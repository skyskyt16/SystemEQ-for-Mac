import AudioToolbox
import CoreAudio
@testable import SystemEQ_for_Mac
import XCTest

// Async entry points avoid the Swift 6.3 isolated-deinit XCTest crash.
// swiftformat:disable redundantAsync
@MainActor
final class AudioRouteRecoveryTests: XCTestCase {
    // MARK: - Health and bounded retry policy

    func testSilentPlaybackDoesNotTriggerRecovery() async {
        var policy = AudioRouteHealthPolicy(now: 0)
        for second in 1...300 {
            let snapshot = AudioCallbackHealthSnapshot(callbacks: Int64(second * 100), validBlocks: Int64(second * 100))
            XCTAssertNil(policy.evaluate(snapshot, now: Double(second)))
        }
    }

    func testZeroFrameHeartbeatsDoNotTriggerRecovery() async {
        let health = AudioCallbackHealth()
        var policy = AudioRouteHealthPolicy(now: 0)
        for second in 1...300 {
            health.noteInvocation()
            health.noteIdle()
            XCTAssertNil(policy.evaluate(health.snapshot(), now: Double(second)))
        }
        XCTAssertEqual(health.snapshot().failures, 0)
    }

    func testStoppedCallbacksDetectedEvenWithNoRenderError() async {
        var policy = AudioRouteHealthPolicy(now: 0)
        let snapshot = AudioCallbackHealthSnapshot(callbacks: 100, validBlocks: 100)
        XCTAssertNil(policy.evaluate(snapshot, now: 1))
        XCTAssertNil(policy.evaluate(snapshot, now: 5.9))
        XCTAssertEqual(policy.evaluate(snapshot, now: 6), .callbacksStopped)
    }

    func testStartupGraceAndRepeatedInvalidCallbacks() async {
        var policy = AudioRouteHealthPolicy(now: 0)
        let snapshot = AudioCallbackHealthSnapshot(callbacks: 8, failures: 8, consecutiveFailures: 8)
        XCTAssertNil(policy.evaluate(snapshot, now: 2.9))
        XCTAssertEqual(policy.evaluate(snapshot, now: 3), .invalidCallbacks)
    }

    func testTransientInvalidCallbackRecoversWithoutRestart() async {
        let health = AudioCallbackHealth()
        health.noteInvocation()
        health.noteFailure(.renderFailed, status: -50)
        health.noteInvocation()
        health.noteValidBlock()
        var policy = AudioRouteHealthPolicy(now: 0)
        XCTAssertNil(policy.evaluate(health.snapshot(), now: 3))
        XCTAssertEqual(health.snapshot().failures, 1)
        XCTAssertEqual(health.snapshot().consecutiveFailures, 0)
        XCTAssertEqual(health.snapshot().lastStatus, -50)
    }

    func testRetryBudgetStopsAfterThreeAttempts() async {
        var budget = AudioRecoveryBudget()
        XCTAssertEqual(budget.nextDelay(), 1)
        XCTAssertEqual(budget.nextDelay(), 2)
        XCTAssertEqual(budget.nextDelay(), 4)
        for _ in 0..<20 {
            XCTAssertNil(budget.nextDelay())
        }
        XCTAssertEqual(budget.attempts, 3)
    }

    func testBrieflySuccessfulRestartsDoNotResetBudget() async {
        var budget = AudioRecoveryBudget()
        for second in 0..<3 {
            XCTAssertNotNil(budget.nextDelay())
            budget.noteHealthy(now: Double(second))
            budget.noteHealthy(now: Double(second) + 1)
        }
        XCTAssertNil(budget.nextDelay())
    }

    func testBudgetResetsOnlyAfterThirtyHealthySeconds() async {
        var budget = AudioRecoveryBudget()
        _ = budget.nextDelay()
        _ = budget.nextDelay()
        _ = budget.nextDelay()
        budget.noteHealthy(now: 10)
        budget.noteHealthy(now: 39.9)
        XCTAssertEqual(budget.attempts, 3)
        budget.noteHealthy(now: 40)
        XCTAssertEqual(budget.attempts, 0)
        XCTAssertEqual(budget.nextDelay(), 1)
    }

