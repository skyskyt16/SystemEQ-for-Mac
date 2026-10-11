import Accelerate
import CoreAudio
import Foundation

enum AudioRoutingBackendPreference: String, CaseIterable {
    case automatic
    case native
    case blackHole
}

enum ActiveAudioRoutingBackend: String {
    case none
    case native
    case blackHole
}

struct ProcessTapInputSelection: Equatable {
    let bufferIndex: Int

    static func select(
        tapFormat: AudioStreamBasicDescription,
        aggregateFormats: [AudioStreamBasicDescription],
        aggregateChannelCounts: [UInt32],
        aggregateStartingChannels: [UInt32],
        physicalInputChannelCount: UInt32?
    ) -> ProcessTapInputSelection? {
        guard isSupported(tapFormat),
              aggregateFormats.count == aggregateChannelCounts.count else { return nil }

        let matches = aggregateFormats.indices.filter {
            aggregateChannelCounts[$0] == 2 && formatsMatch(aggregateFormats[$0], tapFormat)
        }
        if matches.count == 1 {
            return ProcessTapInputSelection(bufferIndex: matches[0])
        }

        guard aggregateStartingChannels.count == aggregateFormats.count,
              let physicalInputChannelCount else { return nil }
        let tapStartingChannel = physicalInputChannelCount + 1
        let boundaryMatches = matches.filter {
            aggregateStartingChannels[$0] == tapStartingChannel
        }
        guard boundaryMatches.count == 1 else { return nil }
        return ProcessTapInputSelection(bufferIndex: boundaryMatches[0])
    }

    private static func isSupported(_ format: AudioStreamBasicDescription) -> Bool {
        let expected = AudioStreamBasicDescription(
            mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        return AudioStreamFormatPolicy.matches(format, expected: expected)
    }

    private static func formatsMatch(
        _ lhs: AudioStreamBasicDescription,
        _ rhs: AudioStreamBasicDescription
    ) -> Bool {
        lhs.mSampleRate == rhs.mSampleRate &&
            lhs.mFormatID == rhs.mFormatID &&
            lhs.mFormatFlags == rhs.mFormatFlags &&
            lhs.mBytesPerPacket == rhs.mBytesPerPacket &&
            lhs.mFramesPerPacket == rhs.mFramesPerPacket &&
            lhs.mBytesPerFrame == rhs.mBytesPerFrame &&
            lhs.mChannelsPerFrame == rhs.mChannelsPerFrame &&
            lhs.mBitsPerChannel == rhs.mBitsPerChannel
    }
}

@available(macOS 14.4, *)
final class ProcessTapEngine {
    struct StartInfo {
        let sampleRate: Double
        let bufferFrames: UInt32
    }

    enum StartError: Error {
        case deviceUID
        case createTap(OSStatus)
        case createAggregate(OSStatus)
        case unsupportedTopology
        case createIOProc(OSStatus)
        case startDevice(OSStatus)
        case property(OSStatus)
    }

    private let processor: CoreAudioEngine
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var configuredSampleRate = 0.0
    private var configuredOutputUID: String?
    private var inputSelection = ProcessTapInputSelection(bufferIndex: 0)
    private let scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
    private let scratchCapacity = 4096
    let callbackHealth = AudioCallbackHealth()
    var onSampleRateChange: (() -> Void)?

    init(processor: CoreAudioEngine = .shared) {
        self.processor = processor
    }

