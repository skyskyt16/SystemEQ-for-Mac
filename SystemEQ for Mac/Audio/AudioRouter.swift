//
//  AudioRouter.swift
//  SystemEQ for Mac
//
//  Audio Device Management and Routing
//  Handles device enumeration, BlackHole setup, and system audio routing
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import Foundation
import SwiftUI

// MARK: - Audio Device

public struct AudioDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let isInput: Bool
    public let isOutput: Bool

    public init(id: AudioDeviceID, name: String, uid: String, isInput: Bool, isOutput: Bool) {
        self.id = id
        self.name = name
        self.uid = uid
        self.isInput = isInput
        self.isOutput = isOutput
    }
}

struct OutputVolumeState: Equatable {
    let scalar: Float
    let isMuted: Bool?

    nonisolated init?(scalar: Float, isMuted: Bool?) {
        guard scalar.isFinite else { return nil }
        self.scalar = min(max(scalar, 0), 1)
        self.isMuted = isMuted
    }
}

enum RoutingRequestReason: String {
    case request
    case backendPreferenceChanged
    case outputSelected
    case sampleRateChanged
    case systemOutputChanged
    case preferredOutputReturned
    case outputDisconnected
    case deviceRecovery
    case wake
    case healthRecovery
}

enum OutputVolumeTransfer {
    static func transfer(
        from source: AudioDeviceID,
        to destination: AudioDeviceID,
        read: (AudioDeviceID) -> OutputVolumeState?,
        write: (OutputVolumeState, AudioDeviceID) -> Bool,
        fallback: OutputVolumeState? = nil
    ) -> Bool {
        guard source != destination, let state = read(source) ?? fallback else { return false }
        return write(state, destination)
    }
}

enum DefaultOutputVerificationPolicy {
    nonisolated static func shouldVerify(requestGeneration: UInt64, currentGeneration: UInt64) -> Bool {
        requestGeneration == currentGeneration
    }
}

enum NativeRoutingFailureRecovery {
    case none
    case restore(AudioDevice)
    case recoverPhysicalOutput
}

enum NativeRoutingFailureRecoveryPolicy {
    nonisolated static func recovery(
        previous: AudioDevice?,
        attempted: AudioDevice,
        previousWasVirtual: Bool
    ) -> NativeRoutingFailureRecovery {
        guard let previous else { return .none }
        if previousWasVirtual { return .recoverPhysicalOutput }
        guard previous.id != attempted.id else { return .none }
        return .restore(previous)
    }
}

enum BlackHoleGainStaging {
    private static let unityState = OutputVolumeState(scalar: 1, isMuted: false)

    static func prepareVirtualOutput(
        physicalDevice: AudioDeviceID,
        virtualDevice: AudioDeviceID,
        read: (AudioDeviceID) -> OutputVolumeState?,
        write: (OutputVolumeState, AudioDeviceID) -> Bool
    ) -> Bool {
        guard physicalDevice != virtualDevice else { return false }
        guard let expected = read(physicalDevice) ?? unityState else { return false }
        guard write(expected, virtualDevice), let observed = read(virtualDevice) else { return false }
        return matches(observed, expected: expected)
    }

    static func setPhysicalOutputToUnity(
        _ deviceID: AudioDeviceID,
        read: (AudioDeviceID) -> OutputVolumeState?,
        write: (OutputVolumeState, AudioDeviceID) -> Bool
    ) -> Bool {
        guard let observed = read(deviceID) else { return true }
        if isUnity(observed) { return true }
        guard let unityState else { return false }
        guard write(unityState, deviceID), let verified = read(deviceID) else { return false }
        return isUnity(verified)
    }

    static func isUnity(_ state: OutputVolumeState) -> Bool {
        state.scalar >= 0.999 && state.isMuted != true
    }

    private static func matches(_ observed: OutputVolumeState, expected: OutputVolumeState) -> Bool {
        abs(observed.scalar - expected.scalar) <= 0.001 &&
            (expected.isMuted == nil || observed.isMuted == expected.isMuted)
    }
}

enum BlackHoleVolumeChangeAction {
    case acceptObserved
    case restoreExpected
    case ignore
}

enum BlackHoleVolumeChangePolicy {
    static let coalescingDelayNanoseconds: UInt64 = 1_000_000

    static func action(for scopes: Set<AudioObjectPropertyScope>) -> BlackHoleVolumeChangeAction {
        if scopes.contains(kAudioObjectPropertyScopeOutput) {
            return .acceptObserved
        }
        if scopes.contains(kAudioObjectPropertyScopeInput) {
            return .restoreExpected
        }
        return .ignore
    }

    nonisolated static func needsVolumeWrite(
        from observed: OutputVolumeState?,
        to expected: OutputVolumeState
    ) -> Bool {
        observed?.scalar != expected.scalar
    }

    nonisolated static func needsMuteWrite(
        from observed: OutputVolumeState?,
        to expected: OutputVolumeState
    ) -> Bool {
        guard let expectedMute = expected.isMuted else { return false }
        return observed?.isMuted != expectedMute
    }
}

private struct AudioPropertyListenerRegistration {
    let deviceID: AudioDeviceID
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
}

// MARK: - Audio Router

public final class AudioRouter: ObservableObject {
    // MARK: - Published Properties

    @Published public var inputDevices: [AudioDevice] = []
    @Published public var outputDevices: [AudioDevice] = []

    @Published public var selectedInputDevice: AudioDevice?
    @Published public var selectedOutputDevice: AudioDevice?

    @Published public var blackHoleDetected: Bool = false

    @Published public var statusMessage: String = "Checking devices..."
    @Published public var isRoutingActive: Bool = false
    @Published private(set) var activeBackend: ActiveAudioRoutingBackend = .none
    @Published private(set) var backendPreference: AudioRoutingBackendPreference = {
        let rawValue = UserDefaults.standard.string(forKey: AudioRouter.backendPreferenceKey)
        return rawValue.flatMap(AudioRoutingBackendPreference.init(rawValue:)) ?? .automatic
    }()

    // MARK: - Private Properties

    private var originalSystemOutputDevice: AudioDevice?
    private var deviceChangeDebounceTask: Task<Void, Never>?
    private var defaultOutputChangeTask: Task<Void, Never>?
    private var defaultOutputRequestGeneration: UInt64 = 0
    private var blackHoleVolumeListeners: [AudioPropertyListenerRegistration] = []
    private var blackHoleVolumeChangeTask: Task<Void, Never>?
    private var pendingBlackHoleVolumeChangeScopes: Set<AudioObjectPropertyScope> = []
    private var expectedBlackHoleOutputVolume: OutputVolumeState?
    private var monitoredBlackHoleDeviceID: AudioDeviceID?
    private var processTapEngineStorage: AnyObject?
    private var healthTimer: DispatchSourceTimer?
    private var healthPolicies: [AudioRouteHealthPolicy] = []
    private var recoveryBudget = AudioRecoveryBudget()
    private var defaultOutputObservation = DefaultOutputObservation()
    private var recoveryTask: Task<Void, Never>?
    private var configurationChangeTask: Task<Void, Never>?
    private var configurationListeners: [AudioPropertyListenerRegistration] = []
    private var recoveryBackend: ActiveAudioRoutingBackend = .none
    private var recoveryFallbackAttempted = false
    private var recoveryProcessingEnabled = true
    private var recoveryOutput: AudioDevice?
    private var routingSessionRequested = false

    static let backendPreferenceKey = "audioRoutingBackend"

    var canEnableRouting: Bool {
        guard selectedOutputDevice != nil else { return false }
        if backendPreference == .blackHole { return blackHoleDetected }
        if #available(macOS 14.4, *) { return true }
        return backendPreference == .automatic && blackHoleDetected
    }

    /// UID of the real (non-BlackHole) system output, persisted so a crash that
    /// left the system on BlackHole can still be recovered on next launch.
    private let originalOutputUIDKey = "originalSystemOutputUID"

    /// UIDs of the devices the engine is currently routing through. A UID survives
    /// unplug/replug, an AudioDeviceID does not — so this is what we validate
    /// against whenever the device list changes.
    private var activeInputUID: String?
    private var activeOutputUID: String?

    /// The output we actually want, as opposed to `activeOutputUID` which can be
    /// a temporary fallback. Set once when routing starts and left alone by
    /// fallback rebuilds, so a later topology change can switch back to it.
    private var preferredOutputUID: String?

    /// Set when sleep interrupted an active routing session, so wake restores it.
    private var wasRoutingBeforeSleep = false
    private var wakeRestartTask: Task<Void, Never>?

