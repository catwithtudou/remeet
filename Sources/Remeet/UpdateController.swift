import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class UpdateController: ObservableObject {
    @Published private(set) var status = "点击检查更新，从 GitHub Releases 获取已发布安装包。"
    @Published private(set) var busy = false
    @Published private(set) var available: ReleaseUpdate?
    @Published private(set) var downloadedApp: URL?
    @Published private(set) var includePrereleases: Bool
    let currentVersion: String
    let development: Bool
    let buildDescription: String
    private let defaults: UserDefaults
    private let client: ReleaseClient
    private let appURL: URL
    private var operation: Task<Void, Never>?
    private var downloadDirectory: URL?
    private(set) var pendingInstallation: UpdateInstallation?
    var onQuitForInstallation: (() -> Void)?

    init(bundle: Bundle = .main, defaults: UserDefaults? = nil, client: ReleaseClient = ReleaseClient()) {
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
        buildDescription = kind == "release" ? "发行构建" : (kind == "development" ? "开发构建" : "来源未标记")
        includePrereleases = preferences.bool(forKey: "updateIncludePrereleases")
    }

    func setIncludePrereleases(_ include: Bool) {
        guard !busy else { return }
        includePrereleases = include
        defaults.set(include, forKey: "updateIncludePrereleases")
        available = nil
        downloadedApp = nil
        status = "更新通道已更改，请重新检查更新。"
    }

    func check() {
        guard !busy else { return }
        available = nil
        downloadedApp = nil
        busy = true
        status = "正在检查 GitHub Releases…"
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
                if let update = available {
                    status = "可下载 \(update.release.tagName)（\(update.release.isPrerelease ? "预发布" : "正式版") · \(update.architecture)）。"
                } else if !includePrereleases && !releases.contains(where: { !$0.draft && !$0.isPrerelease && $0.version != nil }) {
                    status = "目前尚无正式版。若需要公开测试版，请显式开启“包含预发布版本”。"
                } else {
                    status = "当前通道没有比 \(currentVersion) 更新的已发布版本。"
                }
            } catch {
                status = error is CancellationError || (error as? URLError)?.code == .cancelled ? "已取消检查。" : error.localizedDescription
            }
        }
    }

    func download() {
        guard !busy, let update = available else { return }
        busy = true
        downloadedApp = nil
        status = "正在下载并校验 \(update.release.tagName)…"
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.NotchRecall/Updates/\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        operation = Task {
            defer { busy = false; operation = nil }
            do {
                let candidate = try await client.download(update, directory: directory)
                try Task.checkCancellation()
                downloadDirectory = directory
                downloadedApp = candidate
                status = "已下载并通过大小、SHA-256、版本、架构和签名完整性校验。可重启安装，或在 Finder 中查看安装包。"
            } catch {
                try? FileManager.default.removeItem(at: directory)
                status = error is CancellationError || (error as? URLError)?.code == .cancelled
                    ? "下载已取消，当前 App 保持原样。" : error.localizedDescription
            }
        }
    }

    func cancel() { operation?.cancel() }

    func showDownload() {
        if let directory = downloadDirectory { NSWorkspace.shared.activateFileViewerSelecting([directory]) }
    }

    func install() {
        guard !busy, let update = available, let candidate = downloadedApp, let directory = downloadDirectory else { return }
        do {
            let plan = try UpdateInstallation.prepare(app: appURL, candidate: candidate,
                receipt: directory.appendingPathComponent("installation.json"),
                version: String(update.release.tagName.drop(while: { $0 == "v" })), architecture: update.architecture)
            queueInstallation(plan)
            onQuitForInstallation?()
        } catch { status = error.localizedDescription }
    }

    func queueInstallation(_ plan: UpdateInstallation) {
        pendingInstallation = plan
        status = "准备退出并安装 \(plan.version)…"
    }

    // Used for every AppKit termination request, including Command-Q and update installation.
    func prepareToTerminate(protectDrafts: () -> Bool,
                            startHelper: (UpdateInstallation) throws -> Void = { _ = try $0.startHelper() }) -> Bool {
        guard protectDrafts() else {
            if let pendingInstallation {
                try? FileManager.default.removeItem(at: pendingInstallation.workspace)
                self.pendingInstallation = nil
                status = "已取消安装，未保存的草稿仍保留在当前 App。"
            }
            return false
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
            status = "无法启动安装进程，当前 App 未退出：\(error.localizedDescription)"
            return false
        }
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        Section("更新") {
            Text("当前版本：\(updater.currentVersion) · \(updater.buildDescription)")
            Toggle("包含预发布版本", isOn: Binding(get: { updater.includePrereleases }, set: updater.setIncludePrereleases))
                .disabled(updater.busy)
            Text(updater.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("检查更新", action: updater.check).disabled(updater.busy)
                if updater.busy {
                    ProgressView().controlSize(.small)
                    Button("取消", action: updater.cancel)
                } else if updater.downloadedApp != nil {
                    Button("重启并安装", action: updater.install)
                    Button("查看安装包", action: updater.showDownload)
                } else if let update = updater.available {
                    Button(update.release.isPrerelease ? "下载预发布版本" : "下载更新", action: updater.download)
                }
            }
            Link("查看 GitHub Releases", destination: URL(string: "https://github.com/catwithtudou/remeet/releases")!)
            Text("仅下载已发布附件；预发布用于测试。安装时先处理未保存草稿，笔记和设置沿用原目录。当前安装包未获 Developer ID 签名或公证；若 macOS 拦截，请到系统设置的隐私与安全性查看并单独允许。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
