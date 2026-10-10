import AppKit
import CryptoKit
import CoreServices
import Darwin
import Foundation

enum UpdateFiles {
    @discardableResult
    static func tool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateFailure("校验或准备更新失败：\(URL(fileURLWithPath: path).lastPathComponent)（\(process.terminationStatus)）。") }
        return String(decoding: data, as: UTF8.self)
    }

    static func sha256(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func quarantine(_ url: URL) throws {
        // Set quarantine on downloads and the bundle, including downloads made by URLSession.
        // Never remove it or launch the downloaded executable directly.
        var values = URLResourceValues()
        values.quarantineProperties = [kLSQuarantineAgentNameKey as String: "Remeet",
            kLSQuarantineAgentBundleIdentifierKey as String: "local.NotchRecall",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String]
        var file = url
        try file.setResourceValues(values)
        guard try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil else {
            throw UpdateFailure("无法为安装包保留系统下载隔离属性，已停止更新。")
        }
    }

    static func extract(_ archive: URL, to directory: URL) throws {
        let names = try tool("/usr/bin/zipinfo", ["-1", archive.path]).split(separator: "\n")
        guard !names.isEmpty, names.allSatisfy({ name in
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            return (parts.first == "Remeet.app" || parts.first == "__MACOSX")
                && !parts.contains("..") && !parts.contains(".") && !name.contains("\\")
                && !name.contains("\r") && !name.hasPrefix("/")
        }) else { throw UpdateFailure("安装包包含无效路径，已停止解压。") }
        let details = try tool("/usr/bin/zipinfo", ["-l", archive.path])
        guard !details.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
            throw UpdateFailure("安装包包含符号链接，已停止解压。")
        }
        try tool("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
    }

    static func info(_ app: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UpdateFailure("安装包缺少有效的 App 信息。")
        }
        return info
    }

    static func validateApp(_ app: URL, version: String? = nil, architecture: String? = nil) throws {
        let fm = FileManager.default
        let root = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard root.isDirectory == true, root.isSymbolicLink != true,
              let files = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw UpdateFailure("安装目标不是有效的 App 目录。")
        }
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw UpdateFailure("App 包含符号链接，不能自动安装。")
            }
        }
        let info = try info(app)
        guard info["CFBundleIdentifier"] as? String == "local.NotchRecall",
              info["CFBundleExecutable"] as? String == "Remeet",
              let actualVersion = info["CFBundleShortVersionString"] as? String,
              ReleaseVersion(actualVersion) != nil,
              version == nil || actualVersion == version else { throw UpdateFailure("安装包的应用标识或版本与所选 Release 不一致。") }
        let minimum = (info["LSMinimumSystemVersion"] as? String ?? "").split(separator: ".").compactMap { Int($0) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        guard !minimum.isEmpty, ![os.majorVersion, os.minorVersion, os.patchVersion].lexicographicallyPrecedes(minimum) else {
            throw UpdateFailure("当前 macOS 版本不满足这个 Release 的要求。")
        }
        let binary = app.appendingPathComponent("Contents/MacOS/Remeet")
        let architectures = try tool("/usr/bin/lipo", ["-archs", binary.path]).split(whereSeparator: \.isWhitespace)
        guard !architectures.isEmpty else { throw UpdateFailure("App 缺少有效的程序架构。") }
        if let architecture, !architectures.contains(Substring(architecture)) { throw UpdateFailure("安装包内的程序不支持 \(architecture)。") }
        try tool("/usr/bin/codesign", ["--verify", "--strict", app.path])
    }

    static func fingerprint(_ app: URL) throws -> String {
        try ["Contents/Info.plist", "Contents/MacOS/Remeet", "Contents/_CodeSignature/CodeResources"]
            .map { try sha256(app.appendingPathComponent($0)) }.joined(separator: ":")
    }

    static func swap(_ left: URL, _ right: URL) throws {
        guard renamex_np(left.path, right.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure("无法原子替换 App（\(errno)），新旧包均已保留。")
        }
    }
}

struct UpdateInstallation: Codable, Sendable {
    let workspace: URL
    let target: URL
    let receipt: URL
    let parentPID: Int32
    let oldFingerprint: String
    let newFingerprint: String
    let version: String
    let architecture: String
    var candidate: URL { workspace.appendingPathComponent("candidate.app", isDirectory: true) }
    var backup: URL { workspace.appendingPathComponent("previous.app", isDirectory: true) }