    /// Whether we are the reason the system default output is BlackHole — true even
    /// while the engine is stopped (between sleep and the wake restart, or after a
    /// restart that failed). Quitting in that window must still restore the real
    /// output, which `CoreAudioEngine.isRunning` alone would not catch.
    public var isRoutingOwned: Bool {
        routingSessionRequested || activeBackend != .none || activeInputUID != nil || CoreAudioEngine.shared.isRunning
    }

    public static let shared = AudioRouter()

    // MARK: - Initialization

    private init() {
        // Setup listeners first to catch any device changes.
        // The initial device refresh is now handled asynchronously from the UI layer.
        setupDeviceChangeListener()
        setupDefaultOutputChangeListener()
        setupNotificationObservers()
        setupSleepWakeObservers()
    }

    func setBackendPreference(_ preference: AudioRoutingBackendPreference) {
        guard backendPreference != preference else { return }
        backendPreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: Self.backendPreferenceKey)
        updateStatus()
        if isRoutingOwned {
            enableEQRouting(forceRestart: true, reason: .backendPreferenceChanged)
        }
    }

    private func setupNotificationObservers() {
        // Listen for device changes from UI
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceChanged),
            name: NSNotification.Name("AudioDeviceChanged"),
            object: nil
        )
    }

    @objc
    private func handleDeviceChanged(_ notification: Notification) {
        // Handle device changes if needed
        guard let userInfo = notification.userInfo else { return }

        if let inputID = userInfo["inputDeviceID"] as? AudioDeviceID,
           let outputID = userInfo["outputDeviceID"] as? AudioDeviceID {
            dlog("Audio devices changed: input=\(inputID), output=\(outputID)", category: .routing)
        }
    }

    // MARK: - Device Enumeration

    public func refreshDevices() async {
        // Perform blocking CoreAudio calls on a background thread.
        let (rawInputs, rawOutputs) = await Task.detached {
            let inputs = AudioRouter.getDevices(isInput: true)
            let outputs = AudioRouter.getDevices(isOutput: true)
            return (inputs, outputs)
        }.value

        // Update the UI and published properties on the Main Actor.
        await MainActor.run {
            // Construct AudioDevice values on the MainActor to satisfy Swift concurrency.
            self.inputDevices = rawInputs.map { info in
                AudioDevice(
                    id: info.id,
                    name: info.name,
                    uid: info.uid,
                    isInput: info.hasInput,
                    isOutput: info.hasOutput
                )
            }
            self.outputDevices = rawOutputs.map { info in
                AudioDevice(
                    id: info.id,
                    name: info.name,
                    uid: info.uid,
                    isInput: info.hasInput,
                    isOutput: info.hasOutput
                )
            }

            self.detectBlackHole()

            // Save the original system output, but only on the first run.
            if self.originalSystemOutputDevice == nil {
                self.saveCurrentSystemOutputDevice()
            }

            // Auto-select devices if they haven't been selected yet.
            if self.selectedInputDevice == nil,
               let blackHole = self.inputDevices
               .first(where: { $0.name.contains(AppConstants.DeviceNames.blackHole) }) {
                self.selectedInputDevice = blackHole
            }

            if self.selectedOutputDevice == nil {
                self.selectedOutputDevice = self.findBestPhysicalOutputDevice()
            }

            self.updateStatus()
            if !self.isRoutingOwned, !self.routingSessionRequested {
                CoreAudioEngine.shared.restoreDeviceSampleRates()
            }
        }
    }

    /// Internal representation used by the nonisolated CoreAudio helper.
    private struct RawDeviceInfo {
        let id: AudioDeviceID
        let name: String
        let uid: String
        let hasInput: Bool
        let hasOutput: Bool
    }

    nonisolated private static func getDevices(isInput: Bool = false, isOutput: Bool = false) -> [RawDeviceInfo] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else {
            errorLog("Failed to get device list size: \(status)", category: .routing)
            return []
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard status == noErr else {
            errorLog("Failed to get device list: \(status)", category: .routing)
            return []
        }

        return deviceIDs.compactMap { deviceID -> RawDeviceInfo? in
            guard let name = AudioRouter.getDeviceName(deviceID),
                  let uid = AudioRouter.getDeviceUID(deviceID) else {
                return nil
            }

            let hasInput = AudioRouter.hasInputStreams(deviceID)
            let hasOutput = AudioRouter.hasOutputStreams(deviceID)

            // Filter based on request
            if isInput, !hasInput {
                return nil
            }
            if isOutput, !hasOutput {
                return nil
            }

            return RawDeviceInfo(
                id: deviceID,
                name: name,
                uid: uid,
                hasInput: hasInput,
                hasOutput: hasOutput
            )
        }
    }

    // MARK: - Device Properties

    nonisolated private static func getDeviceName(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var name: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)

        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }

        guard status == noErr, let unmanagedName = name else { return nil }
        return unmanagedName.takeRetainedValue() as String
    }

    nonisolated private static func getDeviceUID(_ deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var uid: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>>.size)

        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &propertyAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }

        guard status == noErr, let unmanagedUID = uid else { return nil }
        return unmanagedUID.takeRetainedValue() as String
    }

    nonisolated private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }

    nonisolated private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        return status == noErr && dataSize > 0
    }

    // MARK: - Device Selection

    func selectInputDevice(_ device: AudioDevice) {
        selectedInputDevice = device
        dlog("Selected input: \(device.name)", category: .routing)

        // Повідомляємо про зміну пристрою через NotificationCenter
        NotificationCenter.default.post(
            name: NSNotification.Name("AudioDeviceChanged"),
            object: nil,
            userInfo: ["inputDeviceID": device.id, "outputDeviceID": selectedOutputDevice?.id as Any]
        )

        updateStatus()
    }

    func selectOutputDevice(_ device: AudioDevice) {
        guard !device.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase) else {
            dlog("BlackHole cannot be selected as the processed output", level: .warning, category: .routing)
            return
        }
        selectedOutputDevice = device
        preferredOutputUID = device.uid
        dlog("Selected output: \(device.name)", category: .routing)

        // Повідомляємо про зміну пристрою через NotificationCenter
        NotificationCenter.default.post(
            name: NSNotification.Name("AudioDeviceChanged"),
            object: nil,
            userInfo: ["inputDeviceID": selectedInputDevice?.id as Any, "outputDeviceID": device.id]
        )

        updateStatus()
        if isRoutingOwned {
            wakeRestartTask?.cancel()
            wakeRestartTask = nil
            wasRoutingBeforeSleep = false
            enableEQRouting(forceRestart: true, reason: .outputSelected)
        }
    }

    func setupBlackHoleRouting() {
        guard let blackHoleInput = inputDevices
            .first(where: { $0.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase) }),
            let physicalOutput = findBestPhysicalOutputDevice() else {
            dlog("Cannot setup BlackHole routing - missing devices", level: .warning, category: .routing)
            return
        }

        guard activateBlackHoleRoute(output: physicalOutput) else {
            errorLog("Cannot start BlackHole routing", category: .routing)
            return
        }
        selectedInputDevice = blackHoleInput
        dlog("BlackHole routing configured to \(physicalOutput.name)", category: .routing)
    }

    /// Diagnostic entry points use the same verified setup, rollback and health monitoring as normal routing.
    private func activateBlackHoleRoute(output: AudioDevice) -> Bool {
        guard let previousOutput = currentSystemOutputDevice() else { return false }
        recoveryTask?.cancel()
        recoveryTask = nil
        wakeRestartTask?.cancel()
        wakeRestartTask = nil
        wasRoutingBeforeSleep = false
        recoveryBudget = AudioRecoveryBudget()
        recoveryFallbackAttempted = false
        routingSessionRequested = true
        let succeeded = AudioRouteActivation.perform(start: {
            stopActiveBackendForRestart()
            return startBlackHoleRouting(output: output, persistEnabledStateOnFailure: false)
        }, rollback: {
            rollbackFailedActivation(previousOutput: previousOutput)
            routingSessionRequested = false
        })
        if succeeded {
            selectedOutputDevice = output
            preferredOutputUID = output.uid
        }
        return succeeded
    }

    private func findBestPhysicalOutputDevice() -> AudioDevice? {
        // Пріоритетні аудіо інтерфейси
        let priorityDevices = AppConstants.DeviceNames.priorityDevices

        // Спочатку шукаємо пріоритетні пристрої
        for priority in priorityDevices {
            if let device = outputDevices.first(where: {
                !$0.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase) &&
                    $0.name.lowercased().contains(priority)
            }) {
                dlog("Found priority device: \(device.name)", category: .routing)
                return device
            }
        }

        // Якщо пріоритетних немає, шукаємо будь-який USB аудіо інтерфейс
        if let usbDevice = outputDevices.first(where: {
            !$0.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase) &&
                ($0.name.lowercased().contains("usb") || $0.uid.lowercased().contains("usb"))
        }) {
            dlog("Found USB device: \(usbDevice.name)", category: .routing)
            return usbDevice
        }

        // Якщо USB немає, беремо перший не-BlackHole пристрій
        if let firstDevice = outputDevices
            .first(where: { !$0.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase) }) {
            dlog("Using first available device: \(firstDevice.name)", category: .routing)
            return firstDevice
        }

        return nil
    }

    /// Output device the engine should feed. Prefers the device we actually want
    /// (survives a temporary fallback), then the one we were last routing
    /// through, and only auto-picks when both are really gone.
    private func preferredOutputDevice() -> AudioDevice? {
        if let uid = preferredOutputUID,
           let wanted = outputDevices.first(where: { $0.uid == uid }) {
            return wanted
        }
        if let selectedOutputDevice,
           !selectedOutputDevice.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase),
           let selected = outputDevices.first(where: { $0.uid == selectedOutputDevice.uid }) {
            return selected
        }
        if let uid = activeOutputUID,
           let previous = outputDevices.first(where: { $0.uid == uid }) {
            return previous
        }
        return findBestPhysicalOutputDevice()
    }

    private func diagnosticDeviceKind(_ device: AudioDevice?) -> String {
        guard let device else { return "unavailable" }
        let identifier = "\(device.name) \(device.uid)".lowercased()
        if identifier.contains(AppConstants.DeviceNames.blackHoleLowercase) { return "blackHole" }
        if identifier.contains("built-in") || identifier.contains("macbook") || identifier.contains("mac mini") {
            return "builtIn"
        }
        if identifier.contains("usb") { return "usbAudio" }
        return "externalAudio"
    }

    /// - Parameter forceRestart: rebuild the AudioUnits even when the engine looks
    ///   like it is already running on these device IDs. Needed after sleep and
    ///   after a replug, where the IDs can match while the units are already dead.
    @discardableResult
    func enableEQRouting(
        forceRestart: Bool = false,
        persistEnabledStateOnFailure: Bool = true,
        reason: RoutingRequestReason = .request
    ) -> Bool {
        guard let physicalOutput = preferredOutputDevice() else {
            DiagnosticEventStore.shared.record("routing.enable.failed", details: [
                "reason": "noPhysicalOutput", "trigger": reason.rawValue
            ])
            errorLog("No physical output device found!", category: .routing)
            return false
        }

        DiagnosticEventStore.shared.record(
            "routing.enable.request",
            details: [
                "backendPreference": backendPreference.rawValue,
                "forceRestart": "\(forceRestart)",
                "trigger": reason.rawValue,
                "outputKind": diagnosticDeviceKind(physicalOutput)
            ]
        )

        selectedOutputDevice = physicalOutput
        if preferredOutputUID == nil {
            preferredOutputUID = physicalOutput.uid
        }

        let engine = CoreAudioEngine.shared
        if !forceRestart,
           engine.isRunning,
           activeBackend != .none,
           engine.currentOutputDeviceID == physicalOutput.id {
            DiagnosticEventStore.shared.record("routing.enable.skipped", details: ["reason": "alreadyActive"])
            dlog("EQ routing already active, skipping restart", category: .routing)
            return true
        }

        if reason == .request || reason == .outputSelected || reason == .backendPreferenceChanged {
            recoveryTask?.cancel()
            recoveryTask = nil
            recoveryBudget = AudioRecoveryBudget()
            recoveryFallbackAttempted = false
        }
        let previousOutput = currentSystemOutputDevice()
        guard previousOutput != nil else {
            DiagnosticEventStore.shared.record("routing.enable.failed", details: ["reason": "defaultOutputRead"])
            return false
        }
        routingSessionRequested = true
        return AudioRouteActivation.perform(start: {
            stopActiveBackendForRestart()
            switch backendPreference {
            case .native:
                return startNativeRouting(
                    output: physicalOutput,
                    persistEnabledStateOnFailure: persistEnabledStateOnFailure
                )
            case .blackHole:
                return startBlackHoleRouting(
                    output: physicalOutput,
                    persistEnabledStateOnFailure: persistEnabledStateOnFailure
                )
            case .automatic:
                if startNativeRouting(output: physicalOutput, persistEnabledStateOnFailure: false) { return true }
                DiagnosticEventStore.shared.record("routing.native.fallback", details: ["reason": "startFailed"])
                return startBlackHoleRouting(
                    output: physicalOutput,
                    persistEnabledStateOnFailure: persistEnabledStateOnFailure
                )
            }
        }, rollback: {
            rollbackFailedActivation(previousOutput: previousOutput)
            if reason != .healthRecovery {
                routingSessionRequested = false
            }
            if persistEnabledStateOnFailure { UserDefaults.standard.set(false, forKey: "eqWasEnabled") }
        })
    }

    private func rollbackFailedActivation(previousOutput: AudioDevice?) {
        stopActiveBackendForRestart()
        CoreAudioEngine.shared.restoreDeviceSampleRates()
        if let previousOutput,
           !previousOutput.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase),
           let current = outputDevices.first(where: { $0.uid == previousOutput.uid }),
           setAsDefaultOutputDevice(current) {
            DiagnosticEventStore.shared.record("routing.activation.rolledBack", details: ["result": "originalOutput"])
        } else {
            restoreOriginalSystemOutputDevice()
        }
    }

    private func startNativeRouting(
        output: AudioDevice,
        persistEnabledStateOnFailure: Bool
    ) -> Bool {
        guard #available(macOS 14.4, *) else {
            DiagnosticEventStore.shared.record("routing.enable.failed", details: ["reason": "nativeUnavailable"])
            return false
        }

        let previousDefaultOutput = currentSystemOutputDevice()
        saveCurrentSystemOutputDevice()
        guard setAsDefaultOutputDevice(output) else { return false }
        let nativeEngine = ProcessTapEngine()
        nativeEngine.onSampleRateChange = { [weak self] in
            self?.scheduleConfigurationRecovery(reason: .sampleRateChanged)
        }
        switch nativeEngine.start(outputDeviceID: output.id, prepareProcessing: { sampleRate, bufferFrames in
            CoreAudioEngine.shared.prepareProcessTap(
                sampleRate: sampleRate,
                outputDeviceID: output.id,
                bufferFrames: bufferFrames
            )
            AudioEngine.shared.reapplyCurrentFilters()
        }) {
        case let .success(info):
            processTapEngineStorage = nativeEngine
            activeBackend = .native
            activeInputUID = nil
            activeOutputUID = output.uid
            CoreAudioEngine.shared.markProcessTapStarted()
            DiagnosticEventStore.shared.record(
                "routing.enable.succeeded",
                details: [
                    "backend": "native",
                    "bufferFrames": "\(info.bufferFrames)",
                    "outputKind": diagnosticDeviceKind(output),
                    "sampleRateHz": String(format: "%.0f", info.sampleRate)
                ]
            )
            installConfigurationListeners(devices: [output.id], includeRate: false)
            startHealthMonitoring()
            dlog("EQ routing active: native Process Tap → \(output.name)", level: .info, category: .routing)
            return true
        case let .failure(error):
            processTapEngineStorage = nil
            CoreAudioEngine.shared.stop()
            let recovery = NativeRoutingFailureRecoveryPolicy.recovery(
                previous: previousDefaultOutput,
                attempted: output,
                previousWasVirtual: previousDefaultOutput?.name.lowercased()
                    .contains(AppConstants.DeviceNames.blackHoleLowercase) == true
            )
            switch recovery {
            case .none:
                break
            case let .restore(outputToRestore):
                setAsDefaultOutputDevice(outputToRestore)
            case .recoverPhysicalOutput:
                restoreOriginalSystemOutputDevice()
            }
            DiagnosticEventStore.shared.record(
                "routing.enable.failed",
                details: ["backend": "native", "reason": String(describing: error)]
            )
            if persistEnabledStateOnFailure {
                UserDefaults.standard.set(false, forKey: "eqWasEnabled")
            }
            return false
        }
    }

    private func startBlackHoleRouting(
        output physicalOutput: AudioDevice,
        persistEnabledStateOnFailure: Bool
    ) -> Bool {
        guard let blackHoleDevice = inputDevices
            .first(where: { $0.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase) }) else {
            DiagnosticEventStore.shared.record("routing.enable.failed", details: ["reason": "blackHoleMissing"])
            errorLog("BlackHole not found! Install from: \(AppConstants.URLs.blackHoleWebsite)", category: .routing)
            return false
        }

        saveCurrentSystemOutputDevice()

        let virtualVolumeReady = BlackHoleGainStaging.prepareVirtualOutput(
            physicalDevice: physicalOutput.id,
            virtualDevice: blackHoleDevice.id,
            read: Self.outputVolumeState,
            write: { state, deviceID in
                Self.applyOutputVolumeState(
                    state,
                    replacing: Self.outputVolumeState(for: deviceID),
                    to: deviceID
                )
            }
        )
        guard virtualVolumeReady else {
            DiagnosticEventStore.shared.record(
                "routing.enable.failed",
                details: ["backend": "blackHole", "reason": "virtualVolume"]
            )
            return false
        }

        guard setAsDefaultOutputDevice(blackHoleDevice) else { return false }
        removeBlackHoleVolumeListeners()
        let engine = CoreAudioEngine.shared
        engine.stop()
        guard engine.setup(inputDevice: blackHoleDevice.id, outputDevice: physicalOutput.id) else {
            return false
        }
        AudioEngine.shared.reapplyCurrentFilters()
        guard engine.start() else {
            DiagnosticEventStore.shared.record("routing.enable.failed", details: ["reason": "engineStart"])
            errorLog("Core Audio Engine failed to start; restoring system output", category: .routing)
            return false
        }

        let physicalUnityReady = BlackHoleGainStaging.setPhysicalOutputToUnity(
            physicalOutput.id,
            read: Self.outputVolumeState,
            write: { state, deviceID in
                Self.applyOutputVolumeState(
                    state,
                    replacing: Self.outputVolumeState(for: deviceID),
                    to: deviceID
                )
            }
        )
        DiagnosticEventStore.shared.record(
            "routing.blackHoleGainStaging",
            details: [
                "physicalUnity": "\(physicalUnityReady)",
                "virtualVolume": "\(virtualVolumeReady)"
            ]
        )
        guard physicalUnityReady else {
            DiagnosticEventStore.shared.record(
                "routing.enable.failed",
                details: ["backend": "blackHole", "reason": "physicalUnity"]
            )
            return false
        }

        installBlackHoleVolumeListeners(deviceID: blackHoleDevice.id)
        activeBackend = .blackHole
        activeInputUID = blackHoleDevice.uid
        activeOutputUID = physicalOutput.uid
        installConfigurationListeners(devices: [blackHoleDevice.id, physicalOutput.id], includeRate: true)
        startHealthMonitoring()

        DiagnosticEventStore.shared.record(
            "routing.enable.succeeded",
            details: ["backend": "blackHole", "outputKind": diagnosticDeviceKind(physicalOutput)]
        )

        dlog(
            "EQ routing active: System → BlackHole → CoreAudio+EQ → \(physicalOutput.name) (~20-25ms latency)",
            level: .info,
            category: .routing
        )
        return true
    }

    private func stopActiveBackendForRestart() {
        let previousBackend = activeBackend
        stopHealthMonitoring()
        removeConfigurationListeners()
        removeBlackHoleVolumeListeners()
        if #available(macOS 14.4, *), let nativeEngine = processTapEngineStorage as? ProcessTapEngine {
            nativeEngine.stop()
        }
        processTapEngineStorage = nil
        CoreAudioEngine.shared.stop()
        if previousBackend == .blackHole {
            restoreOriginalSystemOutputDevice()
        }
        activeBackend = .none
        activeInputUID = nil
        activeOutputUID = nil
    }

    private func showSetupInstructions(blackHole: AudioDevice, scarlett: AudioDevice) {
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.localized(.eqRoutingSetupRequired)
        alert.informativeText = String(
            format: LocalizationManager.shared.localized(.eqRoutingSetupInstructions),
            scarlett.name
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: LocalizationManager.shared.localized(.openAudioMIDISetupButton))
        alert.addButton(withTitle: LocalizationManager.shared.localized(.testAudioButton))
        alert.addButton(withTitle: LocalizationManager.shared.localized(.cancel))

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            // Відкриваємо Audio MIDI Setup
            let audioMIDIURL = URL(fileURLWithPath: "/Applications/Utilities/Audio MIDI Setup.app")
            dlog("🔧 Opening Audio MIDI Setup at: \(audioMIDIURL.path)", category: .general)

            // Метод 1: NSWorkspace.shared.open
            let success = NSWorkspace.shared.open(audioMIDIURL)
            if success {
                dlog("✅ Audio MIDI Setup opened successfully", category: .general)
            } else {
                dlog("❌ NSWorkspace failed", category: .general)

                // Метод 2: Process з /usr/bin/open
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-a", "Audio MIDI Setup"]

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        dlog("✅ Audio MIDI Setup opened via /usr/bin/open", category: .general)
                    } else {
                        dlog("❌ /usr/bin/open failed with status: \(process.terminationStatus)", category: .general)
                    }
                } catch {
                    dlog("❌ Process failed: \(error)", category: .general)

                    // Метод 3: Прямий шлях до .app
                    let directProcess = Process()
                    directProcess.executableURL = audioMIDIURL
                    do {
                        try directProcess.run()
                        dlog("✅ Audio MIDI Setup opened via direct execution", category: .general)
                    } catch {
                        dlog("❌ Direct execution failed: \(error)", category: .general)
                        dlog("💡 Please manually open: Applications → Utilities → Audio MIDI Setup", category: .general)
                    }
                }
            }

        case .alertSecondButtonReturn:
            // Тестуємо аудіо
            testAudioRouting()

        default:
            break
        }
    }

    func testAudioRouting() {
        dlog("🔊 Testing audio routing...", category: .general)

        Task { @MainActor in
            // Refresh device list
            dlog("🔄 Refreshing device list...", category: .general)
            await refreshDevices()

            // Find BlackHole and a physical output
            guard let blackHoleInput = inputDevices.first(where: { $0.name.lowercased().contains("blackhole") }) else {
                dlog("❌ BlackHole not found. Please install BlackHole 2ch.", category: .general)
                return
            }
            guard let physicalOutput = findBestPhysicalOutputDevice() else {
                dlog("❌ No physical output device found.", category: .general)
                return
            }

            guard activateBlackHoleRoute(output: physicalOutput) else {
                errorLog("Cannot start test routing", category: .routing)
                return
            }
            selectedInputDevice = blackHoleInput

            dlog("🎛️ Test routing configured", category: .general)
            dlog("   Audio flows: System → BlackHole → CoreAudioEngine → \(physicalOutput.name)", category: .general)
        }
    }

    // MARK: - Diagnostics: Route to Built-in Output

    func routeToBuiltInOutput() {
        dlog("🔊 Route to Built-in Output (diagnostic)", category: .general)
        Task { @MainActor in
            await refreshDevices()

            guard let blackHoleInput = inputDevices.first(where: { $0.name.lowercased().contains("blackhole") }) else {
                dlog("❌ BlackHole not found. Please install BlackHole 2ch.", category: .general)
                return
            }

            // Try common names for built-in speakers/output
            let builtInCandidates = outputDevices.filter { device in
                let n = device.name.lowercased()
                return !n
                    .contains("blackhole") &&
                    (n.contains("built-in") || n.contains("internal") || n.contains("speakers") || n
                        .contains("macbook"))
            }
            guard let builtIn = builtInCandidates.first ?? outputDevices
                .first(where: { $0.name.lowercased().contains("built-in") }) else {
                dlog("❌ Built-in output not found", category: .general)
                return
            }

            guard activateBlackHoleRoute(output: builtIn) else {
                errorLog("Cannot route to built-in output", category: .routing)
                return
            }
            selectedInputDevice = blackHoleInput

            dlog("🎛️ Diagnostic routing configured", category: .general)
            dlog("   Audio flows: System → BlackHole → CoreAudioEngine → \(builtIn.name)", category: .general)
            dlog("   Use 'Start Test Tone' to verify output path", category: .general)
        }
    }

    func disableEQRouting(persistEnabledState: Bool = true) {
        routingSessionRequested = false
        recoveryTask?.cancel()
        recoveryTask = nil
        stopHealthMonitoring()
        removeConfigurationListeners()
        let previousBackend = activeBackend
        DiagnosticEventStore.shared.record(
            "routing.disable.request",
            details: [
                "backend": previousBackend.rawValue,
                "persistEnabledState": "\(persistEnabledState)"
            ]
        )
        dlog(
            "Disabling EQ routing, restoring to: \(originalSystemOutputDevice?.name ?? "Unknown")",
            level: .info,
            category: .routing
        )

        // Drop any pending wake restart — routing is off on purpose now.
        wakeRestartTask?.cancel()
        wakeRestartTask = nil
        removeBlackHoleVolumeListeners()
        if #available(macOS 14.4, *), let nativeEngine = processTapEngineStorage as? ProcessTapEngine {
            nativeEngine.stop()
        }
        processTapEngineStorage = nil
        wasRoutingBeforeSleep = false
        activeInputUID = nil
        activeOutputUID = nil
        activeBackend = .none

        // Keep the enabled flag in sync even when this runs from an automatic
        // recovery path (device vanished) rather than the user's toggle —
        // otherwise the menu bar keeps claiming EQ is on after routing died.
        CoreAudioEngine.shared.setEnabled(false)
        if persistEnabledState {
            UserDefaults.standard.set(false, forKey: "eqWasEnabled")
        }

        // Stop CoreAudioEngine
        CoreAudioEngine.shared.stop()

        CoreAudioEngine.shared.restoreDeviceSampleRates()
        if previousBackend == .blackHole {
            restoreOriginalSystemOutputDevice()
        }
    }

    @discardableResult
    func setAsDefaultOutputDevice(_ device: AudioDevice) -> Bool {
        defaultOutputRequestGeneration &+= 1
        defaultOutputObservation.willWrite(device.id)
        let result = DefaultOutputSwitch.perform(requested: device.id, set: { requested in
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var deviceID = requested
            return AudioObjectSetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID
            )
        }, read: {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var observed = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &observed
            )
            return (status, observed)
        })
        DiagnosticEventStore.shared.record("routing.defaultOutput.verified", details: [
            "result": result.success ? "success" : "failed",
            "status": "\(result.status)", "outputKind": diagnosticDeviceKind(device)
        ])
        if !result.success {
            dlog("Default output switch/readback failed: \(result.status)", level: .error, category: .routing)
        }
        return result.success
    }

    // MARK: - System Output Device Management

    private func saveCurrentSystemOutputDevice() {
        guard let device = currentSystemOutputDevice() else { return }

        // Never save BlackHole as the "original" output. If a previous session
        // crashed while routing, the system default is already BlackHole, and
        // saving it would make restore a no-op — leaving the user with no sound.
        if device.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase) {
            DiagnosticEventStore.shared.record("routing.originalOutput.recovered")
            dlog("System default is BlackHole; recovering original from persisted UID", category: .routing)
            if let savedUID = UserDefaults.standard.string(forKey: originalOutputUIDKey),
               let recovered = outputDevices.first(where: { $0.uid == savedUID }) {
                originalSystemOutputDevice = recovered
            }
            return
        }

        originalSystemOutputDevice = device
        UserDefaults.standard.set(device.uid, forKey: originalOutputUIDKey)
        DiagnosticEventStore.shared.record(
            "routing.originalOutput.saved",
            details: ["outputKind": diagnosticDeviceKind(device)]
        )
        dlog("Saved original system output: \(device.name)", category: .routing)
    }

    private func currentSystemOutputDevice() -> AudioDevice? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            DiagnosticEventStore.shared.record("routing.defaultOutput.readFailed", details: ["status": "\(status)"])
            return nil
        }
        return outputDevices.first(where: { $0.id == deviceID })
    }

    private func currentSystemInputDevice() -> AudioDevice? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr else { return nil }
        return inputDevices.first(where: { $0.id == deviceID })
    }

    func restoreOriginalSystemOutputDevice() {
        // Only attempt a device that is actually enumerated right now — trying
        // one that just vanished (e.g. the USB DAC we're disabling EQ because
        // of) always fails and pops the "manual setup required" alert for a
        // routine unplug instead of a real problem.
        if let originalDevice = originalSystemOutputDevice,
           let currentDevice = outputDevices.first(where: { $0.uid == originalDevice.uid }) {
            dlog("Restoring original system output: \(currentDevice.name)", category: .routing)
            if restoreSystemOutput(to: currentDevice) { return }
        }

        // Fallback: recover by persisted UID (e.g. after a crash left no in-memory value).
        if let savedUID = UserDefaults.standard.string(forKey: originalOutputUIDKey),
           let recovered = outputDevices.first(where: {
               $0.uid == savedUID &&
                   !$0.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase)
           }) {
            dlog("Restoring original system output by UID: \(recovered.name)", category: .routing)
            if restoreSystemOutput(to: recovered) { return }
        }

        // Last resort: any non-BlackHole physical output so the user keeps hearing sound.
        if let physical = findBestPhysicalOutputDevice() {
            dlog(
                "No saved original; falling back to physical output: \(physical.name)",
                level: .warning,
                category: .routing
            )
            restoreSystemOutput(to: physical)
        } else {
            dlog(
                "No original system output device saved and no physical fallback found",
                level: .warning,
                category: .routing
            )
        }
    }

    @discardableResult
    private func restoreSystemOutput(to device: AudioDevice) -> Bool {
        if let blackHole = blackHoleOutputDevice() {
            transferOutputVolume(from: blackHole, to: device)
        }
        return setAsDefaultOutputDevice(device)
    }

    private func blackHoleOutputDevice() -> AudioDevice? {
        outputDevices.first {
            $0.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase)
        }
    }

    @discardableResult
    private func transferOutputVolume(from source: AudioDevice, to destination: AudioDevice) -> Bool {
        let fallback = destination.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase)
            ? OutputVolumeState(scalar: 1, isMuted: false)
            : nil
        let sourceState = Self.outputVolumeState(for: source.id)
        let state = sourceState ?? fallback
        let didTransfer = OutputVolumeTransfer.transfer(
            from: source.id,
            to: destination.id,
            read: Self.outputVolumeState,
            write: { state, deviceID in
                Self.applyOutputVolumeState(
                    state,
                    replacing: Self.outputVolumeState(for: deviceID),
                    to: deviceID
                )
            },
            fallback: fallback
        )
        var details = [
            "destinationKind": diagnosticDeviceKind(destination),
            "result": didTransfer ? "success" : "notApplied",
            "sourceKind": diagnosticDeviceKind(source),
            "sourceSoftwareVolume": sourceState == nil ? "unavailable" : "available",
            "usedMaximumFallback": "\(sourceState == nil && fallback != nil)"
        ]
        if let state {
            details["requestedScalar"] = String(format: "%.3f", state.scalar)
            details["requestedMute"] = state.isMuted.map { String($0) } ?? "unavailable"
        }
        DiagnosticEventStore.shared.record("routing.volumeTransfer", details: details)
        if didTransfer {
            dlog(
                "Copied output volume from \(source.name) to \(destination.name)",
                category: .routing
            )
        }
        return didTransfer
    }

    func diagnosticSummary() -> String {
        let systemInput = currentSystemInputDevice()
        let systemOutput = currentSystemOutputDevice()
        let blackHole = blackHoleOutputDevice()
        let blackHoleVolume = blackHole.flatMap { Self.outputVolumeState(for: $0.id) }
        let blackHoleSettable = blackHole.map { Self.outputVolumeIsSettable(for: $0.id) } ?? false
        let physicalVolume = selectedOutputDevice.flatMap { Self.outputVolumeState(for: $0.id) }
        let physicalAlive = selectedOutputDevice.flatMap { Self.deviceIsAlive($0.id) }
        let selectedOutputPresent = selectedOutputDevice.map { selected in
            outputDevices.contains(where: { $0.uid == selected.uid && $0.id == selected.id })
        } ?? false
        let core = CoreAudioEngine.shared

        return """
        Routing active: \(isRoutingActive)
        Active backend: \(activeBackend.rawValue)
        Backend preference: \(backendPreference.rawValue)
        System input kind: \(diagnosticDeviceKind(systemInput))
        System output kind: \(diagnosticDeviceKind(systemOutput))
        Selected output kind: \(diagnosticDeviceKind(selectedOutputDevice))
        System output matches BlackHole: \(systemOutput?.id == blackHole?.id && blackHole != nil)
        Engine input matches BlackHole: \(core.currentInputDeviceID == blackHole?.id && blackHole != nil)
        Engine output matches selected device: \(core.currentOutputDeviceID == selectedOutputDevice?.id && selectedOutputDevice != nil)
        Selected output present: \(selectedOutputPresent)
        Selected output alive: \(physicalAlive.map { String($0) } ?? "unavailable")
        Selected output volume readable: \(physicalVolume != nil)
        Selected output scalar: \(physicalVolume.map { String(format: "%.3f", $0.scalar) } ?? "unavailable")
        Selected output muted: \(physicalVolume?.isMuted.map { String($0) } ?? "unavailable")
        BlackHole detected: \(blackHoleDetected)
        BlackHole volume readable: \(blackHoleVolume != nil)
        BlackHole volume settable: \(blackHoleSettable)
        BlackHole scalar: \(blackHoleVolume.map { String(format: "%.3f", $0.scalar) } ?? "unavailable")
        BlackHole muted: \(blackHoleVolume?.isMuted.map { String($0) } ?? "unavailable")
        """
    }

    private static func deviceIsAlive(_ deviceID: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    nonisolated private static func outputVolumeIsSettable(for deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable: DarwinBoolean = false
        return AudioObjectHasProperty(deviceID, &address) &&
            AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr &&
            isSettable.boolValue
    }

    nonisolated private static func outputVolumeState(for deviceID: AudioDeviceID) -> OutputVolumeState? {
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &volumeAddress) else { return nil }

        var scalar: Float = 0
        var volumeSize = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(
            deviceID,
            &volumeAddress,
            0,
            nil,
            &volumeSize,
            &scalar
        ) == noErr else { return nil }

        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var muteValue: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let isMuted: Bool? = if AudioObjectHasProperty(deviceID, &muteAddress),
                                AudioObjectGetPropertyData(
                                    deviceID,
                                    &muteAddress,
                                    0,
                                    nil,
                                    &muteSize,
                                    &muteValue
                                ) == noErr {
            muteValue != 0
        } else {
            nil
        }

        return OutputVolumeState(scalar: scalar, isMuted: isMuted)
    }

    nonisolated private static func applyOutputVolumeState(
        _ state: OutputVolumeState,
        replacing observed: OutputVolumeState? = nil,
        to deviceID: AudioDeviceID
    ) -> Bool {
        if BlackHoleVolumeChangePolicy.needsVolumeWrite(from: observed, to: state) {
            var volumeAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var canSetVolume: DarwinBoolean = false
            guard AudioObjectHasProperty(deviceID, &volumeAddress),
                  AudioObjectIsPropertySettable(deviceID, &volumeAddress, &canSetVolume) == noErr,
                  canSetVolume.boolValue else { return false }

            var scalar = state.scalar
            let volumeSize = UInt32(MemoryLayout<Float>.size)
            guard AudioObjectSetPropertyData(
                deviceID,
                &volumeAddress,
                0,
                nil,
                volumeSize,
                &scalar
            ) == noErr else { return false }
        }

        guard BlackHoleVolumeChangePolicy.needsMuteWrite(from: observed, to: state),
              let isMuted = state.isMuted else { return true }
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var canSetMute: DarwinBoolean = false
        guard AudioObjectHasProperty(deviceID, &muteAddress),
              AudioObjectIsPropertySettable(deviceID, &muteAddress, &canSetMute) == noErr,
              canSetMute.boolValue else { return true }

        var muteValue: UInt32 = isMuted ? 1 : 0
        let muteSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectSetPropertyData(
            deviceID,
            &muteAddress,
            0,
            nil,
            muteSize,
            &muteValue
        )
        return true
    }

    private func installBlackHoleVolumeListeners(deviceID: AudioDeviceID) {
        removeBlackHoleVolumeListeners()
        monitoredBlackHoleDeviceID = deviceID
        expectedBlackHoleOutputVolume = Self.outputVolumeState(for: deviceID)

        let selectors = [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute]
        let scopes = [kAudioObjectPropertyScopeInput, kAudioObjectPropertyScopeOutput]

        for selector in selectors {
            for scope in scopes {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: scope,
                    mElement: kAudioObjectPropertyElementMain
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }

                let listener: AudioObjectPropertyListenerBlock = { _, _ in
                    Task { @MainActor in
                        AudioRouter.shared.handleBlackHoleVolumeChange(scope: scope)
                    }
                }
                let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
                if status == noErr {
                    blackHoleVolumeListeners.append(
                        AudioPropertyListenerRegistration(deviceID: deviceID, address: address, block: listener)
                    )
                } else {
                    dlog(
                        "Could not monitor BlackHole volume property: \(status)",
                        level: .warning,
                        category: .routing
                    )
                }
            }
        }
    }

    private func removeBlackHoleVolumeListeners() {
        blackHoleVolumeChangeTask?.cancel()
        blackHoleVolumeChangeTask = nil
        pendingBlackHoleVolumeChangeScopes.removeAll()
        expectedBlackHoleOutputVolume = nil
        monitoredBlackHoleDeviceID = nil

        for registration in blackHoleVolumeListeners {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                registration.deviceID,
                &address,
                DispatchQueue.main,
                registration.block
            )
        }
        blackHoleVolumeListeners.removeAll()
    }

    @MainActor
    private func handleBlackHoleVolumeChange(scope: AudioObjectPropertyScope) {
        guard isRoutingOwned, monitoredBlackHoleDeviceID != nil else { return }
        pendingBlackHoleVolumeChangeScopes.insert(scope)
        blackHoleVolumeChangeTask?.cancel()
        blackHoleVolumeChangeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: BlackHoleVolumeChangePolicy.coalescingDelayNanoseconds)
            guard !Task.isCancelled,
                  self.isRoutingOwned,
                  let deviceID = self.monitoredBlackHoleDeviceID else { return }

            let scopes = self.pendingBlackHoleVolumeChangeScopes
            self.pendingBlackHoleVolumeChangeScopes.removeAll()

            switch BlackHoleVolumeChangePolicy.action(for: scopes) {
            case .acceptObserved:
                self.expectedBlackHoleOutputVolume = Self.outputVolumeState(for: deviceID)
            case .restoreExpected:
                guard let expected = self.expectedBlackHoleOutputVolume,
                      let observed = Self.outputVolumeState(for: deviceID),
                      observed != expected else { return }
                let restored = Self.applyOutputVolumeState(expected, replacing: observed, to: deviceID)
                DiagnosticEventStore.shared.record(
                    "routing.blackHoleInputVolumeOverride",
                    details: [
                        "observedScalar": String(format: "%.3f", observed.scalar),
                        "restoredScalar": String(format: "%.3f", expected.scalar),
                        "result": restored ? "success" : "failed"
                    ]
                )
            case .ignore:
                break
            }
        }
    }

    // MARK: - BlackHole Detection

    private func detectBlackHole() {
        let wasDetected = blackHoleDetected
        blackHoleDetected = outputDevices.contains { device in
            device.name.lowercased().contains("blackhole")
        }

        // Only log when state changes
        if blackHoleDetected != wasDetected {
            DiagnosticEventStore.shared.record(
                "routing.blackHoleAvailability",
                details: ["available": "\(blackHoleDetected)"]
            )
            if blackHoleDetected {
                dlog("BlackHole detected", category: .routing)
            } else {
                dlog("BlackHole not found", level: .warning, category: .routing)
            }
        }
    }

    // MARK: - Status Update

    private func updateStatus() {
        let nativeAvailable = if #available(macOS 14.4, *) {
            true
        } else {
            false
        }

        if selectedOutputDevice != nil,
           backendPreference != .blackHole,
           nativeAvailable {
            statusMessage = "✅ Ready for native routing"
            isRoutingActive = true
        } else if backendPreference != .native,
                  blackHoleDetected,
                  selectedInputDevice != nil,
                  selectedOutputDevice != nil {
            statusMessage = "✅ Ready for routing"
            isRoutingActive = true
        } else if !blackHoleDetected {
            statusMessage = "⚠️ BlackHole not installed"
            isRoutingActive = false
        } else if selectedInputDevice == nil {
            statusMessage = "⚠️ Select input device"
            isRoutingActive = false
        } else if selectedOutputDevice == nil {
            statusMessage = "⚠️ Select output device"
            isRoutingActive = false
        } else {
            statusMessage = "ℹ️ Configure routing"
            isRoutingActive = false
        }
    }

    // MARK: - Device Change Listener

    private func setupDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listenerBlock: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in
                let router = AudioRouter.shared
                router.deviceChangeDebounceTask?.cancel()
                router.deviceChangeDebounceTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms debounce
                    guard !Task.isCancelled else { return }
                    await router.refreshDevices()
                    guard !Task.isCancelled else { return }
                    router.handleDeviceTopologyChange()
                }
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &propertyAddress, DispatchQueue.main, listenerBlock
        )
        if status != noErr {
            DiagnosticEventStore.shared.record("routing.listener.failed", details: [
                "operation": "addDeviceList", "status": "\(status)"
            ])
        }
    }

    private func setupDefaultOutputChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main
        ) { _, _ in
            Task { @MainActor in
                let router = AudioRouter.shared
                router.defaultOutputChangeTask?.cancel()
                router.defaultOutputChangeTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    await router.refreshDevices()
                    guard !Task.isCancelled else { return }
                    router.handleDefaultOutputChange()
                }
            }
        }
        if status != noErr {
            DiagnosticEventStore.shared.record("routing.listener.failed", details: [
                "operation": "addDefaultOutput", "status": "\(status)"
            ])
        }
    }

    @MainActor
    private func handleDefaultOutputChange() {
        guard let device = currentSystemOutputDevice() else { return }
        let action = defaultOutputObservation.action(
            observed: device.id, sessionRequested: routingSessionRequested,
            isVirtual: device.name.lowercased().contains(AppConstants.DeviceNames.blackHoleLowercase),
            isCurrentNativeOutput: activeBackend == .native && activeOutputUID == device.uid &&
                CoreAudioEngine.shared.currentOutputDeviceID == device.id,
            sleepOrWakePending: wasRoutingBeforeSleep || wakeRestartTask != nil
        )
        guard action != .ignore else { return }
        originalSystemOutputDevice = device
        UserDefaults.standard.set(device.uid, forKey: originalOutputUIDKey)
        preferredOutputUID = device.uid
        selectedOutputDevice = device
        // A genuine external selection supersedes a pending recovery. Own restore writes never reach here.
        guard action == .rebuild else { return }
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryBudget = AudioRecoveryBudget()
        recoveryFallbackAttempted = false
        dlog("System output changed to \(device.name) — rebuilding EQ routing", category: .routing)
        enableEQRouting(forceRestart: true, reason: .systemOutputChanged)
    }

    /// Runs after every debounced device-list change. Catches the states that kill
    /// audio silently while routing is active: a device that vanished, a device
    /// that came back under a new AudioDeviceID (the units still point at the old
    /// one, which renders as permanent silence rather than an error), and — not
    /// gated on the engine currently running — a wake restart that failed to find
    /// its devices in time, so a later arrival still gets picked up.
    @MainActor
    private func handleDeviceTopologyChange() {
        guard recoveryTask == nil, wakeRestartTask == nil, !wasRoutingBeforeSleep else { return }
        if activeBackend == .native {
            guard let outputUID = activeOutputUID else { return }
            if let wantedUID = preferredOutputUID,
               wantedUID != outputUID,
               outputDevices.contains(where: { $0.uid == wantedUID }) {
                requestAutomaticRecovery(reason: .preferredOutputReturned)
                return
            }
            guard let output = outputDevices.first(where: { $0.uid == outputUID }) else {
                activeOutputUID = nil
                guard findBestPhysicalOutputDevice() != nil else {
                    requestAutomaticRecovery(reason: .outputDisconnected)
                    return
                }
                requestAutomaticRecovery(reason: .outputDisconnected)
                return
            }
            if !CoreAudioEngine.shared.isRunning || CoreAudioEngine.shared.currentOutputDeviceID != output.id {
                requestAutomaticRecovery(reason: .deviceRecovery)
            }
            return
        }

        guard let inputUID = activeInputUID,
              let outputUID = activeOutputUID else {
            if !isRoutingOwned {
                CoreAudioEngine.shared.restoreDeviceSampleRates()
            }
            return
        }
        let engine = CoreAudioEngine.shared

        // BlackHole gone (driver uninstalled or reset) — nothing left to capture.
        guard let input = inputDevices.first(where: { $0.uid == inputUID }) else {
            dlog("BlackHole disappeared while routing — scheduling recovery", level: .warning, category: .routing)
            requestAutomaticRecovery(reason: .deviceRecovery)
            return
        }

        // The device we actually want reappeared while we were on a fallback —
        // switch back to it rather than staying on the fallback forever.
        if let wantedUID = preferredOutputUID,
           wantedUID != outputUID,
           outputDevices.contains(where: { $0.uid == wantedUID }) {
            dlog("Preferred output reappeared — switching back", level: .info, category: .routing)
            requestAutomaticRecovery(reason: .preferredOutputReturned)
            return
        }

        guard let output = outputDevices.first(where: { $0.uid == outputUID }) else {
            // Output unplugged: forget it so preferredOutputDevice() auto-picks
            // whatever is left, then rebuild onto that device.
            activeOutputUID = nil
            guard let fallback = findBestPhysicalOutputDevice() else {
                dlog(
                    "Active output disappeared and no fallback exists — disabling EQ",
                    level: .warning,
                    category: .routing
                )
                requestAutomaticRecovery(reason: .outputDisconnected)
                return
            }
            dlog(
                "Active output disappeared — rebuilding onto \(fallback.name)",
                level: .warning,
                category: .routing
            )
            requestAutomaticRecovery(reason: .outputDisconnected)
            return
        }

        if !engine.isRunning || input.id != engine.currentInputDeviceID || output.id != engine.currentOutputDeviceID {
            dlog(
                "Rebuilding engine (running=\(engine.isRunning), " +
                    "in \(engine.currentInputDeviceID)→\(input.id), " +
                    "out \(engine.currentOutputDeviceID)→\(output.id))",
                level: .warning,
                category: .routing
            )
            requestAutomaticRecovery(reason: .deviceRecovery)
        }
    }

    // MARK: - Sleep / Wake

    private func setupSleepWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(handleWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc
    private func handleWillSleep(_ notification: Notification) {
        // A pending wake restart means a previous sleep is still being recovered
        // from (e.g. the lid closed again inside the 2.5s post-wake wait). Cancel
        // it and treat this as "was routing" too, or the intent to resume gets
        // silently dropped and wake never restores audio.
        let hadPendingWakeRestart = wakeRestartTask != nil
        guard routingSessionRequested || CoreAudioEngine.shared.isRunning || hadPendingWakeRestart else { return }

        DiagnosticEventStore.shared.record("routing.sleep")
        recoveryTask?.cancel()
        recoveryTask = nil
        stopHealthMonitoring()
        removeConfigurationListeners()

        wakeRestartTask?.cancel()
        wakeRestartTask = nil
        wasRoutingBeforeSleep = true

        removeBlackHoleVolumeListeners()
        if #available(macOS 14.4, *), let nativeEngine = processTapEngineStorage as? ProcessTapEngine {
            nativeEngine.stop()
        }
        processTapEngineStorage = nil
        CoreAudioEngine.shared.stop()
        dlog("Sleep — engine stopped, routing will be restored on wake", level: .info, category: .routing)
    }

    @objc
    private func handleDidWake(_ notification: Notification) {
        guard wasRoutingBeforeSleep else { return }
        DiagnosticEventStore.shared.record("routing.wake.scheduled")
        wasRoutingBeforeSleep = false

        wakeRestartTask?.cancel()
        wakeRestartTask = Task { @MainActor in
            // USB and Bluetooth outputs reappear a couple of seconds after wake,
            // often with a different AudioDeviceID, so refresh before rebuilding.
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            await self.refreshDevices()
            guard !Task.isCancelled else { return }
            dlog("Wake — restoring EQ routing", level: .info, category: .routing)
            self.wakeRestartTask = nil
            self.requestAutomaticRecovery(reason: .wake)
        }
    }

    // MARK: - Bounded automatic recovery (control thread only)

    private func callbackSnapshots() -> [AudioCallbackHealthSnapshot] {
        if #available(macOS 14.4, *), let tap = processTapEngineStorage as? ProcessTapEngine {
            return [tap.callbackHealth.snapshot()]
        }
        return [CoreAudioEngine.shared.inputHealth.snapshot(), CoreAudioEngine.shared.outputHealth.snapshot()]
    }

    private func startHealthMonitoring() {
        stopHealthMonitoring()
        let now = ProcessInfo.processInfo.systemUptime
        healthPolicies = callbackSnapshots().map { AudioRouteHealthPolicy(now: now, snapshot: $0) }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkRouteHealth() }
        healthTimer = timer
        timer.resume()
    }

    private func stopHealthMonitoring() {
        healthTimer?.cancel()
        healthTimer = nil
        healthPolicies = []
    }

    private func checkRouteHealth() {
        guard routingSessionRequested, recoveryTask == nil, !wasRoutingBeforeSleep,
              wakeRestartTask == nil, activeBackend != .none else { return }
        let configurationValid: Bool = if #available(macOS 14.4, *),
                                          let tap = processTapEngineStorage as? ProcessTapEngine {
            tap.validateRunningConfiguration()
        } else {
            CoreAudioEngine.shared.validateRunningConfiguration()
        }
        guard configurationValid else {
            DiagnosticEventStore.shared.record("routing.health.failed", details: ["reason": "configurationChanged"])
            requestAutomaticRecovery(reason: .deviceRecovery)
            return
        }
        let snapshots = callbackSnapshots()
        let now = ProcessInfo.processInfo.systemUptime
        guard snapshots.count == healthPolicies.count else { return }
        for index in snapshots.indices {
            if let failure = healthPolicies[index].evaluate(snapshots[index], now: now) {
                DiagnosticEventStore.shared.record("routing.health.failed", details: [
                    "reason": failure.rawValue, "path": "\(index)",
                    "fault": "\(snapshots[index].lastFault)", "status": "\(snapshots[index].lastStatus)",
                    "callbacks": "\(snapshots[index].callbacks)", "validBlocks": "\(snapshots[index].validBlocks)"
                ])
                requestAutomaticRecovery(reason: .healthRecovery)
                return
            }
        }
        if !CoreAudioEngine.shared.isRunning {
            requestAutomaticRecovery(reason: .healthRecovery)
            return
        }
        if snapshots.allSatisfy({ $0.validBlocks > 0 }) {
            recoveryBudget.noteHealthy(now: now)
            if recoveryBudget.attempts == 0 { recoveryFallbackAttempted = false }
        }
    }

    private func requestAutomaticRecovery(reason: RoutingRequestReason) {
        guard routingSessionRequested, recoveryTask == nil, !wasRoutingBeforeSleep else { return }
        if recoveryBudget.attempts == 0 {
            recoveryBackend = activeBackend
            recoveryProcessingEnabled = CoreAudioEngine.shared.isEnabled
            recoveryOutput = currentSystemOutputDevice()
        }
        stopActiveBackendForRestart()
        guard let delay = recoveryBudget.nextDelay() else {
            // One optional fallback, never an endless Native/BlackHole oscillation.
            if recoveryBackend == .native, backendPreference == .automatic,
               blackHoleDetected, !recoveryFallbackAttempted, let output = preferredOutputDevice() {
                recoveryFallbackAttempted = true
                let restored = AudioRouteActivation.perform(start: {
                    startBlackHoleRouting(output: output, persistEnabledStateOnFailure: false)
                }, rollback: {
                    rollbackFailedActivation(previousOutput: recoveryOutput)
                })
                if restored {
                    CoreAudioEngine.shared.setEnabled(recoveryProcessingEnabled)
                    DiagnosticEventStore.shared.record("routing.recovery.fallback", details: ["backend": "blackHole"])
                    return
                }
            }
            DiagnosticEventStore.shared.record("routing.recovery.exhausted", details: [
                "attempts": "\(recoveryBudget.attempts)", "trigger": reason.rawValue
            ])
            disableEQRouting()
            restoreOriginalSystemOutputDevice()
            return
        }
        DiagnosticEventStore.shared.record("routing.recovery.scheduled", details: [
            "attempt": "\(recoveryBudget.attempts)", "delaySeconds": "\(delay)", "trigger": reason.rawValue
        ])
        recoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.routingSessionRequested else { return }
            await self.refreshDevices()
            guard !Task.isCancelled, self.routingSessionRequested else { return }
            self.recoveryTask = nil
            let succeeded = self.enableEQRouting(
                forceRestart: true, persistEnabledStateOnFailure: false, reason: .healthRecovery
            )
            if succeeded {
                CoreAudioEngine.shared.setEnabled(self.recoveryProcessingEnabled)
                DiagnosticEventStore.shared.record("routing.recovery.restarted", details: [
                    "attempt": "\(self.recoveryBudget.attempts)", "trigger": reason.rawValue
                ])
            } else {
                self.requestAutomaticRecovery(reason: reason)
            }
        }
    }

    private func scheduleConfigurationRecovery(reason: RoutingRequestReason) {
        guard routingSessionRequested else { return }
        configurationChangeTask?.cancel()
        configurationChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.configurationChangeTask = nil
            self.requestAutomaticRecovery(reason: reason)
        }
    }

    private func installConfigurationListeners(devices: [AudioDeviceID], includeRate: Bool) {
        removeConfigurationListeners()
        var selectors: [AudioObjectPropertySelector] = [
            kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyBufferFrameSize
        ]
        if includeRate { selectors.append(kAudioDevicePropertyNominalSampleRate) }
        for deviceID in devices {
            for selector in selectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let reason: RoutingRequestReason = selector == kAudioDevicePropertyNominalSampleRate
                    ? .sampleRateChanged : .deviceRecovery
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.scheduleConfigurationRecovery(reason: reason)
                }
                let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, block)
                if status == noErr {
                    configurationListeners.append(AudioPropertyListenerRegistration(
                        deviceID: deviceID, address: address, block: block
                    ))
                } else {
                    DiagnosticEventStore.shared.record("routing.listener.failed", details: [
                        "operation": "addConfiguration", "selector": "\(selector)", "status": "\(status)"
                    ])
                }
            }
        }
    }

    private func removeConfigurationListeners() {
        configurationChangeTask?.cancel()
        configurationChangeTask = nil
        for listener in configurationListeners {
            var address = listener.address
            let status = AudioObjectRemovePropertyListenerBlock(listener.deviceID, &address, .main, listener.block)
            if status != noErr {
                DiagnosticEventStore.shared.record("routing.listener.failed", details: [
                    "operation": "removeConfiguration", "status": "\(status)"
                ])
            }
        }
        configurationListeners = []
    }

    // MARK: - Manual Setup Alert

    private func showManualSetupAlert(targetDevice: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = LocalizationManager.shared.localized(.manualSetupRequired)
            alert.informativeText = String(
                format: LocalizationManager.shared.localized(.manualSetupInstructions),
                targetDevice,
                targetDevice,
                targetDevice,
                targetDevice
            )
            alert.alertStyle = .informational
            alert.addButton(withTitle: LocalizationManager.shared.localized(.openSystemSettings))
            alert.addButton(withTitle: LocalizationManager.shared.localized(.openAudioMIDISetupButton))
            alert.addButton(withTitle: "OK")

            let response = alert.runModal()

            switch response {
            case .alertFirstButtonReturn:
                // Open System Settings → Sound
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.sound") {
                    NSWorkspace.shared.open(url)
                }
            case .alertSecondButtonReturn:
                // Open Audio MIDI Setup
                self.openAudioMIDISetup()
            default:
                break
            }
        }
    }

    // MARK: - External Links

    func openBlackHoleDownload() {
        if let url = URL(string: AppConstants.URLs.blackHoleReleases) {
            NSWorkspace.shared.open(url)
        }
    }

    func openAudioMIDISetup() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Audio MIDI Setup.app")
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            if let error {
                dlog("❌ Failed to open Audio MIDI Setup: \(error.localizedDescription)", category: .general)
            }
        }
    }

    // MARK: - Multi-Output Device Management

    func createMultiOutputDevice() {
        dlog("🔧 Opening Audio MIDI Setup to set BlackHole as System Output…", category: .general)
        openAudioMIDISetup()

        // Інструкції для користувача (BlackHole-only)
        dlog("Instructions: Set BlackHole as System Output via Audio MIDI Setup", category: .routing)

        // Показуємо діалог з інструкціями BlackHole-only
        let alert = NSAlert()
        alert.messageText = LocalizationManager.shared.localized(.setBlackHoleAsSystemOutputTitle)
        alert.informativeText = LocalizationManager.shared.localized(.setBlackHoleAsSystemOutputInstructions)
        alert.alertStyle = .informational
        alert.addButton(withTitle: LocalizationManager.shared.localized(.openAudioMIDISetupButton))
        alert.addButton(withTitle: LocalizationManager.shared.localized(.testAudioButton))
        alert.addButton(withTitle: LocalizationManager.shared.localized(.cancel))

        let response = alert.runModal()

        switch response {
        case .alertFirstButtonReturn:
            openAudioMIDISetup()
        case .alertSecondButtonReturn:
            testAudioRouting()
        default:
            break
        }
    }
}