    deinit {
        stop()
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    func start(
        outputDeviceID: AudioDeviceID,
        prepareProcessing: (Double, UInt32) -> Void
    ) -> Result<StartInfo, StartError> {
        stop()
        callbackHealth.reset()
        self.outputDeviceID = outputDeviceID

        guard let deviceUID = stringProperty(outputDeviceID, selector: kAudioDevicePropertyDeviceUID) else {
            return .failure(.deviceUID)
        }

        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: ownProcessObject().map { [$0] } ?? []
        )
        description.name = "SystemEQ Native Tap"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &newTapID)
        guard status == noErr, newTapID != kAudioObjectUnknown else {
            return .failure(.createTap(status))
        }
        tapID = newTapID

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SystemEQ Native",
            kAudioAggregateDeviceUIDKey: "com.denzam.SystemEQ.native.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[
                kAudioSubDeviceUIDKey: deviceUID,
                kAudioSubDeviceInputChannelsKey: 0
            ]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true
        ]

        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard status == noErr, newAggregateID != kAudioObjectUnknown else {
            cleanupTap()
            return .failure(.createAggregate(status))
        }
        aggregateID = newAggregateID
        guard stringProperty(aggregateID, selector: kAudioAggregateDevicePropertyMainSubDevice) == deviceUID else {
            cleanup()
            return .failure(.unsupportedTopology)
        }
        configuredOutputUID = deviceUID

        guard let originalBufferFrames = deviceBufferFrames(aggregateID) else {
            cleanup()
            return .failure(.unsupportedTopology)
        }
        if originalBufferFrames > 128 {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var requestedBufferFrames: UInt32 = 128
            let size = UInt32(MemoryLayout<UInt32>.size)
            let bufferStatus = AudioObjectSetPropertyData(
                aggregateID,
                &address,
                0,
                nil,
                size,
                &requestedBufferFrames
            )
            if bufferStatus != noErr {
                dlog("Native buffer request failed: \(bufferStatus)", category: .engine)
            }
        }

        guard let tapFormat = audioFormat(tapID, selector: kAudioTapPropertyFormat),
              let streams = inputStreams(aggregateID),
              let formats = streamFormats(streams),
              let channelCounts = inputStreamChannelCounts(aggregateID),
              let startingChannels = streamStartingChannels(streams),
              let selection = ProcessTapInputSelection.select(
                  tapFormat: tapFormat,
                  aggregateFormats: formats,
                  aggregateChannelCounts: channelCounts,
                  aggregateStartingChannels: startingChannels,
                  physicalInputChannelCount: inputChannelCount(outputDeviceID)
              ) else {
            cleanup()
            return .failure(.unsupportedTopology)
        }
        inputSelection = selection

        guard let sampleRate = nominalSampleRate(outputDeviceID),
              let aggregateRate = nominalSampleRate(aggregateID),
              abs(aggregateRate - sampleRate) < 1,
              abs(tapFormat.mSampleRate - sampleRate) < 1,
              let bufferFrames = deviceBufferFrames(aggregateID), bufferFrames <= UInt32(scratchCapacity),
              verifyOutputFormats(aggregateID, sampleRate: sampleRate) else {
            cleanup()
            return .failure(.unsupportedTopology)
        }
        configuredSampleRate = sampleRate
        prepareProcessing(sampleRate, max(originalBufferFrames, bufferFrames))

        status = AudioDeviceCreateIOProcID(
            aggregateID,
            processTapIOProc,
            Unmanaged.passUnretained(self).toOpaque(),
            &ioProcID
        )
        guard status == noErr, let ioProcID else {
            cleanup()
            return .failure(.createIOProc(status))
        }

        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else {
            cleanup()
            return .failure(.startDevice(status))
        }
        let listenerStatus = installSampleRateListener(sampleRate: sampleRate)
        guard listenerStatus == noErr else {
            cleanup()
            return .failure(.property(listenerStatus))
        }
        let runningBufferFrames = deviceBufferFrames(aggregateID)
        return .success(StartInfo(
            sampleRate: sampleRate,
            bufferFrames: runningBufferFrames ?? bufferFrames
        ))
    }

    func stop() {
        cleanup()
    }

    private func cleanup() {
        removeSampleRateListener()
        if let ioProcID, aggregateID != kAudioObjectUnknown {
            logStatus(AudioDeviceStop(aggregateID, ioProcID), operation: "stopDevice")
            logStatus(AudioDeviceDestroyIOProcID(aggregateID, ioProcID), operation: "destroyIOProc")
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            logStatus(AudioHardwareDestroyAggregateDevice(aggregateID), operation: "destroyAggregate")
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        cleanupTap()
        outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    }

    private func installSampleRateListener(sampleRate: Double) -> OSStatus {
        let deviceID = outputDeviceID
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.nominalSampleRate(deviceID) != sampleRate else { return }
            self.onSampleRateChange?()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
        if status == noErr { sampleRateListener = block }
        logStatus(status, operation: "addRateListener")
        return status
    }

    private func removeSampleRateListener() {
        guard let sampleRateListener, outputDeviceID != kAudioObjectUnknown else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        logStatus(
            AudioObjectRemovePropertyListenerBlock(outputDeviceID, &address, .main, sampleRateListener),
            operation: "removeRateListener"
        )
        self.sampleRateListener = nil
    }

    private func cleanupTap() {
        if tapID != kAudioObjectUnknown {
            logStatus(AudioHardwareDestroyProcessTap(tapID), operation: "destroyTap")
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    @inline(__always)
    func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        processor.noteNativeCallbackInvocation()
        callbackHealth.noteInvocation()
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        guard inputSelection.bufferIndex < inputs.count else {
            callbackHealth.noteFailure(.missingInput)
            zero(outputs)
            return
        }

        let tapBuffer = inputs[inputSelection.bufferIndex]
        guard tapBuffer.mNumberChannels == 2, tapBuffer.mDataByteSize % 8 == 0 else {
            callbackHealth.noteFailure(.invalidInputFormat)
            zero(outputs)
            return
        }
        let frameCount = Int(tapBuffer.mDataByteSize) / (2 * MemoryLayout<Float>.size)
        if frameCount == 0 {
            callbackHealth.noteIdle()
            zero(outputs)
            return
        }
        guard frameCount <= scratchCapacity else {
            callbackHealth.noteFailure(.oversizedBlock)
            zero(outputs)
            return
        }
        guard let inputData = tapBuffer.mData else {
            callbackHealth.noteFailure(.missingInput)
            zero(outputs)
            return
        }
        var outputChannels = 0
        for buffer in outputs {
            let channels = Int(buffer.mNumberChannels)
            guard buffer.mData != nil, channels > 0,
                  Int(buffer.mDataByteSize) >= frameCount * channels * MemoryLayout<Float>.size,
                  Int(buffer.mDataByteSize) % (channels * MemoryLayout<Float>.size) == 0 else {
                callbackHealth.noteFailure(.invalidOutputFormat)
                zero(outputs)
                return
            }
            outputChannels += channels
        }
        guard outputChannels >= 2 else {
            callbackHealth.noteFailure(.missingOutput)
            zero(outputs)
            return
        }

        let interleaved = inputData.assumingMemoryBound(to: Float.self)
        var zeroValue: Float = 0
        vDSP_vsadd(interleaved, 2, &zeroValue, scratchLeft, 1, vDSP_Length(frameCount))
        vDSP_vsadd(interleaved + 1, 2, &zeroValue, scratchRight, 1, vDSP_Length(frameCount))
        processor.generateProcessTapTestToneIfNeeded(
            left: scratchLeft,
            right: scratchRight,
            frameCount: frameCount
        )
        processor.processStereoInPlace(left: scratchLeft, right: scratchRight, frameCount: frameCount)

        var sourceChannel = 0
        var copiedFrames = 0
        for buffer in outputs {
            guard let outputData = buffer.mData else { continue }
            let channels = max(Int(buffer.mNumberChannels), 1)
            let outputFrames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.size)
            let framesToCopy = min(frameCount, outputFrames)
            copiedFrames = max(copiedFrames, framesToCopy)
            let destination = outputData.assumingMemoryBound(to: Float.self)
            for channel in 0..<channels {
                if sourceChannel == 0 {
                    vDSP_vsadd(
                        scratchLeft,
                        1,
                        &zeroValue,
                        destination + channel,
                        vDSP_Stride(channels),
                        vDSP_Length(framesToCopy)
                    )
                } else if sourceChannel == 1 {
                    vDSP_vsadd(
                        scratchRight,
                        1,
                        &zeroValue,
                        destination + channel,
                        vDSP_Stride(channels),
                        vDSP_Length(framesToCopy)
                    )
                } else {
                    vDSP_vclr(
                        destination + channel,
                        vDSP_Stride(channels),
                        vDSP_Length(framesToCopy)
                    )
                }
                sourceChannel += 1
            }
            if outputFrames > framesToCopy {
                vDSP_vclr(
                    destination + framesToCopy * channels,
                    1,
                    vDSP_Length((outputFrames - framesToCopy) * channels)
                )
            }
        }
        processor.noteNativeOutputCallback(frameCount: copiedFrames)
        processor.noteNativeTestToneOutput(left: scratchLeft, right: scratchRight, frameCount: copiedFrames)
        callbackHealth.noteValidBlock()
    }

    @inline(__always)
    private func zero(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }

    private func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processObject
        )
        return status == noErr && processObject != kAudioObjectUnknown ? processObject : nil
    }

    private func stringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        logStatus(status, operation: "readStringProperty")
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        logStatus(status, operation: "readSampleRate")
        guard status == noErr, sampleRate.isFinite, sampleRate > 0 else { return nil }
        return sampleRate
    }

    private func deviceBufferFrames(_ deviceID: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames)
        logStatus(status, operation: "readBufferFrames")
        guard status == noErr, frames > 0 else { return nil }
        return frames
    }

    private func audioFormat(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &format)
        logStatus(status, operation: "readStreamFormat")
        guard status == noErr else { return nil }
        return format
    }

    private func inputStreams(
        _ deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeInput
    ) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        logStatus(sizeStatus, operation: "readStreamsSize")
        guard sizeStatus == noErr else { return nil }
        var streams = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &streams)
        logStatus(status, operation: "readStreams")
        guard status == noErr else { return nil }
        return streams
    }

    private func streamFormats(_ streams: [AudioObjectID]) -> [AudioStreamBasicDescription]? {
        var formats: [AudioStreamBasicDescription] = []
        formats.reserveCapacity(streams.count)
        for stream in streams {
            guard let format = audioFormat(stream, selector: kAudioStreamPropertyVirtualFormat) else { return nil }
            formats.append(format)
        }
        return formats
    }

    private func streamStartingChannels(_ streams: [AudioObjectID]) -> [UInt32]? {
        var channels: [UInt32] = []
        channels.reserveCapacity(streams.count)
        for stream in streams {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioStreamPropertyStartingChannel,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var channel: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &channel)
            logStatus(status, operation: "readStartingChannel")
            guard status == noErr else { return nil }
            channels.append(channel)
        }
        return channels
    }

    private func inputStreamChannelCounts(_ deviceID: AudioDeviceID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        logStatus(sizeStatus, operation: "readChannelConfigurationSize")
        guard sizeStatus == noErr, size > 0 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, storage)
        logStatus(status, operation: "readChannelConfiguration")
        guard status == noErr else { return nil }
        return UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self)
        ).map(\.mNumberChannels)
    }

    private func inputChannelCount(_ deviceID: AudioDeviceID) -> UInt32? {
        inputStreamChannelCounts(deviceID)?.reduce(0, +)
    }

    private func verifyOutputFormats(_ deviceID: AudioDeviceID, sampleRate: Double) -> Bool {
        guard let streams = inputStreams(deviceID, scope: kAudioDevicePropertyScopeOutput),
              let formats = streamFormats(streams), !formats.isEmpty else { return false }
        var channels: UInt32 = 0
        for format in formats {
            guard format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked) ==
                  (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked),
                  format.mFormatFlags & (kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger |
                      kAudioFormatFlagIsAlignedHigh) == 0,
                  format.mBitsPerChannel == 32, format.mChannelsPerFrame > 0,
                  abs(format.mSampleRate - sampleRate) < 1 else { return false }
            let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            let bytes = interleaved ? 4 * format.mChannelsPerFrame : 4
            guard format.mBytesPerFrame == bytes, format.mBytesPerPacket == bytes,
                  format.mFramesPerPacket == 1 else { return false }
            channels += format.mChannelsPerFrame
        }
        return channels >= 2
    }

    /// Control thread only. A running engine flag is insufficient when HAL objects or formats changed.
    func validateRunningConfiguration() -> Bool {
        guard aggregateID != kAudioObjectUnknown, tapID != kAudioObjectUnknown,
              deviceIsAlive(outputDeviceID), deviceIsAlive(aggregateID),
              stringProperty(aggregateID, selector: kAudioAggregateDevicePropertyMainSubDevice) == configuredOutputUID,
              let outputRate = nominalSampleRate(outputDeviceID),
              let aggregateRate = nominalSampleRate(aggregateID),
              abs(outputRate - configuredSampleRate) < 1, abs(aggregateRate - configuredSampleRate) < 1,
              let tapFormat = audioFormat(tapID, selector: kAudioTapPropertyFormat),
              abs(tapFormat.mSampleRate - configuredSampleRate) < 1,
              let streams = inputStreams(aggregateID), let formats = streamFormats(streams),
              let channels = inputStreamChannelCounts(aggregateID),
              let startingChannels = streamStartingChannels(streams),
              ProcessTapInputSelection.select(
                  tapFormat: tapFormat, aggregateFormats: formats, aggregateChannelCounts: channels,
                  aggregateStartingChannels: startingChannels,
                  physicalInputChannelCount: inputChannelCount(outputDeviceID)
              ) == inputSelection,
              verifyOutputFormats(aggregateID, sampleRate: configuredSampleRate) else { return false }
        return true
    }

    private func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &alive)
        logStatus(status, operation: "deviceIsAlive")
        return status == noErr && alive != 0
    }

    private func logStatus(_ status: OSStatus, operation: String) {
        guard status != noErr else { return }
        DiagnosticEventStore.shared.record("native.coreAudio.failed", details: [
            "operation": operation, "status": "\(status)"
        ])
        dlog("Native \(operation) failed: \(status)", level: .error, category: .engine)
    }
}

@available(macOS 14.4, *)
private func processTapIOProc(
    inDevice: AudioObjectID,
    inNow: UnsafePointer<AudioTimeStamp>,
    inInputData: UnsafePointer<AudioBufferList>,
    inInputTime: UnsafePointer<AudioTimeStamp>,
    outOutputData: UnsafeMutablePointer<AudioBufferList>,
    inOutputTime: UnsafePointer<AudioTimeStamp>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let inClientData else { return kAudioHardwareUnspecifiedError }
    let engine = Unmanaged<ProcessTapEngine>.fromOpaque(inClientData).takeUnretainedValue()
    engine.render(input: inInputData, output: outOutputData)
    return noErr
}
