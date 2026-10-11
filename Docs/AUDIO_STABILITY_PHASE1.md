# Audio routing stability — Phase 1 (R1 / R2)

## Git baseline and scope

This change is based on the open, unmerged PR #1 (`fix/eq-reset-and-factory-reset`,
head `c010e04f6780509a55e54d7e8c581e1ea90086cf`). The local reset branch and its
changes were preserved. Development takes place on `fix/audio-routing-recovery`;
the review PR targets PR #1's branch so its diff contains only this phase.
`main` is not merged or modified. Retarget this PR to `main` after PR #1 is merged.

Scope: ProcessTap/AUHAL health detection, bounded recovery, verified CoreAudio
configuration, activation rollback, and tests. Presets, reset behavior, device
profiles, EQ controls, DSP algorithms, and visualizer behavior are retained.

## R1: Detect failed paths even when the engine reports running

`AudioCallbackHealth` owns preallocated C11 atomic counters. Native render, AUHAL
capture, and AUHAL output report callback progress, successful blocks, fault type,
consecutive failures, and the last render OSStatus. Missing buffers, unexpected
channels/byte layouts, undersized outputs, oversized blocks, and failed
`AudioUnitRender` calls are observable without logging from the callback.

A control-thread watchdog runs once per second. After a three-second startup
allowance, eight consecutive invalid callbacks or five seconds without callback
progress trigger recovery. Successful zero-valued blocks count as valid audio.
Zero-frame callbacks count as heartbeats and clear the error streak. Signal
amplitude is never a recovery condition; paused playback with continuing valid or
idle callbacks does not trigger a restart.

The watchdog also reads device liveness, nominal rates, actual aggregate main
output, tap/input topology, stream formats, and AUHAL device attachments/client
formats. This catches stale HAL objects and configuration changes despite a
still-true `isRunning` flag and provides a fallback when a property listener
cannot be registered. Listener registration/removal failures are logged.

All new HAL queries, event recording, scheduling, teardown, and setup happen on
the control thread. Callbacks add only atomic updates and bounds checks. Invalid
outputs are zeroed within their advertised capacity; AUHAL also sets
`OutputIsSilence`. Existing preallocated scratch/ring buffers and vDSP processing
remain in use.

## Controlled recovery and lifecycle

A confirmed fault tears down the active route before scheduling an attempt.
Automatic retries wait 1, 2, and 4 seconds, with at most three attempts. Brief
success does not reset the budget; 30 seconds of healthy operation permits a new
budget. In automatic backend mode, an initially native route may make one final
BlackHole fallback attempt if the driver is available. A subsequent fallback
failure exhausts recovery and disables routing. An explicit user request or a
new external output selection starts a new recovery session.

Own default-output writes are tracked so their queued/coalesced notifications
cannot trigger extra restarts or bypass the budget. An external selection cancels
an obsolete pending attempt. During sleep or a pending wake refresh it updates
the desired device without prematurely starting audio.

Device-alive, buffer-size, and nominal-rate changes are coalesced. Device-list
changes re-resolve persistent UIDs to current AudioDeviceIDs, including returning
USB devices. Sleep cancels timers/listeners/pending attempts and stops callbacks;
wake refreshes the device list after 2.5 seconds and enters bounded recovery.
Disabling EQ cancels the whole session, including a restart that is waiting for a
device refresh. Reconfiguration reapplies the current EQ/preamp/output settings
and rebuilds room-correction filters at the resulting rate.

## R2: Verify configuration and roll back failed activation

Default-output selection now checks the setter OSStatus, the getter OSStatus,
and the actual returned device ID. Activation is successful only after setup and
start succeed. Failure stops partial routes, attempts to restore captured sample
rates, and restores the pre-activation physical output by UID; if it disappeared,
the existing original/preferred physical-output recovery is used. Restoration
writes are themselves verified and failures are logged. The diagnostic routing
entry points share this activation and rollback path.

Native setup verifies the aggregate's main-subdevice UID and actual output
formats, device/tap/aggregate rates, stream selection, and buffer capacity.
Property read, listener, stop, and destroy OSStatus failures are recorded.

AUHAL setup checks property writes, callback installation, initialization,
attachment IDs, and stream-format readback. Accepted formats must have the
expected Float32 PCM channel/interleaving/packet/byte layout and finite positive
rate; unexpected endian, integer, or alignment flags are rejected. Frame limits
are read back and buffers use the largest accepted capacity. Different input and
output block sizes remain supported through the ring buffer.