    @MainActor fileprivate var targetIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath().path == target.path
        }
    }

    static func prepare(app: URL, candidate: URL, receipt: URL, version: String,
                        architecture: String = ReleaseUpdate.architecture, parentPID: Int32 = ProcessInfo.processInfo.processIdentifier) throws -> Self {
        let fm = FileManager.default
        let target = app.standardizedFileURL.resolvingSymlinksInPath()
        guard app.standardizedFileURL.path == target.path, target.pathExtension == "app",
              !target.path.contains("/AppTranslocation/"), !target.path.hasPrefix("/Volumes/"),
              fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateFailure("当前位置无法自动替换 App。请退出回见，将已下载的 Remeet.app 手动放入“应用程序”；笔记和设置会保留。")
        }
        try UpdateFiles.validateApp(target)
        try UpdateFiles.validateApp(candidate, version: version, architecture: architecture)
        let workspace = target.deletingLastPathComponent().appendingPathComponent(".remeet-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false)
        var completed = false
        defer { if !completed { try? fm.removeItem(at: workspace) } }
        let plan = Self(workspace: workspace, target: target, receipt: receipt, parentPID: parentPID,
                        oldFingerprint: try UpdateFiles.fingerprint(target), newFingerprint: try UpdateFiles.fingerprint(candidate),
                        version: version, architecture: architecture)
        try fm.copyItem(at: candidate, to: plan.candidate)
        try fm.copyItem(at: target.appendingPathComponent("Contents/MacOS/Remeet"), to: workspace.appendingPathComponent("installer"))
        try plan.validate()
        try JSONEncoder().encode(plan).write(to: workspace.appendingPathComponent("plan.json"), options: .withoutOverwriting)
        completed = true
        return plan
    }

    func validate() throws {
        let suffix = workspace.lastPathComponent.replacingOccurrences(of: ".remeet-update-", with: "")
        guard workspace.lastPathComponent == ".remeet-update-" + suffix, UUID(uuidString: suffix) != nil,
              workspace.deletingLastPathComponent().path == target.deletingLastPathComponent().path,
              [workspace, target, candidate, receipt.deletingLastPathComponent()].allSatisfy({
                  $0.isFileURL && $0.standardizedFileURL.path == $0.resolvingSymlinksInPath().path
              }),
              target.pathExtension == "app", parentPID > 1,
              !FileManager.default.fileExists(atPath: backup.path) else { throw UpdateFailure("更新安装计划无效或已使用，当前 App 不会被替换。") }
        try UpdateFiles.validateApp(target)
        try UpdateFiles.validateApp(candidate, version: version, architecture: architecture)
        guard try UpdateFiles.fingerprint(target) == oldFingerprint,
              try UpdateFiles.fingerprint(candidate) == newFingerprint else { throw UpdateFailure("准备安装后 App 文件已变化，请重新下载。") }
    }

    func startHelper() throws -> Process {
        let process = Process()
        process.executableURL = workspace.appendingPathComponent("installer")
        process.arguments = ["--install-update", workspace.appendingPathComponent("plan.json").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Do not quit the App until the copied helper has validated its plan and is waiting.
        for _ in 0..<50 {
            if let data = try? Data(contentsOf: receipt),
               let state = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               state["status"] == "waiting", state["workspace"] == workspace.path { return process }
            if !process.isRunning { throw UpdateFailure("安装进程提前退出，请重新下载后重试。") }
            Thread.sleep(forTimeInterval: 0.1)
        }
        process.terminate()
        throw UpdateFailure("安装进程未能就绪，已取消退出；当前 App 保持原样。")
    }

    func record(_ status: String, _ message: String) throws {
        let content: [String: String] = ["status": status, "message": message, "version": version,
            "target": target.path, "backup": backup.path, "workspace": workspace.path]
        try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys]).write(to: receipt, options: .atomic)
    }

    // RENAME_SWAP leaves an App at the original path even if the helper is interrupted.
    @MainActor
    func replaceAndRestart(launch: (URL) async throws -> Void = UpdateInstaller.launch) async throws {
        try validate()
        let fm = FileManager.default
        guard !targetIsRunning else { throw UpdateFailure("安装路径上的 App 仍在运行，更新未执行。") }
        try record("replacing", "正在替换 App。")
        try fm.copyItem(at: target, to: backup)
        var swapped = false
        do {
            try UpdateFiles.swap(candidate, target)
            swapped = true
            try record("restarting", "正在通过 macOS 启动新版本。")
            try await launch(target)
            try record("complete", "已安装 \(version) 并重新启动。旧 App 保留在更新备份目录。")
        } catch {
            let failure = error.localizedDescription
            if error is UpdateInstaller.LiveUpdateProcess || targetIsRunning {
                try? record("manualRecovery", "新 App 仍在运行，保留旧包于 \(backup.path)，请退出后手动处理。\(failure)")
                throw UpdateFailure("新 App 尚未退出，未替换运行中的程序；旧包仍保留在更新目录。")
            }
            do {
                // The production launcher returns an error only after any new process has exited.
                if swapped { try UpdateFiles.swap(candidate, target) }
                try record("rolledBack", "更新未完成，已恢复旧 App：\(failure)")
                try await launch(target)
            } catch {
                try? record("manualRecovery", "更新或重启失败。请检查 \(target.path)；旧包保留于 \(backup.path)。\(error.localizedDescription)")
                throw UpdateFailure("更新失败，自动恢复或启动也未完成。旧包仍保留在更新目录，可查看安装记录并手动恢复。")
            }
            throw UpdateFailure("更新未完成，已恢复并启动旧 App。\(failure)")
        }
    }
}

