import Foundation
@testable import SystemEQ_for_Mac
import XCTest

final class EQResetTests: XCTestCase {
    func testResetClearsBothBandModesPreampAndPendingSliderWrites() throws {
        let suiteName = "EQResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = AudioEngine(defaults: defaults, enableRouting: { _ in true }, disableRouting: { _ in })

        for mode in EQBandMode.allCases {
            engine.bandMode = mode
            engine.applyEQValues(Array(repeating: 5, count: mode.bandCount))
            engine.setPreampGain(-8)
            engine.updateBandGain(bandId: 0, gain: 12)
            engine.resetAllBands()

            // Allow previously scheduled mode changes, DSP sync and persistence
            // to run; none may restore nonzero gains after the reset.
            RunLoop.main.run(until: Date().addingTimeInterval(0.35))
            XCTAssertEqual(engine.bandMode, mode)
            XCTAssertEqual(engine.bands.map(\.gain), Array(repeating: 0, count: mode.bandCount))
            XCTAssertEqual(engine.preampGain, 0)
            let restored = try XCTUnwrap(PresetPersistence.loadPlaybackState(in: defaults))
            XCTAssertEqual(restored.gains, Array(repeating: 0, count: mode.bandCount))
            XCTAssertEqual(restored.preamp, 0)

            // Verify actual DSP output, including the one-sample boundary.
            let filter = try XCTUnwrap(CoreAudioEngine.shared.vdspFilter)
            var left: [Float] = [0.25]
            var right: [Float] = [-0.25]
            left.withUnsafeMutableBufferPointer { l in
                right.withUnsafeMutableBufferPointer { r in
                    filter.processStereo(l.baseAddress!, r.baseAddress!, frameCount: 0)
                    filter.processStereo(l.baseAddress!, r.baseAddress!, frameCount: 1)
                }
            }
            XCTAssertEqual(left[0], 0.25, accuracy: 0.0001)
            XCTAssertEqual(right[0], -0.25, accuracy: 0.0001)
        }
    }

    func testResetImmediatelyAfterModeSwitchResetsAll31Bands() throws {
        let suiteName = "EQResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = AudioEngine(defaults: defaults, enableRouting: { _ in true }, disableRouting: { _ in })
        engine.applyEQValues(Array(repeating: -4, count: 10))
        engine.setPreampGain(3)
        engine.bandMode = .thirtyOneBand
        engine.resetAllBands()
        XCTAssertEqual(engine.bands.map(\.gain), Array(repeating: 0, count: 31))
        XCTAssertEqual(engine.preampGain, 0)
    }
}
