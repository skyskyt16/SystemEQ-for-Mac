import Foundation

// MARK: - Factory Reset

/// Applied at the end of normal shutdown, after routing restoration and pending
/// profile writes. Relaunching starts every settings owner from its defaults.
enum FactoryReset {
    @MainActor static var isRequested = false

    static func clearStoredData(
        defaults: UserDefaults,
        domainName: String,
        applicationSupportURL: URL,
        documentsURL: URL,
        fileManager: FileManager = .default
    ) throws {
        // Only app-owned data: never remove imported source files or the bundled
        // read-only AutoEQ database. Missing files are already in factory state.
        let paths = [
            applicationSupportURL.appendingPathComponent("SystemEQ"),
            applicationSupportURL.appendingPathComponent("SystemEQ for Mac"),
            documentsURL.appendingPathComponent("CalibrationProfiles.json")
        ]
        for url in paths where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        defaults.removePersistentDomain(forName: domainName)
    }
}
