import CryptoKit
import Foundation
import Darwin

struct ReleaseVersion: Comparable, Sendable {
    let numbers: [Int]
    let prerelease: [String]

    init?(_ text: String) {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let build = value.split(separator: "+", omittingEmptySubsequences: false)
        guard build.count <= 2, build.allSatisfy({ !$0.isEmpty }) else { return nil }
        let parts = build[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let components = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber)
                  && ($0.count == 1 || $0.first != "0") && Int($0) != nil }) else { return nil }
        numbers = components.map { Int($0)! }
        prerelease = parts.count == 2 ? parts[1].components(separatedBy: ".") : []
        let identifiers = prerelease + (build.count == 2 ? build[1].components(separatedBy: ".") : [])
        guard identifiers.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45
        } }), prerelease.allSatisfy({ !$0.allSatisfy(\.isNumber) || $0.count == 1 || $0.first != "0" }) else { return nil }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            let leftNumeric = left.allSatisfy(\.isNumber), rightNumeric = right.allSatisfy(\.isNumber)
            if leftNumeric != rightNumeric { return leftNumeric }
            if leftNumeric && left.count != right.count { return left.count < right.count }
            return left < right
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct GitHubRelease: Decodable, Sendable {
    struct Asset: Decodable, Sendable {
        let name: String
        let size: Int64
        let state: String
        let browserDownloadURL: URL
        let digest: String?
        enum CodingKeys: String, CodingKey {
            case name, size, state, digest
            case browserDownloadURL = "browser_download_url"
        }
    }
    let tagName: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case draft, prerelease, assets
        case tagName = "tag_name", htmlURL = "html_url"
    }
    var version: ReleaseVersion? { ReleaseVersion(tagName) }
    var isPrerelease: Bool { prerelease || version?.prerelease.isEmpty == false }
}

struct ReleaseUpdate: Sendable {
    let release: GitHubRelease
    let archive: GitHubRelease.Asset
    let checksum: GitHubRelease.Asset
    let architecture: String

    static var architecture: String {
        // Prefer the hardware architecture, including an Intel process under Rosetta.
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0, arm64 == 1 { return "arm64" }
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func select(_ releases: [GitHubRelease], current: ReleaseVersion,
                       includePrereleases: Bool, development: Bool, architecture: String) throws -> Self? {
        let eligible = releases.filter {
            !$0.draft && (includePrereleases || !$0.isPrerelease)
                && $0.version != nil
        }
        guard let release = eligible.max(by: { $0.version! < $1.version! }),
              let version = release.version,
              version > current || (development && version == current) else { return nil }
        guard repositoryURL(release.htmlURL, path: "/catwithtudou/remeet/releases/tag/\(release.tagName)") else {
            throw UpdateFailure("发布页面不属于 Remeet 仓库。")
        }
        let number = String(release.tagName.drop(while: { $0 == "v" }))
        let names = ["Remeet-\(number)-\(architecture).zip", "Remeet-\(number)-arm64-x86_64.zip", "Remeet-\(number)-x86_64-arm64.zip"]
        guard let archive = names.compactMap({ name in release.assets.first(where: { $0.name == name }) }).first,
              let checksum = release.assets.first(where: { $0.name == archive.name + ".sha256" }),
              archive.size > 0, archive.size <= 512 * 1024 * 1024,
              checksum.size > 0, checksum.size <= 4096,
              [archive, checksum].allSatisfy({ $0.state == "uploaded" && repositoryURL($0.browserDownloadURL,
                  path: "/catwithtudou/remeet/releases/download/\(release.tagName)/\($0.name)") }) else {
            throw UpdateFailure("\(release.tagName) 没有适用于 \(architecture) 的完整安装包及 SHA-256 附件。可查看发布页面，当前 App 不会被替换。")
        }
        return Self(release: release, archive: archive, checksum: checksum, architecture: architecture)
    }

    private static func repositoryURL(_ url: URL, path: String) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.port == nil && url.user == nil
            && url.password == nil && url.query == nil && url.fragment == nil && url.path == path
    }
}

struct UpdateFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct ReleaseClient: Sendable {
    let session: URLSession
    init(session: URLSession = URLSession(configuration: .ephemeral)) { self.session = session }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("Remeet-Update", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    static func checkResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 || code == 429 { throw UpdateFailure("GitHub 暂时拒绝访问或已达到访问频率限制，请稍后重试。") }
            throw UpdateFailure("下载或检查更新失败（HTTP \(code)），请稍后重试。")
        }
    }

    func releases() async throws -> [GitHubRelease] {
        var result: [GitHubRelease] = []
        for page in 1...20 {
            let url = URL(string: "https://api.github.com/repos/catwithtudou/remeet/releases?per_page=100&page=\(page)")!
            let (data, response) = try await session.data(for: request(url))
            try Self.checkResponse(response)
            let entries = try JSONDecoder().decode([GitHubRelease].self, from: data)
            result += entries
            if entries.count < 100 { return result }
        }
        throw UpdateFailure("发布列表过长，尚未完成检查。请到 GitHub 查看，不能据此判断已是最新版本。")
    }

    func download(_ update: ReleaseUpdate, directory: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: directory) } }
        let (checksumData, response) = try await session.data(for: request(update.checksum.browserDownloadURL))
        try Self.checkResponse(response)
        guard checksumData.count == update.checksum.size,
              let line = String(data: checksumData, encoding: .utf8) else { throw UpdateFailure("SHA-256 附件大小或内容不正确。") }
        let expected = try Self.checksum(line, filename: update.archive.name)
        let (temporary, archiveResponse) = try await session.download(for: request(update.archive.browserDownloadURL))
        defer { try? fm.removeItem(at: temporary) }
        try Self.checkResponse(archiveResponse)
        let actual = try UpdateFiles.sha256(temporary)
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard Int64(size ?? -1) == update.archive.size, actual == expected,
              update.archive.digest == nil || update.archive.digest == "sha256:" + actual else {
            throw UpdateFailure("安装包大小或 SHA-256 校验失败，请重新下载；当前 App 不会被替换。")
        }
        let archive = directory.appendingPathComponent(update.archive.name)
        try fm.moveItem(at: temporary, to: archive)
        try UpdateFiles.quarantine(archive)
        let extracted = directory.appendingPathComponent("unpacked", isDirectory: true)
        try UpdateFiles.extract(archive, to: extracted)
        let app = extracted.appendingPathComponent("Remeet.app", isDirectory: true)
        try UpdateFiles.quarantine(app)
        try UpdateFiles.validateApp(app, version: String(update.release.tagName.drop(while: { $0 == "v" })),
                                    architecture: update.architecture)
        completed = true
        return app
    }

    static func checksum(_ text: String, filename: String) throws -> String {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
        let name = fields.count == 2 ? fields[1].trimmingCharacters(in: .whitespaces) : ""
        guard fields.count == 2, fields[0].count == 64,
              fields[0].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }),
              (name == filename || name == "*" + filename) else {
            throw UpdateFailure("SHA-256 附件格式或安装包名称不匹配。")
        }
        return fields[0].lowercased()
    }
}
