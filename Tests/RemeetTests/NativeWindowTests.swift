import AppKit
import Testing
@testable import Remeet
@testable import RemeetCore

@Suite(.serialized) @MainActor
struct NativeWindowTests {
    @Test func saveWarningsProtectAllDraftsAndCloseUsesTheSameConfirmation() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.save-warning-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "hoverPresent")
        defaults.set(false, forKey: "showIndicator")
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let initial = try model.saveContent([Quote(text: "A"), Quote(text: "待删除")], expectedFileData: nil)
        let editor = ContentEditorSession(model: model)
        editor.load()
        editor.selectedID = editor.drafts.last?.id
        editor.deleteSelected()
        editor.drafts[0].source = "保留的来源"
        editor.drafts.append(QuoteDraft(Quote(text: " A\n", source: "被忽略的来源")))
        editor.drafts[1].tagInput = "待提交的标签"
        editor.drafts.append(QuoteDraft(Quote(text: " \n", source: "没有正文但有来源")))
        editor.searchText = "无匹配结果"
        editor.selectSearchResult()
        let before = editor.drafts.map(\.quote)
        let ids = editor.drafts.map(\.id)
        var warnings = 0
        let canceled = editor.save { quotes, discarded in
            warnings += 1
            #expect(quotes == before)
            #expect(discarded == [1, 2])
            #expect(quotes[1].tags == ["待提交的标签"])
            return false
        }
        #expect(!canceled)
        #expect(warnings == 1)
        #expect(editor.drafts.map(\.id) == ids && editor.drafts.map(\.quote) == before)
        #expect(editor.dirty && editor.canUndoDelete)
        #expect(editor.searchText == "无匹配结果" && editor.selectedID == nil)
        #expect(try Data(contentsOf: model.store.fileURL) == initial.fileData)
        #expect(model.store.quotes == initial.quotes)
        #expect(try model.store.backups().isEmpty)
        #expect(!editor.prepareToClose(confirmDiscarded: { _, _ in false }, decide: { .save }))
        #expect(editor.dirty)
        // Confirming an older preview must not save changes made while its modal loop was running.
        #expect(!editor.save { _, _ in editor.drafts[0].source = "确认期间变化"; return true })
        #expect(try Data(contentsOf: model.store.fileURL) == initial.fileData)
        #expect(editor.failure?.contains("草稿已变化") == true)
        let closed = editor.prepareToClose(confirmDiscarded: { _, discarded in
            #expect(discarded == [1, 2])
            return true
        }, decide: { .save })
        #expect(closed)
        let saved = try model.store.editorSnapshot()
        #expect(saved.quotes == [Quote(text: "A", source: "确认期间变化")])
        #expect(!editor.dirty && !editor.canUndoDelete)
        #expect(try Data(contentsOf: #require(model.store.backups().first).url) == initial.fileData)
        editor.drafts[0].text = "普通编辑"
        #expect(editor.save { _, _ in Issue.record("不丢弃条目的保存不应要求确认"); return false })
        #expect(model.store.quotes.first?.text == "普通编辑")
    }

    @Test func conflictingDraftExportPreservesAllEntriesAndDoesNotResolveTheConflict() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.draft-export-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "hoverPresent")
        defaults.set(false, forKey: "showIndicator")
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = [Quote(text: "原文"), Quote(text: "待删除")]
        _ = try model.saveContent(original, expectedFileData: nil)
        model.start()
        let due = model.nextRecallDate
        let editor = ContentEditorSession(model: model)
        editor.load()
        editor.selectedID = editor.drafts[1].id
        editor.deleteSelected()
        editor.drafts[0].text = "  中文草稿\n  保留缩进 🌱\n"
        editor.drafts[0].source = "来源一"
        editor.drafts[0].tagInput = "阅读，工作"
        editor.drafts.append(QuoteDraft(Quote(text: editor.drafts[0].text, source: "来源二", tags: ["另一标签"])))
        editor.drafts.append(QuoteDraft(Quote(text: " \n", source: "仅来源", tags: ["待补正文"])))
        editor.searchText = "无匹配结果"
        editor.selectSearchResult()
        #expect(editor.filteredDrafts.isEmpty)
        let expected = editor.drafts.map(\.quote)
        let ids = editor.drafts.map(\.id)
        let external = Data(#"[{"text":"外部新增","tags":["新标签"]}]"#.utf8)
        try external.write(to: model.store.fileURL)
        #expect(!editor.save(confirmDiscarded: { _, _ in true }))
        let conflict = try #require(editor.failure)

        editor.exportDrafts()
        let url = try #require(editor.draftExportResult).get()
        let exported = try Data(contentsOf: url)
        // Use the raw decoder: QuoteStore.decode intentionally filters blank and duplicate bodies.
        #expect(try JSONDecoder().decode([Quote].self, from: exported) == expected)
        #expect(url.deletingLastPathComponent().lastPathComponent == "draft-exports")
        #expect(editor.drafts.map(\.id) == ids)
        #expect(editor.drafts[0].tagInput == "阅读，工作")
        #expect(editor.selectedID == nil && editor.searchText == "无匹配结果")
        #expect(editor.dirty && editor.canUndoDelete)
        #expect(editor.failure == conflict)
        #expect(try Data(contentsOf: model.store.fileURL) == external)
        #expect(model.store.quotes == original)
        #expect(model.nextRecallDate == due && !model.panel.isPresented)
        #expect(try model.store.backups().isEmpty)
        #expect(!editor.prepareToClose { .cancel })
        #expect(!editor.save(confirmDiscarded: { _, _ in true })) // Export must not replace the file baseline.

        editor.exportDrafts()
        let secondURL = try #require(editor.draftExportResult).get()
        #expect(secondURL != url)
        #expect(try Data(contentsOf: url) == exported)
        editor.load()
        #expect(!editor.dirty)
        #expect(editor.drafts.map(\.text) == ["外部新增"])
        #expect(try Data(contentsOf: secondURL) == exported)
        #expect(try #require(editor.draftExportResult).get() == secondURL)
    }

    @Test func draftExportFailureKeepsDraftUndoAndExistingFile() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.draft-export-failure.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = try model.saveContent([Quote(text: "保留")], expectedFileData: nil)
        let editor = ContentEditorSession(model: model)
        editor.load()
        editor.deleteSelected() // Exporting a deliberate empty draft must remain possible.
        let blocked = directory.appendingPathComponent("draft-exports")
        try Data("not a directory".utf8).write(to: blocked)
        editor.exportDrafts()
        let failedExport = try #require(editor.draftExportResult)
        #expect(throws: (any Error).self) { try failedExport.get() }
        #expect(editor.dirty && editor.canUndoDelete)
        #expect(editor.drafts.isEmpty)
        #expect(try Data(contentsOf: model.store.fileURL) == original.fileData)
        #expect(model.store.quotes == original.quotes)
        #expect(try Data(contentsOf: blocked) == Data("not a directory".utf8))
        try FileManager.default.removeItem(at: blocked)
        editor.exportDrafts()
        let url = try #require(editor.draftExportResult).get()
        #expect(try JSONDecoder().decode([Quote].self, from: Data(contentsOf: url)).isEmpty)
        #expect(editor.dirty && editor.canUndoDelete)
        editor.undoDelete()
        #expect(editor.drafts.map(\.quote) == original.quotes)
    }

    @Test func deletedDraftsUndoInOrderAndBackupRecoveryRemainsAnExplicitSave() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.recovery-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "hoverPresent")
        defaults.set(false, forKey: "showIndicator")
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = [Quote(text: "A", source: "来源", tags: ["阅读"]), Quote(text: "B"), Quote(text: "C")]
        _ = try model.saveContent(original, expectedFileData: nil)
        model.start()
        let due = model.nextRecallDate
        let editor = ContentEditorSession(model: model)
        editor.load()
        editor.drafts[1].tagInput = "未提交标签"
        let deletedID = editor.drafts[1].id
        editor.selectedID = deletedID
        editor.deleteSelected() // B, then C.
        editor.deleteSelected()
        editor.drafts[0].source = "保留其他编辑"
        editor.undoDelete()
        editor.searchText = "不匹配"
        editor.tagFilter = .tag("阅读")
        editor.undoDelete()
        #expect(editor.drafts.map(\.text) == ["A", "B", "C"])
        #expect(editor.drafts[0].source == "保留其他编辑")
        #expect(editor.selectedID == deletedID)
        #expect(editor.selectedDraft?.tagInput == "未提交标签")
        #expect(editor.searchText.isEmpty && editor.tagFilter == .all)
        #expect(!editor.canUndoDelete)
        editor.deleteSelected()
        let blockedBackups = directory.appendingPathComponent("editor-backups")
        try Data("blocked".utf8).write(to: blockedBackups)
        #expect(!editor.save())
        #expect(editor.dirty && editor.canUndoDelete)
        #expect(model.store.quotes == original)
        try FileManager.default.removeItem(at: blockedBackups)
        #expect(editor.save())
        #expect(!editor.canUndoDelete)
        let changed = try model.store.editorSnapshot()
        let backup = try #require(model.store.backups().first)
        #expect(editor.loadBackup(backup))
        #expect(editor.drafts.map(\.quote) == original)
        #expect(editor.dirty)
        #expect(try model.store.editorSnapshot().fileData == changed.fileData)
        #expect(model.store.quotes == changed.quotes)
        #expect(model.nextRecallDate == due)
        #expect(!model.panel.isPresented)
        #expect(!editor.prepareToClose { .cancel })
        #expect(editor.save())
        #expect(model.store.quotes == original)
        // Recovery itself saves a backup of the content it replaces.
        let recoveryBackup = try #require(model.store.backups().first)
        #expect(try Data(contentsOf: recoveryBackup.url) == changed.fileData)
        #expect(!editor.dirty)
        #expect(model.nextRecallDate == due)
        // Read through a new store so a successful in-memory update cannot hide a failed disk restore.
        let reopened = QuoteStore(fileURL: model.store.fileURL)
        #expect(try reopened.editorSnapshot().quotes == original)

        editor.drafts[0].text = "保留草稿"
        editor.selectedID = editor.drafts.last?.id
        editor.deleteSelected()
        let draftBeforeFailure = editor.drafts.map(\.quote)
        let selectionBeforeFailure = editor.selectedID
        try Data("[".utf8).write(to: backup.url)
        #expect(!editor.loadBackup(backup))
        #expect(editor.drafts.map(\.quote) == draftBeforeFailure)
        #expect(editor.selectedID == selectionBeforeFailure)
        #expect(editor.canUndoDelete)
        #expect(editor.failure != nil)
        // A backup can disappear while the picker is open; failure must also preserve the draft.
        try FileManager.default.removeItem(at: backup.url)
        #expect(!editor.loadBackup(backup))
        #expect(editor.drafts.map(\.quote) == draftBeforeFailure)
        #expect(editor.selectedID == selectionBeforeFailure)
        #expect(editor.canUndoDelete)
        #expect(editor.loadBackup(recoveryBackup))
        #expect(!editor.canUndoDelete)
        let external = Data(#"[{"text":"外部导入"}]"#.utf8)
        try external.write(to: model.store.fileURL)
        #expect(!editor.save())
        #expect(editor.dirty)
        #expect(try Data(contentsOf: model.store.fileURL) == external)
        #expect(editor.drafts.map(\.quote) == changed.quotes)
        #expect(model.store.quotes == original)
    }

    @Test func tagsOrganizeDraftsWithoutFilteringTheRecallPool() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.tag-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "hoverPresent")
        defaults.set(false, forKey: "showIndicator")
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try model.saveContent([Quote(text: "A", source: "Book", tags: ["工作"]), Quote(text: "B")], expectedFileData: nil)
        model.start()
        let due = model.nextRecallDate
        let editor = ContentEditorSession(model: model)
        editor.load()
        editor.tagFilter = .untagged
        editor.selectSearchResult()
        #expect(editor.filteredDrafts.map(\.text) == ["B"])
        editor.tagFilter = .tag("工作")
        editor.searchText = "book"
        editor.selectSearchResult()
        #expect(editor.filteredDrafts.map(\.text) == ["A"])
        editor.searchText = "不存在"
        editor.selectSearchResult()
        #expect(editor.selectedID == nil)
        editor.searchText = "工作"
        editor.selectSearchResult()
        #expect(editor.selectedDraft?.text == "A")
        #expect(!editor.dirty)
        // Only A is visible, but alternating manual recall still reaches B.
        model.remindNext()
        let first = model.currentQuote?.text
        model.remindNext()
        #expect(Set([first, model.currentQuote?.text]) == Set(["A", "B"]))
        #expect(model.nextRecallDate == due)
        editor.drafts[0].tagInput = " 阅读 ，工作, 阅读,🌱 "
        #expect(editor.dirty)
        editor.searchText = ""
        editor.tagFilter = .untagged
        editor.selectSearchResult()
        #expect(editor.selectedDraft?.text == "B")
        #expect(editor.drafts[0].tagInput.contains("阅读"))
        // Save pending tag input even without pressing Add.
        #expect(editor.save())
        #expect(model.store.quotes[0].tags == ["工作", "阅读", "🌱"])
        #expect(editor.selectedDraft?.text == "B")
        editor.addTag("阅读")
        #expect(editor.selectedDraft?.tags == ["阅读"])
        #expect(editor.filteredDrafts.isEmpty)
        editor.removeTag("阅读")
        #expect(editor.filteredDrafts.map(\.text) == ["B"])
        #expect(!editor.dirty)
        editor.tagFilter = .tag("工作")
        editor.searchText = ""
        editor.selectSearchResult()
        editor.removeTag("工作")
        #expect(editor.filteredDrafts.isEmpty)
        #expect(editor.selectedDraft?.text == "A") // Editing does not eject the draft.
        #expect(editor.save())
        #expect(editor.selectedID == nil)
        editor.addDraft()
        #expect(editor.tagFilter == .all)
        #expect(editor.selectedDraft?.tags == [])
        editor.deleteSelected()
        #expect(!editor.dirty)
        editor.load()
        #expect(editor.drafts[0].tags == ["阅读", "🌱"])
    }

    @Test func nativeEditingMenuHandlesSelectAll() throws {
        _ = NSApplication.shared
        let menu = RemeetApp.makeMainMenu()
        let edit = try #require(menu.items.first(where: { $0.title == "编辑" })?.submenu)
        let expected = ["z": "undo:", "x": "cut:", "c": "copy:", "v": "paste:", "a": "selectAll:"]
        for (key, action) in expected {
            let item = try #require(edit.items.first(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command
            }))
            #expect(item.action == Selector(action))
            #expect(item.target == nil)
        }
        #expect(edit.items.contains { $0.action == Selector(("redo:")) && $0.keyEquivalentModifierMask == [.command, .shift] })
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 80))
        editor.string = "笔记内容 🌱"
        let selectAll = try #require(edit.items.first(where: { $0.keyEquivalent == "a" }))
        // Offscreen routing uses an explicit responder; full app focus remains a UI check.
        selectAll.target = editor
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
            characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(edit.performKeyEquivalent(with: event))
        #expect(editor.selectedRange() == NSRange(location: 0, length: (editor.string as NSString).length))
    }

    @Test func contentSearchKeepsDraftsAndPreviewDoesNotChangeRecallSelection() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.content-browser-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "hoverPresent")
        defaults.set(false, forKey: "showIndicator")
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        _ = try model.saveContent([Quote(text: "阅读笔记", source: "Book"), Quote(text: "工作想法", source: "Idea")], expectedFileData: nil)
        model.start()
        let editor = ContentEditorSession(model: model)
        editor.load()
        let first = try #require(editor.selectedID)
        editor.drafts[0].text = "阅读笔记草稿"
        editor.searchText = "idea"
        editor.selectSearchResult()
        #expect(editor.filteredDrafts.count == 1)
        #expect(editor.selectedDraft?.text == "工作想法")
        #expect(editor.drafts.first { $0.id == first }?.text == "阅读笔记草稿")
        editor.previewSelected()
        #expect(!model.panel.isPresented) // Any unsaved draft requires saving first.
        #expect(editor.save())
        #expect(editor.selectedDraft?.text == "工作想法")
        let current = model.currentQuote
        let due = model.nextRecallDate
        editor.previewSelected()
        #expect(model.panel.displayedQuote?.text == "工作想法")
        #expect(model.currentQuote == current)
        #expect(model.nextRecallDate == due)
        model.panel.collapse(immediately: true)
        model.remindCurrent()
        #expect(model.panel.displayedQuote == current)
        model.panel.collapse(immediately: true)
        editor.searchText = "不存在"
        editor.selectSearchResult()
        #expect(editor.selectedID == nil)
        editor.addDraft()
        #expect(editor.searchText.isEmpty)
        #expect(editor.selectedDraft?.text == "")
        editor.deleteSelected()
        #expect(editor.drafts.count == 2)
        #expect(!editor.dirty)
        model.updateSettings { $0.isPaused = true }
        editor.previewSelected()
        #expect(!model.panel.isPresented)
        editor.searchText = "book"
        editor.selectSearchResult()
        editor.deleteSelected()
        #expect(editor.filteredDrafts.isEmpty)
        #expect(editor.selectedID == nil)
        #expect(editor.dirty)
    }

    @Test func panelResizesHostedContentExactlyAndNeverBecomesKey() throws {
        _ = NSApplication.shared
        guard !NSScreen.screens.isEmpty else {
            Issue.record("Native window checks require a logged-in graphical Mac session.")
            return
        }
        let panel = NotchPanelController(reduceMotion: { true })
        defer { panel.shutdown() }
        panel.configure(quote: Quote(text: "中文 🌱\n第二行", source: "示例"),
                        active: true, hoverEnabled: true, showIndicator: false, screen: "auto")
        #expect(panel.windowFrame.height == 8)
        #expect(panel.hostedFrame == nil)
        panel.present(duration: 10)
        #expect(panel.isPresented)
        #expect(panel.hostedFrame?.width == panel.windowFrame.width)
        #expect(panel.hostedFrame?.height == panel.windowFrame.height - panel.contentInset)
        #expect(panel.hostedFrame?.origin == .zero)
        #expect(!panel.isAnimating)
        #expect(!panel.canBecomeKey)
        #expect(panel.headerIsVisible)
        #expect(panel.headerFrames.count == 2)
        for frame in panel.headerFrames {
            #expect(panel.windowFrame.contains(frame))
            #expect(!frame.intersects(panel.physicalNotchFrame))
            #expect(frame.maxY == panel.windowFrame.maxY)
            #expect(frame.minY >= panel.windowFrame.minY + (panel.hostedFrame?.maxY ?? 0))
        }
        panel.collapse()
        #expect(panel.windowFrame.height == 8)
        #expect(panel.hostedFrame == nil)
        #expect(panel.headerFrames.isEmpty)
        #expect(!panel.headerIsVisible)
        panel.configure(quote: Quote(text: String(repeating: "长文段落 🌱\n", count: 100)),
                        active: true, hoverEnabled: true, showIndicator: false, screen: "auto")
        panel.present(duration: 10)
        #expect(panel.hostedFrame?.width == panel.windowFrame.width)
        #expect(panel.hostedFrame?.height == panel.windowFrame.height - panel.contentInset)
        #expect(panel.windowFrame.height <= 332 + panel.notchInset)
    }

    @Test(arguments: [false, true])
    func motionKeepsTopAnchoredAndCanReverseWithoutJumping(indicator: Bool) {
        _ = NSApplication.shared
        let panel = NotchPanelController(reduceMotion: { false })
        defer { panel.shutdown() }
        panel.configure(quote: Quote(text: "从刘海展开的内容"), active: true, hoverEnabled: true, showIndicator: indicator, screen: "auto")
        panel.present(duration: 10)
        let start = panel.windowFrame
        #expect(panel.isAnimating)
        #expect(panel.contentOpacity == 0)
        #expect(!panel.headerIsVisible)
        panel.advanceAnimationForTesting(to: 0.5)
        let middle = panel.windowFrame
        #expect(middle.width > start.width)
        #expect(middle.height > start.height)
        #expect(abs(middle.maxY - start.maxY) < 1)
        #expect(panel.contentOpacity > 0 && panel.contentOpacity < 1)
        panel.collapse()
        #expect(panel.windowFrame == middle)
        panel.advanceAnimationForTesting(to: 0.5)
        let shrinking = panel.windowFrame
        #expect(shrinking.height < middle.height)
        #expect(abs(shrinking.maxY - start.maxY) < 1)
        panel.present(duration: 10)
        #expect(panel.windowFrame == shrinking)
        panel.advanceAnimationForTesting(to: 1)
        #expect(panel.isPresented)
        #expect(!panel.isAnimating)
        #expect(panel.contentOpacity == 1)
        #expect(panel.headerIsVisible)
        for frame in panel.headerFrames {
            #expect(!frame.intersects(panel.physicalNotchFrame))
        }
        #expect(abs(panel.windowFrame.maxY - start.maxY) < 1)
        #expect(panel.hostedFrame?.maxY == panel.windowFrame.height - panel.contentInset)
        panel.collapse()
        panel.advanceAnimationForTesting(to: 1)
        #expect(!panel.isAnimating)
        #expect(!panel.surfaceIsVisible)
        #expect(panel.headerFrames.isEmpty)
        #expect(panel.hostedFrame == nil)
        #expect(panel.windowFrame.height == (indicator ? max(24, panel.notchInset) : 8))
        #expect(panel.indicatorIsVisible == indicator)
    }

    @Test func hidingOrRelocatingDuringMotionCancelsSurfaceImmediately() {
        _ = NSApplication.shared
        let panel = NotchPanelController(reduceMotion: { false })
        defer { panel.shutdown() }
        let quote = Quote(text: "暂停和屏幕变化不能留下正在播放的卡片")
        panel.configure(quote: quote, active: true, hoverEnabled: true, showIndicator: false, screen: "auto")
        panel.present(duration: 10)
        panel.advanceAnimationForTesting(to: 0.5)
        panel.configure(quote: quote, active: false, hoverEnabled: true, showIndicator: false, screen: "auto")
        #expect(!panel.isAnimating)
        #expect(!panel.surfaceIsVisible)
        panel.advanceAnimationForTesting(to: 1)
        #expect(panel.hostedFrame == nil)
        panel.configure(quote: quote, active: true, hoverEnabled: true, showIndicator: false, screen: "auto")
        panel.present(duration: 10)
        panel.advanceAnimationForTesting(to: 0.5)
        panel.relocate()
        #expect(!panel.isPresented)
        #expect(!panel.isAnimating)
        #expect(!panel.surfaceIsVisible)
        #expect(panel.windowFrame.height == 8)
    }

    @Test func indicatorLayerSettingsAndYielding() {
        _ = NSApplication.shared
        let panel = NotchPanelController(reduceMotion: { true })
        defer { panel.shutdown() }
        let quote = Quote(text: "默认标识与展开层级")
        panel.configure(quote: quote, active: true, hoverEnabled: true, screen: "auto")
        #expect(panel.indicatorIsVisible)
        #expect(panel.hostedFrame == nil)
        #expect(panel.windowFrame.height == (panel.notchInset > 0 ? panel.notchInset : 24))
        if panel.notchInset > 0 {
            #expect(panel.windowFrame.maxY == panel.physicalNotchFrame.maxY)
            #expect(panel.windowFrame.minY == panel.physicalNotchFrame.minY)
            #expect(!panel.indicatorSymbolFrame.intersects(panel.physicalNotchFrame))
            #expect(panel.windowFrame.contains(panel.indicatorSymbolFrame))
        }
        panel.present(duration: 10)
        #expect(!panel.indicatorIsVisible)
        #expect(panel.windowLevel.rawValue > NSWindow.Level.statusBar.rawValue)
        #expect(panel.windowLevel.rawValue < NSWindow.Level.popUpMenu.rawValue)
        #expect(!panel.canBecomeKey)
        var settingsRequests = 0
        panel.onOpenSettings = { settingsRequests += 1 }
        panel.openSettings()
        #expect(settingsRequests == 1)
        #expect(!panel.isPresented)
        #expect(panel.indicatorIsVisible)
        panel.configure(quote: quote, active: true, hoverEnabled: false, showIndicator: false, screen: "auto")
        #expect(!panel.windowIsVisible)
        panel.present(duration: 10)
        #expect(panel.isPresented)
        panel.configure(quote: quote, active: false, hoverEnabled: true, screen: "auto")
        #expect(!panel.windowIsVisible)
        panel.configure(quote: nil, active: true, hoverEnabled: true, screen: "auto")
        #expect(panel.indicatorIsVisible)
        panel.present(duration: 10)
        #expect(!panel.isPresented)
    }

    @Test func geometryFollowsNotchAcrossScreenOrigins() {
        for origin in [NSPoint.zero, NSPoint(x: -1728, y: 400), NSPoint(x: 200, y: -1200)] {
            let top = origin.y + 1117
            let geometry = NotchGeometry(anchor: NSPoint(x: origin.x + 864, y: top - 32), width: 185, depth: 32)
            #expect(geometry.indicatorFrame.maxY == top)
            #expect(geometry.indicatorFrame.minY == geometry.cameraFrame.minY)
            #expect(geometry.indicatorFrame.midX == geometry.cameraFrame.midX)
            #expect(geometry.indicatorFrame.contains(geometry.symbolFrame))
            #expect(geometry.symbolFrame.maxX < geometry.cameraFrame.minX)
            #expect(geometry.symbolFrame.minX - geometry.indicatorFrame.minX >= 6)
            #expect(geometry.cameraFrame.minX - geometry.symbolFrame.maxX >= 6)
            #expect(geometry.cameraFrame.minX - geometry.indicatorFrame.minX == NotchGeometry.compactWing)
            #expect(geometry.indicatorFrame.maxX - geometry.cameraFrame.maxX == NotchGeometry.compactWing)
            #expect(geometry.symbolFrame.midX == geometry.indicatorFrame.minX + NotchGeometry.compactWing / 2)
            #expect(geometry.symbolFrame.midY == geometry.indicatorFrame.midY)
        }
        let fallback = NotchGeometry(anchor: NSPoint(x: 1000, y: 900), width: 160, depth: 0)
        #expect(fallback.indicatorFrame.maxY == 900)
        #expect(fallback.indicatorFrame.width == 28)
        #expect(fallback.indicatorFrame.contains(fallback.symbolFrame))
        #expect(fallback.symbolFrame.midX == fallback.indicatorFrame.midX)
    }

    @Test func editorCloseProtectsDraftAndRequiresSuccessfulSave() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.editor-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer { model.shutdown() }
        _ = try model.saveContent([Quote(text: "原文")], expectedFileData: nil)
        let editor = ContentEditorSession(model: model)
        editor.load()
        var prompted = false
        #expect(editor.prepareToClose { prompted = true; return .cancel })
        #expect(!prompted)
        editor.drafts[0].text = "未保存的中文草稿"
        #expect(!editor.prepareToClose { .cancel })
        #expect(editor.dirty)
        #expect(try model.store.editorSnapshot().quotes.first?.text == "原文")
        #expect(editor.prepareToClose { .save })
        #expect(!editor.dirty)
        #expect(try model.store.editorSnapshot().quotes.first?.text == "未保存的中文草稿")

        editor.drafts[0].text = "发生冲突时仍保留的草稿"
        try Data("[{\"text\":\"外部导入\"}]".utf8).write(to: model.store.fileURL)
        #expect(!editor.prepareToClose { .save })
        #expect(editor.dirty)
        #expect(editor.failure != nil)
        #expect(editor.drafts[0].text == "发生冲突时仍保留的草稿")
        #expect(try model.store.editorSnapshot().quotes.first?.text == "外部导入")
        #expect(editor.prepareToClose { .discard })
        #expect(!editor.dirty)
        #expect(!editor.loaded)
        editor.load()
        #expect(editor.drafts[0].text == "外部导入")

        // A filesystem failure also leaves the app open with the draft intact.
        let fresh = directory.appendingPathComponent("unwritable-parent")
        try Data("not a directory".utf8).write(to: fresh)
        let broken = RecallModel(dataDirectory: fresh, userDefaults: defaults)
        defer { broken.shutdown() }
        let failedEditor = ContentEditorSession(model: broken)
        failedEditor.load()
        failedEditor.drafts.append(QuoteDraft(Quote(text: "写入失败仍保留")))
        #expect(!failedEditor.prepareToClose { .save })
        #expect(failedEditor.dirty)
        #expect(failedEditor.failure != nil)
    }

    @Test func readingAppearanceResizesWithoutMovingNotchOrOpeningCollapsedCard() {
        _ = NSApplication.shared
        let panel = NotchPanelController(reduceMotion: { true })
        defer { panel.shutdown() }
        let quote = Quote(text: String(repeating: "长笔记需要更舒适的阅读空间。\n", count: 100), source: "示例")
        panel.configure(quote: quote, active: true, hoverEnabled: false, screen: "auto",
                        fontSize: 14, panelWidth: 420, maxTextHeight: 160)
        #expect(!panel.isPresented)
        panel.present(duration: 10)
        let before = panel.windowFrame
        #expect(panel.displayedFontSize == 14)
        #expect(panel.displayedTextHeight == 160)
        panel.configure(quote: quote, active: true, hoverEnabled: false, screen: "auto",
                        fontSize: 22, panelWidth: 620, maxTextHeight: 400)
        #expect(panel.displayedFontSize == 22)
        #expect((panel.displayedTextHeight ?? 0) <= 400)
        #expect(panel.windowFrame.width > before.width)
        #expect(panel.windowFrame.height > before.height)
        #expect(panel.windowFrame.maxY == before.maxY)
        for frame in panel.headerFrames {
            #expect(!frame.intersects(panel.physicalNotchFrame))
        }
        panel.collapse()
        panel.configure(quote: quote, active: true, hoverEnabled: false, screen: "auto",
                        fontSize: 17, panelWidth: 537, maxTextHeight: 289)
        #expect(!panel.isPresented)
        panel.present(duration: 10)
        #expect(panel.displayedFontSize == 17)
        #expect(panel.displayedTextHeight == 289)
        #expect(panel.windowFrame.width >= 537)
    }

    @Test func headerKeepsReadableControlsOutsideDifferentCameraSizes() {
        for cameraWidth: CGFloat in [0, 160, 185, 240, 300] {
            for depth: CGFloat in [0, 32, 38] {
                let width = max(420, cameraWidth + 224)
                let height = max(32, depth)
                let layout = NotchHeaderLayout(size: NSSize(width: width, height: height), cameraWidth: cameraWidth)
                let camera = NSRect(x: (width - cameraWidth) / 2, y: height - depth,
                                    width: cameraWidth, height: depth)
                #expect(layout.fits)
                #expect(layout.left.width >= 88)
                #expect(layout.right.width >= 88) // Three 24 pt hit targets and two 8 pt gaps.
                #expect(layout.left.maxX <= camera.minX)
                #expect(layout.right.minX >= camera.maxX)
                #expect(!layout.left.intersects(camera))
                #expect(!layout.right.intersects(camera))
                #expect(layout.left.maxY == height && layout.right.maxY == height)
            }
        }
        // An unusually narrow display must not squeeze controls into the camera area.
        #expect(!NotchHeaderLayout(size: NSSize(width: 300, height: 32), cameraWidth: 185).fits)
    }

    @Test func manualActionsPauseReloadAndScheduledRecovery() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Remeet.native-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("quotes.json")
        try Data(#"[{"text":"A"},{"text":"B"}]"#.utf8).write(to: file)
        let model = RecallModel(dataDirectory: directory, userDefaults: defaults)
        defer {
            model.shutdown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        model.start()
        #expect(!model.panel.isPresented)
        let beforeEdit = try model.store.editorSnapshot()
        let beforeDue = model.nextRecallDate
        _ = try model.saveContent([Quote(text: "自定义 A"), Quote(text: "自定义 B")], expectedFileData: beforeEdit.fileData)
        #expect(model.store.quotes.contains(try #require(model.currentQuote)))
        #expect(!model.panel.isPresented)
        #expect(model.nextRecallDate == beforeDue)
        let initial = model.currentQuote
        let due = model.nextRecallDate
        model.remindCurrent()
        #expect(model.currentQuote == initial)
        #expect(model.panel.isPresented)
        model.remindNext()
        #expect(model.currentQuote != initial)
        #expect(model.nextRecallDate == due)
        model.updateSettings { $0.isPaused = true }
        #expect(!model.panel.isPresented)
        let before = model.currentQuote
        model.remindNext()
        #expect(model.currentQuote == before)
        model.handleScheduledEvent(.scheduled)
        #expect(model.currentQuote != before)
        #expect(!model.panel.isPresented)
        model.updateSettings { $0.isPaused = false; $0.autoPresent = false; $0.hoverPresent = false }
        #expect(!model.panel.isPresented)
        model.remindCurrent()
        #expect(model.panel.isPresented)
        model.handleScheduledEvent(.recovered)
        #expect(!model.panel.isPresented)
        let retained = model.currentQuote
        try Data("bad json".utf8).write(to: file)
        model.reload()
        #expect(model.currentQuote == retained)
        #expect(model.errorMessage != nil)
        try Data("[]".utf8).write(to: file)
        model.reload()
        #expect(model.currentQuote == nil)
        #expect(!model.canRemind)
        model.remindCurrent()
        #expect(!model.panel.isPresented)
        #expect(model.errorMessage == nil)
    }
}
