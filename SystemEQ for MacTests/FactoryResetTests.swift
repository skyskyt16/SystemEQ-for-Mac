// Async XCTest entry points avoid the isolated-deinit runtime crash.
// https://github.com/swiftlang/swift/issues/87316
// swiftformat:disable redundantAsync

import Foundation
@testable import SystemEQ_for_Mac
import XCTest

@MainActor
final class FactoryResetTests: XCTestCase {
    func testFactoryResetRemovesOwnedDataAndPreservesSourceFilesAndOtherDomains() async throws {
        let suiteName = "FactoryResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let otherName = suiteName + ".other"
        let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherName))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            otherDefaults.removePersistentDomain(forName: otherName)
            try? FileManager.default.removeItem(at: root)
        }
        let support = root.appendingPathComponent("Application Support")
        let documents = root.appendingPathComponent("Documents")
        let files = [
            support.appendingPathComponent("SystemEQ/AutoEQIndex.json"),
            support.appendingPathComponent("SystemEQ for Mac/PersonalizedProfiles.json"),
            documents.appendingPathComponent("CalibrationProfiles.json"),
            documents.appendingPathComponent("My imported preset.txt"),
            support.appendingPathComponent("OtherApp/settings.json")
        ]
        for file in files {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("test".utf8).write(to: file)
        }
        for key in [
            "lastAppliedPresetJSON",
            "lastCustomPresetText",
            "autoEQFavorites",
            "devicePresets.v1",
            "AppLanguage",
            "eqStartupMode",
            "visualizerQuality",
            "hasCompletedSetup"
        ] {
            defaults.set("saved value", forKey: key)
        }
        PresetPersistence.savePlaybackState(
            mode: .thirtyOneBand,
            gains: Array(repeating: 5, count: 31),
            preamp: -6,
            in: defaults
        )
        otherDefaults.set("keep", forKey: "AppLanguage")

        try FactoryReset.clearStoredData(
            defaults: defaults,
            domainName: suiteName,
            applicationSupportURL: support,
            documentsURL: documents
        )

        XCTAssertTrue(defaults.persistentDomain(forName: suiteName)?.isEmpty ?? true)
        XCTAssertNil(PresetPersistence.loadPlaybackState(in: defaults))
        XCTAssertEqual(otherDefaults.string(forKey: "AppLanguage"), "keep")
        for file in files.prefix(3) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        for file in files.suffix(2) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
        // A second reset and a fresh install with no files must both succeed.
        try FactoryReset.clearStoredData(
            defaults: defaults,
            domainName: suiteName,
            applicationSupportURL: support,
            documentsURL: documents
        )
    }
}
