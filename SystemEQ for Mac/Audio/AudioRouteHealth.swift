import CoreAudio
import Foundation

// MARK: - Real-time callback health

nonisolated enum AudioCallbackFault: Int32 {
    case none = 0
    case missingInput = 1
    case invalidInputFormat = 2
    case oversizedBlock = 3
    case missingOutput = 4
    case invalidOutputFormat = 5
    case renderFailed = 6
}

nonisolated struct AudioCallbackHealthSnapshot {
    var callbacks: Int64 = 0
    var validBlocks: Int64 = 0
    var failures: Int64 = 0
    var consecutiveFailures: Int32 = 0
    var lastFault: Int32 = 0
    var lastStatus: OSStatus = noErr
}

/// 🔧 One callback writer; control-thread snapshots. No locks, allocation, logging or dispatch in note methods.
nonisolated final class AudioCallbackHealth: @unchecked Sendable {
    private let counters = UnsafeMutablePointer<SEQAtomicInt64>.allocate(capacity: 3)
    private let flags = UnsafeMutablePointer<SEQAtomicInt32>.allocate(capacity: 3)

    init() {
        for index in 0..<3 {
            seq_atomic_int64_init(counters + index, 0)
            seq_atomic_int32_init(flags + index, 0)
        }
    }

    deinit {
        counters.deallocate()
        flags.deallocate()
    }

    /// Only reset while the callback is stopped.
    func reset() {
        for index in 0..<3 {
            seq_atomic_int64_store_release(counters + index, 0)
            seq_atomic_int32_store_release(flags + index, 0)
        }
    }

    @inline(__always)
    func noteInvocation() {
        seq_atomic_int64_fetch_add(counters, 1)
    }

    @inline(__always)
    func noteValidBlock() {
        seq_atomic_int64_fetch_add(counters + 1, 1)
        seq_atomic_int32_store_release(flags, 0)
    }

    @inline(__always)
    func noteIdle() {
        // A zero-frame callback is a heartbeat, not a broken route.
        seq_atomic_int32_store_release(flags, 0)
    }

    @inline(__always)
    func noteFailure(_ fault: AudioCallbackFault, status: OSStatus = noErr) {
        seq_atomic_int32_store_release(flags + 1, fault.rawValue)
        seq_atomic_int32_store_release(flags + 2, status)
        seq_atomic_int64_fetch_add(counters + 2, 1)
        seq_atomic_int32_fetch_add(flags, 1)
    }

    func snapshot() -> AudioCallbackHealthSnapshot {
        AudioCallbackHealthSnapshot(
            callbacks: Int64(seq_atomic_int64_load_acquire(counters)),
            validBlocks: Int64(seq_atomic_int64_load_acquire(counters + 1)),
            failures: Int64(seq_atomic_int64_load_acquire(counters + 2)),
            consecutiveFailures: seq_atomic_int32_load(flags),
            lastFault: seq_atomic_int32_load(flags + 1),
            lastStatus: seq_atomic_int32_load(flags + 2)
        )
    }
}

// MARK: - Control-thread recovery policy

struct AudioRouteHealthPolicy {
    enum Failure: String {
        case invalidCallbacks
        case callbacksStopped
    }

    private var started: TimeInterval
    private var lastProgress: TimeInterval
    private var lastCallbacks: Int64

    init(now: TimeInterval, snapshot: AudioCallbackHealthSnapshot = .init()) {
        started = now
        lastProgress = now
        lastCallbacks = snapshot.callbacks
    }

    mutating func evaluate(_ snapshot: AudioCallbackHealthSnapshot, now: TimeInterval) -> Failure? {
        if snapshot.callbacks != lastCallbacks {
            lastCallbacks = snapshot.callbacks
            lastProgress = now
        }
        guard now - started >= 3 else { return nil }
        if snapshot.consecutiveFailures >= 8 { return .invalidCallbacks }
        if now - lastProgress >= 5 { return .callbacksStopped }
        return nil
    }
}

struct AudioRecoveryBudget {
    private(set) var attempts = 0
    private var healthySince: TimeInterval?

    mutating func nextDelay() -> TimeInterval? {
        healthySince = nil
        guard attempts < 3 else { return nil }
        let delay = pow(2.0, Double(attempts))
        attempts += 1
        return delay
    }

    mutating func noteHealthy(now: TimeInterval) {
        if healthySince == nil { healthySince = now }
        if let healthySince, now - healthySince >= 30 { attempts = 0 }
    }
}

// MARK: - Verified activation

enum AudioRouteActivation {
    static func perform(start: () -> Bool, rollback: () -> Void) -> Bool {
        guard start() else {
            rollback()
            return false
        }
        return true
    }
}

enum DefaultOutputSwitch {
    static func perform(
        requested: AudioDeviceID,
        set: (AudioDeviceID) -> OSStatus,
        read: () -> (OSStatus, AudioDeviceID)
    ) -> (success: Bool, status: OSStatus) {
        let status = set(requested)
        guard status == noErr else { return (false, status) }
        let (readStatus, observed) = read()
        guard readStatus == noErr else { return (false, readStatus) }
        return (observed == requested, observed == requested ? noErr : kAudioHardwareUnspecifiedError)
    }
}

enum AudioStreamFormatPolicy {
    static func matches(_ observed: AudioStreamBasicDescription, expected: AudioStreamBasicDescription) -> Bool {
        let layoutFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked |
            kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh
        return observed.mSampleRate.isFinite && observed.mSampleRate > 0 &&
            abs(observed.mSampleRate - expected.mSampleRate) < 1 &&
            observed.mFormatID == kAudioFormatLinearPCM &&
            observed.mFormatFlags & layoutFlags == expected.mFormatFlags & layoutFlags &&
            observed.mBitsPerChannel == 32 && observed.mChannelsPerFrame == expected.mChannelsPerFrame &&
            observed.mBytesPerFrame == expected.mBytesPerFrame &&
            observed.mBytesPerPacket == expected.mBytesPerPacket && observed.mFramesPerPacket == 1
    }
}

enum AudioStreamConfiguration {
    static func perform(
        expected: AudioStreamBasicDescription,
        write: () -> OSStatus,
        read: () -> (OSStatus, AudioStreamBasicDescription)
    ) -> OSStatus {
        let status = write()
        guard status == noErr else { return status }
        let (readStatus, observed) = read()
        guard readStatus == noErr else { return readStatus }
        return AudioStreamFormatPolicy.matches(observed, expected: expected)
            ? noErr : kAudioHardwareUnsupportedOperationError
    }
}

/// Tracks our own HAL writes so their queued notifications cannot bypass the retry budget.
struct DefaultOutputObservation {
    enum Action: Equatable {
        case ignore
        case deferUntilWake
        case rebuild
    }

    private var ownedDeviceID: AudioDeviceID?

    mutating func willWrite(_ deviceID: AudioDeviceID) {
        ownedDeviceID = deviceID
    }

    mutating func action(
        observed: AudioDeviceID, sessionRequested: Bool, isVirtual: Bool,
        isCurrentNativeOutput: Bool, sleepOrWakePending: Bool
    ) -> Action {
        guard sessionRequested, observed != ownedDeviceID else { return .ignore }
        ownedDeviceID = nil
        guard !isVirtual, !isCurrentNativeOutput else { return .ignore }
        return sleepOrWakePending ? .deferUntilWake : .rebuild
    }
}