@MainActor
enum UpdateInstaller {
    static func launch(_ url: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.addsToRecentItems = false
        #if DEBUG
        configuration.environment = ProcessInfo.processInfo.environment.filter {
            ["REMEET_DATA_DIR", "REMEET_DEFAULTS_SUITE"].contains($0.key)
        }
        #endif
        let existingPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        do {
            // This is a startup check, not a guarantee of future stability or content correctness.
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                if app.isTerminated { throw UpdateFailure("新 App 在启动时退出。") }
            }
            guard app.bundleURL?.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path else {
                throw UpdateFailure("系统启动的 App 路径不匹配，已停止更新。")
            }
            guard app.isFinishedLaunching else { throw UpdateFailure("App 未能完成启动。") }
        } catch {
            // Stop only this launch's new process, including App Translocation, before rollback.
            guard !app.isTerminated else { throw error }
            guard !existingPIDs.contains(app.processIdentifier) else { throw LiveUpdateProcess() }
            app.terminate()
            for _ in 0..<100 where !app.isTerminated {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !app.isTerminated {
                // Do not replace a live process or force it to quit; preserve the backup.
                throw LiveUpdateProcess()
            }
            throw error
        }
    }

    struct LiveUpdateProcess: LocalizedError {
        var errorDescription: String? { "新 App 尚未退出，保留新旧包供手动处理。" }
    }

    static func waitForExit(_ pid: Int32, timeout: Duration = .seconds(60)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while kill(pid, 0) == 0 || errno != ESRCH {
            guard ContinuousClock.now < deadline else { throw UpdateFailure("旧 App 尚未退出，更新已取消，安装包未替换。") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    static func run(_ planURL: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task {
            var plan: UpdateInstallation?
            var parentExited = false
            do {
                let value = try JSONDecoder().decode(UpdateInstallation.self, from: Data(contentsOf: planURL))
                guard planURL.resolvingSymlinksInPath().path == value.workspace.appendingPathComponent("plan.json").resolvingSymlinksInPath().path else {
                    throw UpdateFailure("安装计划路径不一致。")
                }
                try value.validate()
                plan = value
                try value.record("waiting", "等待旧 App 正常退出。")
                try await waitForExit(value.parentPID)
                parentExited = true
                try await value.replaceAndRestart()
            } catch {
                FileHandle.standardError.write(Data("Remeet update failed: \(error.localizedDescription)\n".utf8))
                if let plan {
                    let status = (try? Data(contentsOf: plan.receipt))
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["status"]
                    if !["complete", "rolledBack", "manualRecovery"].contains(status ?? "") {
                        try? plan.record("failed", error.localizedDescription)
                        if parentExited, (try? UpdateFiles.fingerprint(plan.target)) == plan.oldFingerprint,
                           !plan.targetIsRunning {
                            try? await launch(plan.target)
                        }
                    }
                }
                #if DEBUG
                let showAlert = ProcessInfo.processInfo.environment["REMEET_UPDATE_TEST_NO_ALERT"] != "1"
                #else
                let showAlert = true
                #endif
                if showAlert {
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "回见更新未完成"
                    alert.informativeText = error.localizedDescription + "\n若 macOS 拦截了下载包，请到“系统设置 → 隐私与安全性”查看具体原因并单独允许。"
                    alert.addButton(withTitle: "好")
                    if plan != nil { alert.addButton(withTitle: "查看安装记录") }
                    if alert.runModal() == .alertSecondButtonReturn, let plan {
                        NSWorkspace.shared.activateFileViewerSelecting([plan.receipt])
                    }
                }
            }
            exit(0)
        }
        app.run()
    }
}