    func testFreshSessionHasWakeStartupGrace() async {
        var policy = AudioRouteHealthPolicy(now: 100)
        XCTAssertNil(policy.evaluate(.init(), now: 102.9))
        XCTAssertNil(policy.evaluate(.init(callbacks: 1, validBlocks: 1), now: 104))
        XCTAssertNil(policy.evaluate(.init(callbacks: 2, validBlocks: 2), now: 108))
    }

    // MARK: - Verified output and rollback with injected CoreAudio failures

    func testDefaultOutputWriteFailureDoesNotReportActivationSuccess() async {
        var reads = 0
        let result = DefaultOutputSwitch.perform(requested: 42, set: { _ in -50 }, read: {
            reads += 1
            return (noErr, 42)
        })
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.status, -50)
        XCTAssertEqual(reads, 0)
    }

    func testDefaultOutputReadFailureDoesNotReportActivationSuccess() async {
        let result = DefaultOutputSwitch.perform(requested: 42, set: { _ in noErr }, read: { (-50, 42) })
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.status, -50)
    }

    func testDefaultOutputMismatchDoesNotReportActivationSuccess() async {
        let result = DefaultOutputSwitch.perform(requested: 42, set: { _ in noErr }, read: { (noErr, 7) })
        XCTAssertFalse(result.success)
    }

    func testVerifiedDefaultOutputSucceeds() async {
        let result = DefaultOutputSwitch.perform(requested: 42, set: { _ in noErr }, read: { (noErr, 42) })
        XCTAssertTrue(result.success)
    }

    func testFailedPartialActivationRestoresOriginalOutputExactlyOnce() async {
        var output: AudioDeviceID = 7
        var rollbacks = 0
        var unitsRunning = false
        let succeeded = AudioRouteActivation.perform(start: {
            let switchResult = DefaultOutputSwitch.perform(requested: 42, set: {
                output = $0
                return noErr
            }, read: { (noErr, output) })
            XCTAssertTrue(switchResult.success)
            unitsRunning = true
            // Simulate a failed format readback after switching to BlackHole.
            return false
        }, rollback: {
            rollbacks += 1
            unitsRunning = false
            output = 7
        })
        XCTAssertFalse(succeeded)
        XCTAssertFalse(unitsRunning)
        XCTAssertEqual(output, 7)
        XCTAssertEqual(rollbacks, 1)
    }

    func testSuccessfulActivationDoesNotRollback() async {
        var rollbacks = 0
        XCTAssertTrue(AudioRouteActivation.perform(start: { true }, rollback: { rollbacks += 1 }))
        XCTAssertEqual(rollbacks, 0)
    }

    // MARK: - Default-output notification arbitration

    func testOwnRecoveryAndRollbackNotificationsCannotConsumeRetryBudget() async {
        var observation = DefaultOutputObservation()
        var budget = AudioRecoveryBudget()
        for expectedDelay in [1.0, 2.0, 4.0] {
            XCTAssertEqual(budget.nextDelay(), expectedDelay)
            for ownedDevice: AudioDeviceID in [42, 7] {
                observation.willWrite(ownedDevice)
                for _ in 0..<3 {
                    XCTAssertEqual(observation.action(
                        observed: ownedDevice, sessionRequested: true, isVirtual: ownedDevice == 42,
                        isCurrentNativeOutput: false, sleepOrWakePending: false
                    ), .ignore)
                }
            }
        }
        XCTAssertNil(budget.nextDelay())
        XCTAssertEqual(budget.attempts, 3)
    }

    func testExternalSelectionSupersedesOwnOutputWrite() async {
        var observation = DefaultOutputObservation()
        observation.willWrite(7)
        for observed: AudioDeviceID in [9, 7] {
            XCTAssertEqual(observation.action(
                observed: observed, sessionRequested: true, isVirtual: false,
                isCurrentNativeOutput: false, sleepOrWakePending: false
            ), .rebuild)
        }
    }

    func testExternalSelectionDuringSleepOrWakeIsDeferred() async {
        var observation = DefaultOutputObservation()
        XCTAssertEqual(observation.action(
            observed: 9, sessionRequested: true, isVirtual: false,
            isCurrentNativeOutput: false, sleepOrWakePending: true
        ), .deferUntilWake)
    }

    func testInactiveVirtualAndCurrentNativeOutputsDoNotRestart() async {
        var observation = DefaultOutputObservation()
        for state in [(false, false, false), (true, true, false), (true, false, true)] {
            XCTAssertEqual(observation.action(
                observed: 9, sessionRequested: state.0, isVirtual: state.1,
                isCurrentNativeOutput: state.2, sleepOrWakePending: false
            ), .ignore)
        }
    }

    func testAtomicHealthCanBeObservedWhileCallbackWriterRuns() async {
        let health = AudioCallbackHealth()
        let writer = Task.detached {
            for _ in 0..<50000 {
                health.noteInvocation()
                health.noteValidBlock()
            }
        }
        for _ in 0..<1000 {
            let snapshot = health.snapshot()
            // Each counter is atomic; a snapshot may span two writer iterations.
            XCTAssertLessThanOrEqual(snapshot.callbacks, 50000)
            XCTAssertLessThanOrEqual(snapshot.validBlocks, 50000)
            XCTAssertEqual(snapshot.failures, 0)
        }
        await writer.value
        XCTAssertEqual(health.snapshot().callbacks, 50000)
        XCTAssertEqual(health.snapshot().validBlocks, 50000)
    }

    // MARK: - Actual AUHAL output failure boundaries, without opening hardware

    func testAUHALInvalidLayoutClearsOnlyAdvertisedOutputAndMarksSilence() async {
        checkInvalidAUHALOutput(
            frames: 1,
            channels: 1,
            advertisedFloats: 1,
            expectedFault: .invalidOutputFormat,
            expectedStatus: noErr
        )
    }

    func testAUHALShortBufferClearsOnlyAdvertisedOutputAndMarksSilence() async {
        checkInvalidAUHALOutput(
            frames: 2,
            channels: 2,
            advertisedFloats: 2,
            expectedFault: .invalidOutputFormat,
            expectedStatus: noErr
        )
    }

    func testAUHALOversizedBlockClearsOnlyAdvertisedOutputAndMarksSilence() async {
        checkInvalidAUHALOutput(
            frames: 4097,
            channels: 2,
            advertisedFloats: 2,
            expectedFault: .oversizedBlock,
            expectedStatus: kAudioUnitErr_TooManyFramesToProcess
        )
    }

    func testAUHALMissingOutputMarksSilenceAndZeroFramesAreIdle() async {
        let engine = CoreAudioEngine.shared
        engine.outputHealth.reset()
        defer { engine.outputHealth.reset() }
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        let reference = Unmanaged.passUnretained(engine).toOpaque()
        XCTAssertEqual(renderCallbackFunction(
            inRefCon: reference,
            ioActionFlags: &flags,
            inTimeStamp: &time,
            inBusNumber: 0,
            inNumberFrames: 1,
            ioData: nil
        ), noErr)
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertEqual(engine.outputHealth.snapshot().lastFault, AudioCallbackFault.missingOutput.rawValue)
        XCTAssertEqual(renderCallbackFunction(
            inRefCon: reference,
            ioActionFlags: &flags,
            inTimeStamp: &time,
            inBusNumber: 0,
            inNumberFrames: 0,
            ioData: nil
        ), noErr)
        XCTAssertEqual(engine.outputHealth.snapshot().consecutiveFailures, 0)
    }

    private func checkInvalidAUHALOutput(
        frames: UInt32, channels: UInt32, advertisedFloats: Int,
        expectedFault: AudioCallbackFault, expectedStatus: OSStatus
    ) {
        let engine = CoreAudioEngine.shared
        engine.prepareProcessTap(sampleRate: 48000, outputDeviceID: 0, bufferFrames: 4096)
        engine.outputHealth.reset()
        defer { engine.stop(); engine.outputHealth.reset() }
        var samples = [Float](repeating: 99, count: advertisedFloats + 2)
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        samples.withUnsafeMutableBytes { storage in
            var output = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: channels, mDataByteSize: UInt32(advertisedFloats * 4), mData: storage.baseAddress
            ))
            XCTAssertEqual(renderCallbackFunction(
                inRefCon: Unmanaged.passUnretained(engine).toOpaque(), ioActionFlags: &flags,
                inTimeStamp: &time, inBusNumber: 0, inNumberFrames: frames, ioData: &output
            ), expectedStatus)
        }
        XCTAssertEqual(Array(samples.prefix(advertisedFloats)), [Float](repeating: 0, count: advertisedFloats))
        XCTAssertEqual(Array(samples.suffix(2)), [99, 99])
        XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        XCTAssertEqual(engine.outputHealth.snapshot().lastFault, expectedFault.rawValue)
        XCTAssertEqual(engine.outputHealth.snapshot().validBlocks, 0)
    }

    // MARK: - Format verification

    func testFormatSetterErrorIsPreservedAndReadbackSkipped() async {
        var reads = 0
        let status = AudioStreamConfiguration.perform(expected: format(), write: { -10868 }, read: {
            reads += 1
            return (noErr, self.format())
        })
        XCTAssertEqual(status, -10868)
        XCTAssertEqual(reads, 0)
    }

    func testFormatReadbackErrorIsPreserved() async {
        let status = AudioStreamConfiguration.perform(
            expected: format(),
            write: { noErr },
            read: { (-50, self.format()) }
        )
        XCTAssertEqual(status, -50)
    }

    func testFormatReadbackRejectsWrongRateLayoutChannelsAndByteSizes() async {
        let expected = format()
        var mutations: [AudioStreamBasicDescription] = []
        var wrong = expected
        wrong.mSampleRate = 44100
        mutations.append(wrong)
        wrong = expected
        wrong.mSampleRate = .nan
        mutations.append(wrong)
        wrong = expected
        wrong.mChannelsPerFrame = 1
        mutations.append(wrong)
        wrong = expected
        wrong.mFormatFlags |= kAudioFormatFlagIsNonInterleaved
        mutations.append(wrong)
        wrong = expected
        wrong.mBytesPerFrame = 4
        mutations.append(wrong)
        wrong = expected
        wrong.mBitsPerChannel = 64
        mutations.append(wrong)
        for observed in mutations {
            XCTAssertNotEqual(AudioStreamConfiguration.perform(
                expected: expected, write: { noErr }, read: { (noErr, observed) }
            ), noErr)
        }
    }

    func testVerifiedFormatsAtDifferentRatesAndInterleaving() async {
        for rate in [44100.0, 48000, 96000] {
            for interleaved in [false, true] {
                let expected = format(rate: rate, interleaved: interleaved)
                XCTAssertEqual(AudioStreamConfiguration.perform(
                    expected: expected, write: { noErr }, read: { (noErr, expected) }
                ), noErr)
            }
        }
    }

    func testFormatReadbackRejectsUnexpectedEndianIntegerAndAlignmentFlags() async {
        let expected = format()
        for flag in [kAudioFormatFlagIsBigEndian, kAudioFormatFlagIsSignedInteger, kAudioFormatFlagIsAlignedHigh] {
            var observed = expected
            observed.mFormatFlags |= flag
            XCTAssertFalse(AudioStreamFormatPolicy.matches(observed, expected: expected))
        }
    }

    func testNativeSelectionRejectsInvalidFloatByteLayouts() async {
        let expected = format()
        var invalid = [AudioStreamBasicDescription]()
        var endian = expected
        endian.mFormatFlags |= kAudioFormatFlagIsBigEndian
        invalid.append(endian)
        var short = expected
        short.mBytesPerFrame = 4
        invalid.append(short)
        var packet = expected
        packet.mFramesPerPacket = 2
        invalid.append(packet)
        var rate = expected
        rate.mSampleRate = .nan
        invalid.append(rate)
        for observed in invalid {
            XCTAssertNil(ProcessTapInputSelection.select(
                tapFormat: observed, aggregateFormats: [observed], aggregateChannelCounts: [2],
                aggregateStartingChannels: [1], physicalInputChannelCount: 0
            ))
        }
    }

    // MARK: - Actual ProcessTap render path, without opening audio hardware

    func testNativeRenderProcessesOneSilentFrameAndReportsValidOutput() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Process Tap requires macOS 14.4") }
        let tap = ProcessTapEngine()
        let enabled = CoreAudioEngine.shared.isEnabled
        CoreAudioEngine.shared.setEnabled(false)
        defer { CoreAudioEngine.shared.setEnabled(enabled) }
        render(tap, frames: 1) { output in XCTAssertEqual(output, [0, 0]) }
        XCTAssertEqual(tap.callbackHealth.snapshot().validBlocks, 1)
        XCTAssertEqual(tap.callbackHealth.snapshot().failures, 0)
    }

    func testNativeRenderZeroFramesAreIdleNotFailure() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Process Tap requires macOS 14.4") }
        let tap = ProcessTapEngine()
        render(tap, frames: 0) { _ in }
        XCTAssertEqual(tap.callbackHealth.snapshot().callbacks, 1)
        XCTAssertEqual(tap.callbackHealth.snapshot().failures, 0)
    }

    func testNativeRenderOversizedBlockFailsSafely() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Process Tap requires macOS 14.4") }
        let tap = ProcessTapEngine()
        render(tap, frames: 4097) { output in XCTAssertTrue(output.allSatisfy { $0 == 0 }) }
        XCTAssertEqual(tap.callbackHealth.snapshot().lastFault, AudioCallbackFault.oversizedBlock.rawValue)
        XCTAssertEqual(tap.callbackHealth.snapshot().validBlocks, 0)
    }

    func testNativeRenderRejectsWrongInputChannels() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Process Tap requires macOS 14.4") }
        let tap = ProcessTapEngine()
        render(tap, frames: 1, inputChannels: 1) { output in XCTAssertEqual(output, [0, 0]) }
        XCTAssertEqual(tap.callbackHealth.snapshot().lastFault, AudioCallbackFault.invalidInputFormat.rawValue)
    }

    func testNativeRenderRejectsOutputTooSmallBeforeWriting() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Process Tap requires macOS 14.4") }
        let tap = ProcessTapEngine()
        render(tap, frames: 2, outputFrames: 1) { output in XCTAssertEqual(output, [0, 0, 99, 99]) }
        XCTAssertEqual(tap.callbackHealth.snapshot().lastFault, AudioCallbackFault.invalidOutputFormat.rawValue)
    }

    func testNativeRenderRejectsMisalignedInputByteCount() async throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Process Tap requires macOS 14.4") }
        let tap = ProcessTapEngine()
        render(tap, frames: 1, inputBytes: 7) { output in XCTAssertEqual(output, [0, 0]) }
        XCTAssertEqual(tap.callbackHealth.snapshot().lastFault, AudioCallbackFault.invalidInputFormat.rawValue)
    }

    private func format(rate: Double = 48000, interleaved: Bool = true) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: interleaved ? 8 : 4, mFramesPerPacket: 1,
            mBytesPerFrame: interleaved ? 8 : 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
    }

    @available(macOS 14.4, *)
    private func render(
        _ tap: ProcessTapEngine, frames: Int, inputChannels: UInt32 = 2,
        outputFrames: Int? = nil, inputBytes: UInt32? = nil, check: ([Float]) -> Void
    ) {
        var input = [Float](repeating: 0, count: max(frames * 2, 2))
        var output = [Float](repeating: 99, count: max(frames * 2, 2))
        input.withUnsafeMutableBytes { inputStorage in
            output.withUnsafeMutableBytes { outputStorage in
                var inputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: inputChannels, mDataByteSize: inputBytes ?? UInt32(frames * 8),
                    mData: inputStorage.baseAddress
                ))
                var outputList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                    mNumberChannels: 2, mDataByteSize: UInt32((outputFrames ?? frames) * 8),
                    mData: outputStorage.baseAddress
                ))
                tap.render(input: &inputList, output: &outputList)
            }
        }
        check(output)
    }
}
