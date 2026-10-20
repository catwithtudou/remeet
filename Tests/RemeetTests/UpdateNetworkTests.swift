import Foundation
import Testing
@testable import Remeet

private final class UpdateProtocol: URLProtocol, @unchecked Sendable {
    // The suite is serialized; handlers are installed before starting each session.
    nonisolated(unsafe) static var respond: (URLRequest) -> (Int, Data) = { _ in (404, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, data) = Self.respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized)
struct UpdateNetworkTests {
    func client() -> ReleaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateProtocol.self]
        return ReleaseClient(session: URLSession(configuration: configuration))
    }

    @MainActor
    func waitForOperation(_ updater: UpdateController) async throws {
        let deadline = Date().addingTimeInterval(10)
        while updater.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!updater.busy)
    }

    @Test(arguments: zip(["download", "cancel", "failure", "download"], [true, true, true, false])) @MainActor
    func oneClickUpdateDownloadsThenQuitsOrGuidesReplacement(outcome: String, automatic: Bool) async throws {
        let fixture = UpdateTests()
        let root = try fixture.temporary()
        let suite = testDefaultsSuite("local.Remeet.update-action")
        let defaults = try #require(UserDefaults(suiteName: suite))
        let target = try fixture.app(root, name: "installed.app", version: "0.2.17")
        let incoming = try fixture.app(root, name: "incoming/Remeet.app", version: "0.2.18")
        let archive = root.appendingPathComponent("update.zip")
        try UpdateFiles.tool("/usr/bin/ditto", ["-c", "-k", "--keepParent", incoming.path, archive.path])
        let bytes = try Data(contentsOf: archive)
        let name = "Remeet-0.2.18-\(ReleaseUpdate.architecture).zip"
        let checksum = Data((try UpdateFiles.sha256(archive) + "  " + name + "\n").utf8)
        let base = "https://github.com/catwithtudou/remeet/releases"
        let releases = try JSONSerialization.data(withJSONObject: [["tag_name": "v0.2.18", "html_url": "\(base)/tag/v0.2.18",
            "draft": false, "prerelease": false, "assets": [
                ["name": name, "size": bytes.count, "state": "uploaded", "browser_download_url": "\(base)/download/v0.2.18/\(name)"],
                ["name": name + ".sha256", "size": checksum.count, "state": "uploaded", "browser_download_url": "\(base)/download/v0.2.18/\(name).sha256"]
            ]]])
        UpdateProtocol.respond = { request in
            if request.url!.host == "api.github.com" { return (200, releases) }
            if outcome == "failure" { return (500, Data()) }
            return (200, request.url!.path.hasSuffix(".sha256") ? checksum : bytes)
        }
        let updater = UpdateController(bundle: try #require(Bundle(url: target)), defaults: defaults, client: client(),
                                       installsAutomatically: automatic)
        defer {
            updater.onQuitForInstallation = nil
            updater.onManualInstallReady = nil
            if let app = updater.downloadedApp {
                try? FileManager.default.removeItem(at: app.deletingLastPathComponent().deletingLastPathComponent())
            }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let original = try UpdateFiles.fingerprint(target)
        var quits = 0
        updater.onQuitForInstallation = {
            quits += 1
            #expect(updater.pendingInstallation != nil)
            #expect(!updater.prepareToTerminate(protectDrafts: { false }, startHelper: { _ in
                Issue.record("Cancelled drafts must never start the installer")
            }))
        }
        var guides: [URL] = []
        updater.onManualInstallReady = { guides.append($0) }
        #expect(updater.actionTitle == "检查更新")
        updater.check() // The startup check may discover an update, but cannot download or quit.
        try await waitForOperation(updater)
        #expect(updater.available?.release.tagName == "v0.2.18")
        #expect(updater.downloadedApp == nil && quits == 0 && updater.failure == nil)
        #expect(updater.actionTitle == (automatic ? "更新并重启" : "下载更新"))
        updater.performPrimaryAction()
        if outcome == "cancel" { updater.cancel() }
        try await waitForOperation(updater)
        #expect(try UpdateFiles.fingerprint(target) == original)
        #expect(updater.pendingInstallation == nil)
        if outcome == "download" && !automatic {
            // Ad-hoc builds stop after verification: no installer workspace, helper or quit.
            let cached = try #require(updater.downloadedApp)
            #expect(quits == 0 && guides == [cached] && updater.failure == nil)
            #expect(try cached.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
            #expect(updater.actionTitle == "安装更新")
            updater.performPrimaryAction() // "Later" keeps the download for another look at the steps.
            #expect(quits == 0 && guides == [cached, cached] && updater.pendingInstallation == nil)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".remeet-update-") })
            // As if a cache cleaner removed the download; this also leaves nothing for teardown.
            try FileManager.default.removeItem(at: cached.deletingLastPathComponent().deletingLastPathComponent())
            updater.performPrimaryAction()
            #expect(guides.count == 2 && updater.downloadedApp == nil && updater.failure != nil)
            #expect(updater.actionTitle == "下载更新")
        } else if outcome == "download" {
            #expect(quits == 1 && guides.isEmpty && updater.failure == nil)
            let cached = try #require(updater.downloadedApp)
            #expect(updater.actionTitle == "重启更新")
            updater.performPrimaryAction() // Retry after cancelling the draft dialog reuses the download.
            #expect(quits == 2 && updater.downloadedApp == cached)
        } else {
            #expect(quits == 0 && updater.downloadedApp == nil)
            #expect((updater.failure != nil) == (outcome == "failure"))
            #expect(!updater.status.contains("最新"))
        }
    }

    @Test func releaseListingIncludesLaterPagesRatherThanUsingStableOnlyLatestEndpoint() async throws {
        let release: [String: Any] = ["tag_name": "v0.2.17", "html_url": "https://github.com/catwithtudou/remeet/releases/tag/v0.2.17",
                                      "draft": false, "prerelease": true, "assets": []]
        let first = try JSONSerialization.data(withJSONObject: Array(repeating: release, count: 100))
        let second = try JSONSerialization.data(withJSONObject: [release])
        UpdateProtocol.respond = { request in
            #expect(request.url?.path == "/repos/catwithtudou/remeet/releases")
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "Remeet-Update")
            return (200, request.url!.query!.hasSuffix("page=1") ? first : second)
        }
        let entries = try await client().releases()
        #expect(entries.count == 101 && entries.allSatisfy(\.prerelease))
    }

    @Test func HTTPAndRateLimitFailuresCannotReportUpToDate() async {
        for code in [403, 429, 404, 500] {
            UpdateProtocol.respond = { _ in (code, Data()) }
            do {
                _ = try await client().releases()
                Issue.record("Expected HTTP failure")
            } catch { #expect(error is UpdateFailure) }
        }
    }

    @Test @MainActor func dailyCheckRetriesFailuresAndKeepsAFoundUpdate() async throws {
        let fixture = UpdateTests()
        let root = try fixture.temporary()
        let suite = testDefaultsSuite("local.Remeet.daily-check")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let name = "Remeet-0.2.18-\(ReleaseUpdate.architecture).zip"
        let base = "https://github.com/catwithtudou/remeet/releases"
        let releases = try JSONSerialization.data(withJSONObject: [["tag_name": "v0.2.18", "html_url": "\(base)/tag/v0.2.18",
            "draft": false, "prerelease": false, "assets": [name, name + ".sha256"].map {
                ["name": $0, "size": 64, "state": "uploaded", "browser_download_url": "\(base)/download/v0.2.18/\($0)"]
            }]])
        let target = try fixture.app(root, name: "installed.app", version: "0.2.17")
        let updater = UpdateController(bundle: try #require(Bundle(url: target)), defaults: defaults, client: client())
        let start = Date(), hour: TimeInterval = 60 * 60
        UpdateProtocol.respond = { _ in (403, Data()) }
        updater.check(now: start) // The launch check is rate limited.
        try await waitForOperation(updater)
        #expect(updater.failure != nil && updater.available == nil)
        UpdateProtocol.respond = { _ in (200, Data("[]".utf8)) }
        updater.checkIfStale(now: start.addingTimeInterval(hour))
        #expect(updater.busy) // A failed check is retried on the next hourly tick.
        try await waitForOperation(updater)
        #expect(updater.failure == nil && updater.available == nil)
        updater.checkIfStale(now: start.addingTimeInterval(2 * hour))
        #expect(!updater.busy) // A successful check holds for a day.
        UpdateProtocol.respond = { _ in (200, releases) }
        updater.checkIfStale(now: start.addingTimeInterval(-2 * 24 * hour))
        #expect(updater.busy) // A clock moved back still gets its daily check.
        try await waitForOperation(updater)
        #expect(updater.available?.release.tagName == "v0.2.18" && updater.failure == nil)
        UpdateProtocol.respond = { _ in (403, Data()) }
        updater.checkIfStale(now: start.addingTimeInterval(3 * 24 * hour))
        // A found update is kept rather than re-checked, so a background failure cannot hide it.
        #expect(!updater.busy && updater.available?.release.tagName == "v0.2.18")
    }

    @Test func failedOrTruncatedDownloadRemovesOnlyItsTemporaryDirectory() async throws {
        let name = "Remeet-0.2.18-arm64.zip"
        let checksum = Data((String(repeating: "a", count: 64) + "  " + name + "\n").utf8)
        let base = "https://github.com/catwithtudou/remeet/releases"
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": "v0.2.18", "html_url": "\(base)/tag/v0.2.18",
            "draft": false, "prerelease": false, "assets": [
                ["name": name, "size": 3, "state": "uploaded", "browser_download_url": "\(base)/download/v0.2.18/\(name)"],
                ["name": name + ".sha256", "size": checksum.count, "state": "uploaded", "browser_download_url": "\(base)/download/v0.2.18/\(name).sha256"]
            ]])
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let selection = try ReleaseUpdate.select([release], current: ReleaseVersion("0.2.17")!, includePrereleases: false, development: false, architecture: "arm64")
        let update = try #require(selection)
        for code in [500, 200] {
            UpdateProtocol.respond = { request in
                request.url!.path.hasSuffix(".sha256") ? (200, checksum) : (code, Data("bad".utf8))
            }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-download-test-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let original = root.appendingPathComponent("keep.txt")
            try Data("keep".utf8).write(to: original)
            let download = root.appendingPathComponent("download", isDirectory: true)
            do {
                _ = try await client().download(update, directory: download)
                Issue.record("Expected failed download")
            } catch {
                #expect(error is UpdateFailure)
                #expect(error.localizedDescription.contains(code == 200 ? "SHA-256" : "HTTP 500"))
            }
            #expect(!FileManager.default.fileExists(atPath: download.path))
            #expect(try Data(contentsOf: original) == Data("keep".utf8))
        }
    }
}
