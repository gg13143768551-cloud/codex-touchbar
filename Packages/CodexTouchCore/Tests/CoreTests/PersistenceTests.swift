import XCTest
@testable import CodexTouchCore

final class PersistenceTests: XCTestCase {
    func testPreferencesRoundTripAndSelectedProfileWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prefs = try AtomicPreferences(fileURL: root.appendingPathComponent("preferences.json"))
        let id = UUID()
        _ = try prefs.write(Preferences(selectedProfileID: nil, oneTouchEnabled: true, orderedProfileIDs: [id]))
        let result = try prefs.setSelectedProfileID(id)
        XCTAssertEqual(result.selectedProfileID, id)
        XCTAssertEqual(try prefs.read().oneTouchEnabled, true)
    }

    func testProfileRegistryNeverNeedsCredentialContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let registry = try ProfileRegistry(rootDirectory: root)
        let profile = try registry.register(alias: "Personal")
        XCTAssertEqual(profile.alias, "Personal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.codexHome.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.codexHome.appendingPathComponent("credentials").path))
    }
}
