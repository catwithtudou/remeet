import Foundation

/// An isolated preferences suite stored under the temporary directory.
/// cfprefsd writes an empty plist back after `removePersistentDomain`, even after
/// `synchronize()`, so a named suite would leave a file in ~/Library/Preferences.
/// A suite named by an absolute path keeps that leftover out of the user's preferences.
func testDefaultsSuite(_ name: String) -> String {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-test-defaults", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("\(name).\(UUID().uuidString)").path
}