The physical output's selected sample rate is preserved. Only the virtual input
is aligned to it; failed alignment/readback aborts setup instead of silently
forcing the physical device to a different rate. This matters because
[Apple documents that AUHAL input does not perform sample-rate conversion](https://developer.apple.com/library/archive/qa/qa1777/_index.html).
Virtual-device rates are restored from the existing persisted UID-based map;
entries are removed only after verified restoration.

## Automated verification

`AudioRouteRecoveryTests.swift` adds 36 tests covering:

- silent and zero-frame callbacks, startup grace, stopped callbacks, transient
  errors, three-attempt exhaustion and healthy-budget reset;
- concurrent atomic health observation;
- own output notifications during retry/rollback, external selection, and wake deferral;
- injected write/read failures, mismatched default outputs, activation rollback;
- invalid Float32 formats and native input selection;
- actual ProcessTap render calls with zero/one/oversized blocks and malformed
  buffers, plus actual AUHAL output callbacks with missing/short/invalid output
  and sentinel checks outside advertised writable capacity.

No test opens a hardware audio route. Fault-injection tests cover policies and
verification helpers; they do not simulate a USB driver or the full live HAL.

Commands (run from the repository root):

```sh
xcodebuild test -project "SystemEQ for Mac.xcodeproj" \
  -scheme "SystemEQ for Mac" -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/SystemEQ-phase1-build \
  CODE_SIGNING_ALLOWED=NO -quiet

xcodebuild build -project "SystemEQ for Mac.xcodeproj" \
  -scheme "SystemEQ for Mac" -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath /private/tmp/SystemEQ-phase1-release \
  CODE_SIGNING_ALLOWED=NO -quiet

swiftformat "SystemEQ for Mac" "SystemEQ for MacTests/AudioRouteRecoveryTests.swift" \
  --config .swiftformat --cache ignore --lint
swiftlint lint --config .swiftlint.yml --no-cache
```

Local full-suite result: **191 passed, 0 failed, 0 skipped** on an arm64 MacBook Air
with macOS 26.3.1 and Xcode's macOS 26.4 SDK. Formatting passed; SwiftLint has no
errors and three pre-existing warnings in DebugLogger, DevicePresetManager, and
BiquadFilterVDSP. XCTest linking reports existing macOS 13/14 deployment warnings.
The final post-review full suite also passed all 191 tests. The standard Release
build failed with a Swift 6.3 `EarlyPerfInliner` compiler crash in the unchanged
`EQEditingSession.deinit`. The same Release command against an isolated export of
PR #1's exact baseline reproduced that crash at the same function. This pre-existing
toolchain limitation is not fixed in Phase 1; a successful Release build with the
supported distribution toolchain remains required before shipping.

The current Code Quality workflow runs for PRs targeting `main`; this stacked PR
will require CI verification when retargeted after PR #1 is merged.

## Required hardware validation — not yet performed

Run both forced native mode (macOS 14.4+) and forced BlackHole mode, plus automatic
mode where fallback is available. Use built-in output and a USB interface/DAC;
include Bluetooth/AirPods and a device with fixed block sizes if available.
Capture the app diagnostics and correlate `routing.health.failed`,
`routing.recovery.scheduled/restarted/fallback/exhausted`,
`routing.defaultOutput.verified`, `routing.activation.rolledBack`,
`native.coreAudio.failed`, and `engine.setup.stepFailed` with audible results.

| Scenario | Required result |
| --- | --- |
| Play, pause for at least 10 minutes, resume | No restart during normal silence; resume is audible. Confirm native callback cadence on real HAL. |
| Silent audio stream / silent test file | No recovery driven by amplitude. |
| Unplug/replug USB repeatedly, including reconnect with new device ID | Clean teardown, audible fallback/recovery, selected device/profile remains correct; no uncontrolled loop. |
| Change physical rate 44.1 → 48 → 96 kHz during playback and pause | Verified reconfiguration and all EQ/room filters rebuilt; selected physical rate preserved. |
| Fixed/different input/output block sizes | Routing continues; no unsafe writes or failure caused merely by block-size mismatch. |
| Sleep/wake repeatedly; unplug during sleep; sleep again during wake delay | Current UID resolved after wake; no obsolete task starts; recovery remains bounded. |
| Externally select another output while recovery is pending | New selection supersedes the old attempt; own restoration events do not create extra restarts. |
| Cause setup/start failure with a test driver or debugger | Partial route removed; original physical output restored or verified fallback chosen; failure visible in diagnostics. |
| Stop callbacks / repeatedly fail render while the engine flag remains true | Watchdog detects failure; at most three scheduled attempts and one optional fallback. |
| Disable or quit while a retry waits | No delayed restart; physical output restored. |
| Preset removal/reset, preamp, bypass, A/B, room filters, device autoswitch, visualizer | Existing behavior retained before and after recovery. |

Hardware checks must also establish whether delayed HAL property application or
callback suspension during idle needs additional device-specific handling. Unit
tests and a successful build cannot certify audible recovery on these devices.
