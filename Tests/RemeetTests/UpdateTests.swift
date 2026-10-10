import AppKit
import Foundation
import CoreServices
import Testing
@testable import Remeet
#if SWIFT_PACKAGE
import RemeetCore
#endif

@Suite(.serialized) @MainActor
struct UpdateTests {
    func release(_ tag: String = "v0.2.18", prerelease: Bool = false, draft: Bool = false,
                 architecture: String = "arm64", checksum: Bool = true) throws -> GitHubRelease {
        let name = "Remeet-\(tag.dropFirst())-\(architecture).zip"
        let base = "https://github.com/catwithtudou/remeet/releases"
        let names = checksum ? [name, name + ".sha256"] : [name]
        return try JSONDecoder().decode(GitHubRelease.self, from: JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "html_url": "\(base)/tag/\(tag)", "prerelease": prerelease, "draft": draft,
            "assets": names.map { ["name": $0, "state": "uploaded", "size": 100,
                                  "browser_download_url": "\(base)/download/\(tag)/\($0)"] }
        ]))
    }

    @Test func versionOrderingIsSemanticAndRejectsInvalidInput() throws {
        let ordered = ["0.2.9", "0.2.10-alpha", "0.2.10-alpha.2", "0.2.10-alpha.10", "0.2.10-beta", "0.2.10", "1.0.0"]
        let versions = try ordered.map { try #require(ReleaseVersion($0)) }
        #expect(versions == versions.sorted())
        #expect(ReleaseVersion("v0.2.17+build.18") == ReleaseVersion("0.2.17"))
        for invalid in ["", "main", "0.2", "01.2.3", "1.2.3-", "1.2.3-01", "1.2.3+", "1.2.3/other", "999999999999999999999.0.0"] {
            #expect(ReleaseVersion(invalid) == nil)
        }
    }

    @Test func stableDefaultAndExplicitPrereleaseSelectionDoNotDowngrade() throws {
        let current = try #require(ReleaseVersion("0.2.17"))
        let entries = try [release("v0.2.19", prerelease: true), release(), release("v0.2.20", draft: true)]
        let stable = try ReleaseUpdate.select(entries, current: current, includePrereleases: false, development: false, architecture: "arm64")
        #expect(stable?.release.tagName == "v0.2.18")
        let test = try ReleaseUpdate.select(entries, current: current, includePrereleases: true, development: false, architecture: "arm64")
        #expect(test?.release.tagName == "v0.2.19" && test?.release.prerelease == true)
        #expect(try ReleaseUpdate.select([release("v0.2.17", prerelease: true)], current: current,
                                       includePrereleases: false, development: true, architecture: "arm64") == nil)
        #expect(try ReleaseUpdate.select([release("v0.2.17", prerelease: true)], current: current,
                                       includePrereleases: true, development: false, architecture: "arm64") == nil)
        #expect(try ReleaseUpdate.select([release("v0.2.16")], current: current,
                                       includePrereleases: true, development: true, architecture: "arm64") == nil)
        #expect(try ReleaseUpdate.select([release("v0.2.17", prerelease: true)], current: current,
                                       includePrereleases: true, development: true, architecture: "arm64") != nil)
        let mislabeled = try release("v0.2.19-rc.1")
        #expect(mislabeled.isPrerelease)
        #expect(try ReleaseUpdate.select([mislabeled], current: current,
                                       includePrereleases: false, development: false, architecture: "arm64") == nil)
    }

    @Test func incompleteOrWrongArchitectureReleaseDoesNotFallBackToSourceOrAnOlderPackage() throws {
        let current = try #require(ReleaseVersion("0.2.16"))
        #expect(throws: UpdateFailure.self) {
            try ReleaseUpdate.select([release("v0.2.18", architecture: "x86_64"), release("v0.2.17")],
                                     current: current, includePrereleases: false, development: false, architecture: "arm64")
        }
        #expect(throws: UpdateFailure.self) {
            try ReleaseUpdate.select([release(checksum: false)], current: current,
                                     includePrereleases: false, development: false, architecture: "arm64")
        }
        #expect(try ReleaseUpdate.select([release(architecture: "arm64-x86_64")], current: current,
                                       includePrereleases: false, development: false, architecture: "x86_64")?.archive.name.hasSuffix("arm64-x86_64.zip") == true)
    }

    @Test func checksumsRequireExactFilenameAndDigest() throws {
        let digest = String(repeating: "a", count: 64)
        #expect(try ReleaseClient.checksum(digest + "  Remeet.zip\n", filename: "Remeet.zip") == digest)
        #expect(try ReleaseClient.checksum(digest.uppercased() + " *Remeet.zip\n", filename: "Remeet.zip") == digest)
        for invalid in [digest + "  wrong.zip", digest + "  Remeet.zip\nextra", "bad  Remeet.zip", digest + "  Re*meet.zip"] {
            #expect(throws: UpdateFailure.self) { try ReleaseClient.checksum(invalid, filename: "Remeet.zip") }
        }
    }

    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remeet-update-test-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func app(_ root: URL, name: String, version: String) throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let binaryDirectory = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: package.appendingPathComponent(".build/debug/Remeet"), to: binaryDirectory.appendingPathComponent("Remeet"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "local.NotchRecall", "CFBundleExecutable": "Remeet",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "19", "LSMinimumSystemVersion": "14.0"],
            format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try UpdateFiles.tool("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        return app
    }

    @Test func versionAndSignatureRejectionsReachTheirOwnValidationBoundary() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let wrongVersion = try app(root, name: "wrong-version.app", version: "0.2.18")
        do {
            try UpdateFiles.validateApp(wrongVersion, version: "0.2.17")
            Issue.record("Expected valid but mismatched version to be rejected")
        } catch { #expect(error.localizedDescription.contains("版本")) }

        let signed = try app(root, name: "signed.app", version: "0.2.17")
        let resource = signed.appendingPathComponent("Contents/Resources/sealed.txt")
        try FileManager.default.createDirectory(at: resource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("original".utf8).write(to: resource)
        try UpdateFiles.tool("/usr/bin/codesign", ["--force", "--sign", "-", signed.path])
        try UpdateFiles.validateApp(signed, version: "0.2.17", architecture: ReleaseUpdate.architecture)
        try Data("changed sealed resource".utf8).write(to: resource)
        do {
            try UpdateFiles.validateApp(signed, version: "0.2.17", architecture: ReleaseUpdate.architecture)
            Issue.record("Expected damaged signature to be rejected")
        } catch { #expect(error.localizedDescription.contains("codesign")) }
    }

    @Test(arguments: ["traversal", "absolute", "backslash", "symlink"])
    func unsafeArchiveEntriesAreRejectedBeforeExtraction(kind: String) throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let retained = root.appendingPathComponent("keep.txt")
        let original = Data("keep original bytes".utf8)
        try original.write(to: retained)
        let archive = root.appendingPathComponent("unsafe.zip")
        let entry = kind == "absolute" ? retained.path : (kind == "traversal" ? "Remeet.app/../../keep.txt"
            : (kind == "symlink" ? "Remeet.app/Contents/link" : "Remeet.app/Contents\\keep.txt"))
        let script = """
        import sys, zipfile
        with zipfile.ZipFile(sys.argv[1], 'w') as archive:
            entry = zipfile.ZipInfo(sys.argv[2])
            entry.create_system = 3
            entry.external_attr = (0o120777 if sys.argv[3] == 'symlink' else 0o100644) << 16
            archive.writestr(entry, sys.argv[4] if sys.argv[3] == 'symlink' else 'must not extract')
        """
        try UpdateFiles.tool("/usr/bin/python3", ["-c", script, archive.path, entry, kind, retained.path])
        let destination = root.appendingPathComponent("unpacked", isDirectory: true)
        do {
            try UpdateFiles.extract(archive, to: destination)
            Issue.record("Expected unsafe archive to be rejected before extraction")
        } catch {
            #expect(error is UpdateFailure)
            #expect(error.localizedDescription.contains(kind == "symlink" ? "符号链接" : "无效路径"))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Data(contentsOf: retained) == original)
    }

    func installation(_ root: URL) throws -> UpdateInstallation {
        try UpdateInstallation.prepare(app: app(root, name: "Remeet.app", version: "0.2.16"),
                                       candidate: app(root, name: "incoming.app", version: "0.2.17"),
                                       receipt: root.appendingPathComponent("installation.json"), version: "0.2.17")
    }

    @Test func atomicReplacementKeepsBackupAndDoesNotTouchAdjacentNotes() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try installation(root)
        let notes = root.appendingPathComponent("quotes.json")
        try Data("笔记原始字节".utf8).write(to: notes)
        var launched: [URL] = []
        try await plan.replaceAndRestart { launched.append($0) }
        #expect(launched == [plan.target])
        #expect(try UpdateFiles.fingerprint(plan.target) == plan.newFingerprint)
        #expect(try UpdateFiles.fingerprint(plan.backup) == plan.oldFingerprint)
        #expect(try UpdateFiles.fingerprint(plan.candidate) == plan.oldFingerprint)
        #expect(try String(contentsOf: notes, encoding: .utf8) == "笔记原始字节")
        #expect(try String(contentsOf: plan.receipt, encoding: .utf8).contains("complete"))
        #expect(throws: UpdateFailure.self) { try plan.validate() } // Cannot reuse a completed plan.
    }

    @Test func launchFailureRestoresExactOriginalAndRestartFailureRetainsRecoveryEvidence() async throws {
        for failRollbackLaunch in [false, true] {
            let root = try temporary()
            defer { try? FileManager.default.removeItem(at: root) }
            let plan = try installation(root)
            var attempts = 0
            do {
                try await plan.replaceAndRestart { _ in
                    attempts += 1
                    if attempts == 1 || failRollbackLaunch { throw UpdateFailure("模拟系统拒绝启动") }
                }
                Issue.record("Expected installation failure")
            } catch {}
            #expect(attempts == 2)
            #expect(try UpdateFiles.fingerprint(plan.target) == plan.oldFingerprint)
            #expect(try UpdateFiles.fingerprint(plan.backup) == plan.oldFingerprint)
            #expect(try String(contentsOf: plan.receipt, encoding: .utf8).contains(failRollbackLaunch ? "manualRecovery" : "rolledBack"))
        }
    }

    @Test func liveNewProcessNeverTriggersAutomaticReplacement() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try installation(root)
        do {
            try await plan.replaceAndRestart { _ in throw UpdateInstaller.LiveUpdateProcess() }
            Issue.record("Expected manual recovery")
        } catch {}
        #expect(try UpdateFiles.fingerprint(plan.target) == plan.newFingerprint)
        #expect(try UpdateFiles.fingerprint(plan.backup) == plan.oldFingerprint)
        #expect(try String(contentsOf: plan.receipt, encoding: .utf8).contains("manualRecovery"))
    }

    @Test func changedBundleVersionSignatureOrPathRejectsInstallationBeforeReplacement() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try installation(root)
        let info = plan.candidate.appendingPathComponent("Contents/Info.plist")
        let original = try Data(contentsOf: info)
        try Data("changed".utf8).write(to: info)
        #expect(throws: (any Error).self) { try plan.validate() }
        #expect(try UpdateFiles.fingerprint(plan.target) == plan.oldFingerprint)
        try original.write(to: info)
        let link = plan.candidate.appendingPathComponent("outside")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: UpdateFailure.self) { try plan.validate() }
        #expect(!FileManager.default.fileExists(atPath: plan.backup.path))
    }

    @Test func cancellationAndSaveConflictKeepDraftsAndNeverStartHelper() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local.Remeet.update-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecallModel(dataDirectory: root.appendingPathComponent("data"), userDefaults: defaults)
        try FileManager.default.createDirectory(at: model.store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[{\"text\":\"已保存\"}]".utf8).write(to: model.store.fileURL)
        let editor = ContentEditorSession(model: model)
        editor.load()
        editor.drafts[0].text = "尚未保存"
        let updater = UpdateController(defaults: defaults)
        var starts = 0
        updater.queueInstallation(try installation(root))
        #expect(!updater.prepareToTerminate(protectDrafts: { editor.prepareToClose { .cancel } }, startHelper: { _ in starts += 1 }))
        #expect(starts == 0 && updater.pendingInstallation == nil && editor.dirty)
        #expect(editor.drafts[0].text == "尚未保存")
        let another = try temporary()
        defer { try? FileManager.default.removeItem(at: another) }
        updater.queueInstallation(try installation(another))
        try Data("[{\"text\":\"外部改写\"}]".utf8).write(to: model.store.fileURL)
        #expect(!updater.prepareToTerminate(protectDrafts: { editor.prepareToClose { .save } }, startHelper: { _ in starts += 1 }))
        #expect(starts == 0 && editor.dirty && editor.drafts[0].text == "尚未保存")
        #expect(updater.pendingInstallation == nil)
    }

    @Test(arguments: [false, true])
    func draftSaveMustFinishBeforeHelperStartsAndBackupFailurePreventsQuit(failBackup: Bool) throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local.Remeet.update-save.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecallModel(dataDirectory: root.appendingPathComponent("data"), userDefaults: defaults)
        defer { model.shutdown() }
        let original = Data("[{\"text\":\"已保存\"}]".utf8)
        try model.store.initializeIfMissing(sample: original)
        let editor = ContentEditorSession(model: model)
        editor.load()
        editor.drafts[0].text = "保存后安装"
        editor.drafts[0].source = "来源"
        editor.drafts[0].tagInput = "尚未提交的标签"
        let expected = editor.drafts.map(\.quote)
        if failBackup {
            try Data("阻止创建备份目录".utf8).write(to: model.store.fileURL.deletingLastPathComponent().appendingPathComponent("editor-backups"))
        }
        let updater = UpdateController(defaults: defaults)
        let plan = try installation(root)
        updater.queueInstallation(plan)
        var starts = 0
        let canQuit = updater.prepareToTerminate(protectDrafts: { editor.prepareToClose { .save } }, startHelper: { value in
            starts += 1
            let saved = try JSONDecoder().decode([Quote].self, from: Data(contentsOf: model.store.fileURL))
            let backup = try Data(contentsOf: #require(model.store.backups().first).url)
            let fingerprint = try UpdateFiles.fingerprint(value.target)
            #expect(!editor.dirty)
            #expect(saved == expected && backup == original)
            #expect(fingerprint == value.oldFingerprint)
        })
        #expect(canQuit == !failBackup && starts == (failBackup ? 0 : 1))
        #expect(updater.pendingInstallation == nil)
        if failBackup {
            #expect(editor.dirty && editor.drafts.map(\.quote) == expected && editor.failure != nil)
            #expect(try Data(contentsOf: model.store.fileURL) == original)
            #expect(!FileManager.default.fileExists(atPath: plan.workspace.path))
        }
    }

    @Test func helperFailurePreventsQuitAndChannelRequiresExplicitOptIn() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "local.Remeet.update-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updater = UpdateController(defaults: defaults)
        #expect(!updater.includePrereleases)
        updater.setIncludePrereleases(true)
        #expect(UpdateController(defaults: defaults).includePrereleases)
        updater.queueInstallation(try installation(root))
        #expect(!updater.prepareToTerminate(protectDrafts: { true }, startHelper: { _ in throw UpdateFailure("helper unavailable") }))
        #expect(updater.status.contains("当前 App 未退出"))
        #expect(updater.prepareToTerminate(protectDrafts: { true })) // Normal quit does not run a stale plan.
    }

    @Test func waitingForCurrentProcessTimesOutWithoutTerminatingIt() async {
        do {
            try await UpdateInstaller.waitForExit(ProcessInfo.processInfo.processIdentifier, timeout: .milliseconds(1))
            Issue.record("Expected timeout")
        } catch { #expect(error is UpdateFailure) }
    }

    @Test func copiedHelperMustBeReadyBeforeOriginalCanQuit() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let plan = try installation(root)
        let helper = try plan.startHelper()
        defer { helper.terminate(); helper.waitUntilExit() }
        #expect(helper.isRunning)
        #expect(try String(contentsOf: plan.receipt, encoding: .utf8).contains("waiting"))
        #expect(try UpdateFiles.fingerprint(plan.target) == plan.oldFingerprint)
        #expect(!FileManager.default.fileExists(atPath: plan.backup.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["REMEET_TEST_LIVE_RELEASE"] == "1"))
    func livePublishedReleaseDownloadsAndVerifiesWithoutInstallingOrLaunching() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = ReleaseClient()
        let entries: [GitHubRelease]
        if let metadata = ProcessInfo.processInfo.environment["REMEET_TEST_RELEASE_METADATA"] {
            entries = try JSONDecoder().decode([GitHubRelease].self, from: Data(contentsOf: URL(fileURLWithPath: metadata)))
        } else {
            entries = try await client.releases()
        }
        let release = try #require(entries.first(where: { $0.tagName == "v0.2.17" }))
        #expect(release.prerelease)
        let selection = try ReleaseUpdate.select([release], current: ReleaseVersion("0.2.16")!, includePrereleases: true,
                                                 development: false, architecture: ReleaseUpdate.architecture)
        let update = try #require(selection)
        let app = try await client.download(update, directory: root.appendingPathComponent("download", isDirectory: true))
        #expect(try UpdateFiles.info(app)["CFBundleShortVersionString"] as? String == "0.2.17")
        let quarantine = try UpdateFiles.tool("/usr/bin/xattr", ["-p", "com.apple.quarantine", app.path])
        let properties = try app.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(!quarantine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(properties?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
        print("LIVE_QUARANTINE_VERIFIED value=\(quarantine.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("LIVE_RELEASE_VERIFIED tag=\(release.tagName) asset=\(update.archive.name) digest=\(update.archive.digest ?? "sidecar-only")")
    }
}
