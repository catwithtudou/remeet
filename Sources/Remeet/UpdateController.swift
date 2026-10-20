import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var failure: String?
    @Published private(set) var busy = false
    @Published private(set) var available: ReleaseUpdate?
    @Published private(set) var downloadedApp: URL?
    @Published private(set) var includePrereleases: Bool
    let currentVersion: String
    let development: Bool
    /// Off in production: a quarantined App swapped into place is stopped by Gatekeeper and
    /// App Translocation, even with a Team ID. Downloads are verified, then replaced in Finder.
    /// Enable only with the signed-build checks described in docs/UPDATING.md.
    let installsAutomatically: Bool
    private let defaults: UserDefaults
    private let client: ReleaseClient
    private let appURL: URL
    private var operation: Task<Void, Never>?
    private var lastCheck: Date?
    private var downloadDirectory: URL?
    private(set) var pendingInstallation: UpdateInstallation?
    private(set) var pendingManualInstall: URL?
    var onQuitForInstallation: (() -> Void)?
    var onManualInstallReady: ((URL) -> Void)?

    init(bundle: Bundle = .main, defaults: UserDefaults? = nil, client: ReleaseClient = ReleaseClient(),
         installsAutomatically: Bool = false) {
        var preferences = defaults ?? .standard
        #if DEBUG
        if defaults == nil, let suite = ProcessInfo.processInfo.environment["REMEET_DEFAULTS_SUITE"],
           let isolated = UserDefaults(suiteName: suite) { preferences = isolated }
        #endif
        self.defaults = preferences
        self.client = client
        appURL = bundle.bundleURL
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let kind = bundle.object(forInfoDictionaryKey: "RemeetBuildKind") as? String
        development = kind == "development" || kind == nil
        includePrereleases = preferences.bool(forKey: "updateIncludePrereleases")
        self.installsAutomatically = installsAutomatically
    }

    /// The folder to replace in, so an App kept outside /Applications is not duplicated.
    var installFolderName: String { Self.installFolderName(for: appURL) }

    static func installFolderName(for app: URL) -> String {
        let folder = app.deletingLastPathComponent().path
        if folder == "/Applications" || folder.contains("/AppTranslocation/") { return "应用程序" }
        return (folder as NSString).abbreviatingWithTildeInPath
    }

    var actionTitle: String {
        if busy { return available == nil ? "正在检查…" : "正在下载…" }
        if downloadedApp != nil { return installsAutomatically ? "重启更新" : "安装更新" }
        if available == nil { return "检查更新" }
        return installsAutomatically ? "更新并重启" : "下载更新"
    }

    func performPrimaryAction() {
        guard !busy, pendingInstallation == nil else { return }
        if downloadedApp != nil { installDownload() }
        else if available != nil { download() }
        else { check() }
    }

    private func installDownload() {
        guard let app = downloadedApp else { return }
        if installsAutomatically { install(); return }
        do {
            // A cache cleaner may remove or change the download while the user chose "later".
            try UpdateFiles.validateApp(app, version: available.map { String($0.release.tagName.drop(while: { $0 == "v" })) },
                                        architecture: available?.architecture)
            onManualInstallReady?(app)
        } catch {
            downloadedApp = nil
            status = "下载的新版本已不可用，请重新下载。"
            failure = error.localizedDescription
        }
    }

    /// Finder is shown only once drafts allow quitting, so the running App is never replaced.
    func queueManualInstall(_ app: URL) {
        pendingManualInstall = app
    }

    func setIncludePrereleases(_ include: Bool) {
        guard !busy else { return }
        includePrereleases = include
        defaults.set(include, forKey: "updateIncludePrereleases")
        available = nil
        downloadedApp = nil
        failure = nil
        status = "更新通道已更改，请重新检查更新。"
    }

    /// Menu-bar sessions can run for weeks: check again once a day, keeping any update already found.
    /// Only successful checks count, and a clock moved either way counts as a new day.
    func checkIfStale(now: Date = Date()) {
        guard available == nil, abs(now.timeIntervalSince(lastCheck ?? .distantPast)) >= 24 * 60 * 60 else { return }
        check(now: now)
    }

    func check(now: Date = Date()) {
        guard !busy else { return }
        available = nil
        downloadedApp = nil
        failure = nil
        busy = true
        status = "正在检查更新…"
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                guard let version = ReleaseVersion(currentVersion) else {
                    throw UpdateFailure("当前构建没有有效版本号，请在 GitHub Releases 下载发行版本。")
                }
                let releases = try await client.releases()
                try Task.checkCancellation()
                available = try ReleaseUpdate.select(releases, current: version, includePrereleases: includePrereleases,
                                                     development: development, architecture: ReleaseUpdate.architecture)
                lastCheck = now // Failures leave this unset, so the next hourly tick retries.
                if available != nil {
                    status = ""
                } else if !includePrereleases && !releases.contains(where: { !$0.draft && !$0.isPrerelease && $0.version != nil }) {
                    status = "暂无正式版，可在“测试版本”中选择接收预发布版本。"
                } else {
                    status = "已是最新版本。"
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    status = "已取消检查。"
                } else {
                    status = "检查更新失败，请稍后重试。"
                    failure = error.localizedDescription
                }
            }
        }
    }

    func download() {
        guard !busy, let update = available else { return }
        busy = true
        downloadedApp = nil
        failure = nil
        status = "正在下载更新…"
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.NotchRecall/Updates/\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        operation = Task {
            do {
                let candidate = try await client.download(update, directory: directory)
                try Task.checkCancellation()
                downloadDirectory = directory
                downloadedApp = candidate
                status = installsAutomatically ? "更新已就绪。" : "已下载。点击“安装更新”查看替换步骤。"
            } catch {
                try? FileManager.default.removeItem(at: directory)
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    status = "已取消更新。"
                } else {
                    status = "下载更新失败，请重试。"
                    failure = error.localizedDescription
                }
            }
            busy = false
            operation = nil
            if downloadedApp != nil { installDownload() }
        }
    }

    func cancel() { operation?.cancel() }

    func showDownload() {
        if let directory = downloadDirectory { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
    }

    private func install() {
        guard !busy, pendingInstallation == nil,
              let update = available, let candidate = downloadedApp, let directory = downloadDirectory else { return }
        failure = nil
        do {
            let plan = try UpdateInstallation.prepare(app: appURL, candidate: candidate,
                receipt: directory.appendingPathComponent("installation.json"),
                version: String(update.release.tagName.drop(while: { $0 == "v" })), architecture: update.architecture)
            queueInstallation(plan)
            onQuitForInstallation?()
        } catch {
            status = "无法自动安装，当前 App 未退出。"
            failure = error.localizedDescription
        }
    }

    func queueInstallation(_ plan: UpdateInstallation) {
        pendingInstallation = plan
        status = "正在重启更新…"
    }

    // Used for every AppKit termination request, including Command-Q and update installation.
    func prepareToTerminate(protectDrafts: () -> Bool,
                            startHelper: (UpdateInstallation) throws -> Void = { _ = try $0.startHelper() },
                            reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) -> Bool {
        guard protectDrafts() else {
            if let pendingInstallation {
                try? FileManager.default.removeItem(at: pendingInstallation.workspace)
                self.pendingInstallation = nil
                status = "已取消安装，未保存的草稿仍保留在当前 App。"
            }
            if pendingManualInstall != nil {
                pendingManualInstall = nil
                status = "已取消退出，未保存的草稿仍保留。新版本仍在下载目录，可再次点击“安装更新”。"
            }
            return false
        }
        if let app = pendingManualInstall {
            pendingManualInstall = nil
            reveal(app)
            return true
        }
        guard let plan = pendingInstallation else { return true }
        do {
            defaults.synchronize()
            try startHelper(plan)
            pendingInstallation = nil
            return true
        } catch {
            try? FileManager.default.removeItem(at: plan.workspace)
            pendingInstallation = nil
            status = "更新失败，当前 App 未退出。"
            failure = error.localizedDescription
            return false
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        Section("关于") {
            HStack {
                Text("版本 \(updater.currentVersion)")
                Spacer()
                Button(updater.actionTitle, action: updater.performPrimaryAction).disabled(updater.busy)
            }
            if let update = updater.available {
                HStack {
                    Text("\(update.release.tagName)\(update.release.isPrerelease ? "（预发布）" : "")")
                    Spacer()
                    Link("更新内容", destination: update.release.htmlURL)
                }.font(.caption).foregroundStyle(.secondary)
            }
            if !updater.status.isEmpty {
                Text(updater.status).font(.caption).foregroundStyle(.secondary)
            }
            if updater.busy {
                HStack {
                    ProgressView().controlSize(.small)
                    Button("取消", action: updater.cancel)
                }
            }
            if let failure = updater.failure {
                DisclosureGroup("查看详情") {
                    Text(failure).font(.caption).textSelection(.enabled)
                    if updater.downloadedApp != nil {
                        Button("打开下载目录", action: updater.showDownload)
                    }
                    Link("手动安装说明", destination: URL(string: "https://github.com/catwithtudou/remeet#安装")!)
                }
            }
            DisclosureGroup("测试版本") {
                Toggle("接收预发布版本", isOn: Binding(get: { updater.includePrereleases },
                    set: { value in updater.setIncludePrereleases(value) }))
                    .disabled(updater.busy)
                Text("预发布版本用于测试，默认关闭。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
