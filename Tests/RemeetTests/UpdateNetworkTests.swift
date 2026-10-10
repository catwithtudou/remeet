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
