import AppKit
import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import RemeetCore
#endif

struct QuoteDraft: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var source: String
    var tags: [String]
    var tagInput = ""
    // Include unsubmitted input in saves and close protection, just like the body.
    var quote: Quote {
        Quote(text: text, source: source.isEmpty ? nil : source,
              tags: tags + tagInput.components(separatedBy: CharacterSet(charactersIn: ",，\n")))
    }
    init(_ quote: Quote = Quote(text: "")) {
        text = quote.text
        source = quote.source ?? ""
        tags = quote.tags
    }
}

// Select the macOS 14 property wrapper explicitly; newer SDKs also export a State macro.
private typealias EditorState<Value> = SwiftUI.State<Value>

@MainActor
final class ContentEditorSession: ObservableObject {
    enum CloseDecision { case save, discard, cancel }
    enum TagFilter: Hashable { case all, untagged, tag(String) }
    private let model: RecallModel
    @Published var drafts: [QuoteDraft] = []
    @Published var selectedID: UUID?
    @Published var searchText = ""
    @Published var tagFilter = TagFilter.all
    @Published private var deletedDrafts: [(draft: QuoteDraft, index: Int)] = []
    var canUndoDelete: Bool { !deletedDrafts.isEmpty }
    var availableTags: [String] {
        // Committed tags only: half-typed input must not appear as a filter or reusable tag.
        Array(Set(drafts.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var selectedDraft: QuoteDraft? { drafts.first { $0.id == selectedID } }
    var filteredDrafts: [QuoteDraft] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty, case .all = tagFilter { return drafts }
        return drafts.filter { draft in
            let tags = draft.quote.tags
            let matchesTag: Bool
            switch tagFilter {
            case .all: matchesTag = true
            case .untagged: matchesTag = tags.isEmpty
            case .tag(let tag): matchesTag = tags.contains(tag)
            }
            return matchesTag && (query.isEmpty || draft.text.localizedCaseInsensitiveContains(query)
                || draft.source.localizedCaseInsensitiveContains(query)
                || tags.contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }

    func addTag(_ tag: String? = nil) {
        guard let index = drafts.firstIndex(where: { $0.id == selectedID }) else { return }
        drafts[index].tags = Quote(text: "", tags: drafts[index].quote.tags + (tag.map { [$0] } ?? [])).tags
        drafts[index].tagInput = ""
    }

    func removeTag(_ tag: String) {
        guard let index = drafts.firstIndex(where: { $0.id == selectedID }) else { return }
        drafts[index].tags.removeAll { $0 == tag }
    }

    func addDraft() {
        let draft = QuoteDraft()
        searchText = ""
        tagFilter = .all
        drafts.append(draft)
        selectedID = draft.id
        message = nil
    }

    func deleteSelected() {
        guard let index = drafts.firstIndex(where: { $0.id == selectedID }) else { return }
        deletedDrafts.append((drafts[index], index))
        drafts.remove(at: index)
        selectedID = drafts.isEmpty ? nil : drafts[min(index, drafts.count - 1)].id
        selectSearchResult()
        message = nil
    }

    func undoDelete() {
        guard let deleted = deletedDrafts.popLast() else { return }
        drafts.insert(deleted.draft, at: min(deleted.index, drafts.count))
        searchText = ""
        tagFilter = .all
        selectedID = deleted.draft.id
        message = nil
    }

    /// Stage recovery against the existing file baseline; saving still detects external changes.
    @discardableResult
    func loadBackup(_ backup: QuoteStore.Backup) -> Bool {
        guard loaded else { return false }
        do {
            let quotes = try QuoteStore.decode(Data(contentsOf: backup.url))
            drafts = quotes.map(QuoteDraft.init)
            selectedID = drafts.first?.id
            searchText = ""
            tagFilter = .all
            deletedDrafts = []
            failure = nil
            message = dirty ? "备份已载入为草稿，检查后点击“保存并生效”。" : "备份与当前内容一致，无需保存。"
            return true
        } catch {
            failure = "无法载入备份：\(error.localizedDescription)"
            return false
        }
    }

    func selectSearchResult() {
        let matches = filteredDrafts
        if !matches.contains(where: { $0.id == selectedID }) { selectedID = matches.first?.id }
    }

    func previewSelected() {
        guard loaded, !dirty, let quote = selectedDraft?.quote else { return }
        model.preview(quote)
    }

    @Published private(set) var loaded = false
    @Published var message: String?
    @Published private(set) var failure: String?
    @Published private(set) var draftExportResult: Result<URL, Error>?
    @Published private(set) var savedExportResult: Result<URL, Error>?
    private var baseline: [Quote] = []
    private var fileData: Data?
    var dirty: Bool {
        guard drafts.count == baseline.count else { return true }
        return zip(drafts, baseline).contains { draft, saved in draft.quote != saved }
    }

    init(model: RecallModel) { self.model = model }

    struct PendingImport: Identifiable {
        let id = UUID()
        let url: URL
        let sourceData: Data
        let targetData: Data?
        let existing: [Quote]
        let preview: QuoteStore.ImportPreview
    }
    @Published private(set) var pendingImport: PendingImport?
    @Published private(set) var importFailure: String?

    func chooseImportFile() {
        guard loaded, !dirty else {
            importFailure = "请先保存修改，或导出草稿后重新载入，再导入 JSON。"
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "预览导入"
        if panel.runModal() == .OK, let url = panel.url { previewImport(from: url) }
    }

    func previewImport(from url: URL) {
        pendingImport = nil
        importFailure = nil
        guard loaded, !dirty else {
            importFailure = "请先保存修改，或导出草稿后重新载入，再导入 JSON。"
            return
        }
        do {
            let target = try model.store.editorSnapshot()
            guard target.fileData == fileData else { throw QuoteStore.SaveError.changedOnDisk }
            let data = try Data(contentsOf: url)
            let preview = try QuoteStore.previewImport(data, existing: target.quotes)
            pendingImport = PendingImport(url: url, sourceData: data, targetData: target.fileData,
                                          existing: baseline, preview: preview)
        } catch { importFailure = "无法预览导入：\(error.localizedDescription)" }
    }

    func cancelImport() {
        pendingImport = nil
        importFailure = nil
    }

    @discardableResult
    func confirmImport() -> Bool {
        guard let pending = pendingImport else { return false }
        guard loaded, !dirty, baseline == pending.existing, fileData == pending.targetData else {
            importFailure = "草稿或已载入内容已变化，请取消导入，处理当前修改后重新预览。"
            return false
        }
        do {
            guard try Data(contentsOf: pending.url) == pending.sourceData else {
                importFailure = "导入文件已变化，请取消后重新选择文件并预览。"
                return false
            }
            guard try model.store.editorSnapshot().fileData == pending.targetData else {
                throw QuoteStore.SaveError.changedOnDisk
            }
            // A duplicate-only or empty import must not rewrite even noncanonical JSON.
            guard pending.preview.addedCount > 0 else {
                importFailure = "没有可新增的内容，内容文件未写入。"
                return false
            }
            apply(try model.saveContent(pending.preview.merged, expectedFileData: pending.targetData))
            message = "已导入 \(pending.preview.addedCount) 条，跳过重复 \(pending.preview.duplicateCount) 条、空白 \(pending.preview.blankCount) 条。"
            cancelImport()
            return true
        } catch {
            importFailure = "导入失败，预览已保留：\(error.localizedDescription)"
            return false
        }
    }

    func load() {
        do {
            apply(try model.store.editorSnapshot())
            message = nil
        } catch { failure = "无法载入内容：\(error.localizedDescription)" }
    }

    @discardableResult
    func save(confirmDiscarded: (([Quote], [Int]) -> Bool)? = nil) -> Bool {
        let quotes = drafts.map(\.quote)
        let discarded = QuoteStore.normalize(quotes).discardedIndices
        if !discarded.isEmpty,
           !(confirmDiscarded ?? Self.confirmDiscardedQuotes)(quotes, discarded) { return false }
        // A modal confirmation runs an event loop; never save an unreviewed replacement draft.
        guard quotes == drafts.map(\.quote) else {
            failure = "草稿已变化，请重新检查后保存。"
            return false
        }
        do {
            apply(try model.saveContent(quotes, expectedFileData: fileData))
            message = "已保存，回顾内容已更新。"
            return true
        } catch {
            failure = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    private static func confirmDiscardedQuotes(_ quotes: [Quote], _ discarded: [Int]) -> Bool {
        let alert = NSAlert()
        alert.messageText = "有 \(discarded.count) 条内容不会保存"
        alert.informativeText = "空白正文会被忽略；同正文只保留列表中的第一条及其来源、标签。以下条目的来源和标签不会合并，可返回编辑或先导出草稿。"
        alert.addButton(withTitle: "返回编辑")
        alert.addButton(withTitle: "确认忽略并保存")
        alert.buttons[0].keyEquivalent = "\u{1b}"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.contentView.bounds)
        text.isEditable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.font = .systemFont(ofSize: 13)
        text.string = discarded.map { index in
            let quote = quotes[index]
            let blank = quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return """
            第 \(index + 1) 条 · \(blank ? "空白正文" : "重复正文")
            正文：\(blank ? "（空白）" : quote.text)
            来源：\(quote.source ?? "（无）")
            标签：\(quote.tags.isEmpty ? "（无）" : quote.tags.joined(separator: "、"))
            """
        }.joined(separator: "\n\n")
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert.runModal() == .alertSecondButtonReturn
    }

    func exportSavedContent(chooseDestination: (() -> URL?)? = nil) {
        guard loaded, let url = (chooseDestination ?? Self.chooseSavedExportDestination)() else { return }
        savedExportResult = Result {
            try model.store.exportSavedContent(to: url)
            return url
        }
    }

    private static func chooseSavedExportDestination() -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出已保存内容"
        panel.message = "导出磁盘上已保存的全部内容，不受筛选影响，也不包含未保存的草稿。"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Remeet-content.json"
        panel.prompt = "导出"
        return panel.runModal() == .OK ? panel.url : nil
    }

    func exportDrafts() {
        guard loaded else { return }
        draftExportResult = Result {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            // Keep blank/duplicate entries and body whitespace; save normalization would lose edits.
            let data = try encoder.encode(drafts.map(\.quote))
            let directory = model.store.fileURL.deletingLastPathComponent()
                .appendingPathComponent("draft-exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("Remeet-draft-\(UUID().uuidString).json")
            try data.write(to: url, options: .withoutOverwriting)
            return url
        }
    }

    /// Both window close and app termination use the same save/conflict policy.
    func prepareToClose(confirmDiscarded: (([Quote], [Int]) -> Bool)? = nil,
                        decide: () -> CloseDecision) -> Bool {
        guard dirty else { return true }
        switch decide() {
        case .cancel: return false
        case .save: return save(confirmDiscarded: confirmDiscarded)
        case .discard:
            deletedDrafts = []
            drafts = []
            selectedID = nil
            baseline = []
            fileData = nil
            loaded = false
            message = nil
            failure = nil
            return true
        }
    }

    private func apply(_ snapshot: QuoteStore.EditorSnapshot) {
        deletedDrafts = []
        let selectedText = selectedDraft?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousIndex = drafts.firstIndex { $0.id == selectedID } ?? 0
        drafts = snapshot.quotes.map(QuoteDraft.init)
        selectedID = drafts.first(where: { $0.text == selectedText })?.id
            ?? (drafts.isEmpty ? nil : drafts[min(previousIndex, drafts.count - 1)].id)
        selectSearchResult()
        baseline = drafts.map(\.quote)
        fileData = snapshot.fileData
        loaded = true
        failure = nil
        importFailure = nil
    }
}

struct ContentEditorView: View {
    @ObservedObject var model: RecallModel
    @ObservedObject var editor: ContentEditorSession
    @EditorState private var confirmReload = false
    @EditorState private var showBackups = false
    @EditorState private var backups: [QuoteStore.Backup] = []
    @EditorState private var backupError: String?
    @EditorState private var pendingBackup: QuoteStore.Backup?
    @EditorState private var confirmBackup = false

    private func textBinding(_ id: UUID, _ key: WritableKeyPath<QuoteDraft, String>) -> Binding<String> {
        Binding(get: { editor.drafts.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in
                    guard let index = editor.drafts.firstIndex(where: { $0.id == id }) else { return }
                    editor.drafts[index][keyPath: key] = value
                })
    }

    var body: some View {
        // Every keystroke re-renders this whole view; derive these once per render, not at each use.
        let dirty = editor.dirty
        let tags = editor.availableTags
        let filtered = editor.filteredDrafts
        VStack(spacing: 0) {
            HStack {
                Text("我的内容").font(.title2.bold())
                Text("\(editor.drafts.count) 条").foregroundStyle(.secondary)
                Spacer()
                Button("撤销删除", action: editor.undoDelete).disabled(!editor.canUndoDelete)
                Button("新增一条", action: editor.addDraft).disabled(!editor.loaded)
                Button("导入 JSON") { editor.chooseImportFile() }.disabled(!editor.loaded)
                Button("重新载入") {
                    if editor.dirty { confirmReload = true } else { editor.load() }
                }
            }.padding(16)
            Divider()
            HSplitView {
                VStack(spacing: 8) {
                    TextField("搜索正文、来源或标签", text: $editor.searchText)
                        .textFieldStyle(.roundedBorder).padding([.horizontal, .top], 12)
                        .accessibilityLabel("搜索笔记")
                    Picker("标签", selection: $editor.tagFilter) {
                        Text("全部").tag(ContentEditorSession.TagFilter.all)
                        Text("默认（无标签）").tag(ContentEditorSession.TagFilter.untagged)
                        ForEach(tags, id: \.self) { tag in
                            Text("#\(tag)").tag(ContentEditorSession.TagFilter.tag(tag))
                        }
                        if case .tag(let tag) = editor.tagFilter, !tags.contains(tag) {
                            Text("#\(tag)（0 条）").tag(ContentEditorSession.TagFilter.tag(tag))
                        }
                    }.padding(.horizontal, 12).accessibilityLabel("按标签筛选")
                    List(selection: $editor.selectedID) {
                        ForEach(filtered) { draft in
                            DraftRow(draft: draft).equatable().tag(draft.id)
                        }
                    }.listStyle(.sidebar)
                    Text("\(filtered.count) / \(editor.drafts.count) 条")
                        .font(.caption).foregroundStyle(.secondary).padding(.bottom, 10)
                }.frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                VStack(alignment: .leading, spacing: 12) {
                    if let draft = editor.selectedDraft {
                        HStack {
                            Text("正文").font(.headline)
                            Spacer()
                            Button("删除这条", role: .destructive, action: editor.deleteSelected)
                        }
                        TextEditor(text: textBinding(draft.id, \.text))
                            .font(.body).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("笔记正文")
                            .id(draft.id)
                        TextField("来源（可选）", text: textBinding(draft.id, \.source))
                            .textFieldStyle(.roundedBorder).accessibilityLabel("笔记来源")
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("标签").font(.subheadline)
                                if draft.quote.tags.isEmpty { Text("默认（无标签）").font(.caption).foregroundStyle(.secondary) }
                                ScrollView(.horizontal) {
                                    HStack(spacing: 6) {
                                        ForEach(draft.tags, id: \.self) { tag in
                                            Button { editor.removeTag(tag) } label: {
                                                HStack(spacing: 4) {
                                                    Text(tag).lineLimit(1)
                                                    Image(systemName: "xmark").font(.caption2)
                                                }
                                            }.buttonStyle(.bordered).controlSize(.small)
                                                .accessibilityLabel("移除标签 \(tag)")
                                        }
                                    }
                                }.scrollIndicators(.hidden)
                            }
                            HStack {
                                TextField("新增标签，多个用逗号分隔", text: textBinding(draft.id, \.tagInput))
                                    .textFieldStyle(.roundedBorder).accessibilityLabel("新增标签")
                                    .onSubmit { editor.addTag() }
                                Button("添加") { editor.addTag() }
                                    .disabled(draft.tagInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    .accessibilityLabel("添加标签")
                                Menu("已有标签") {
                                    ForEach(tags, id: \.self) { tag in
                                        Button(tag) { editor.addTag(tag) }.disabled(draft.quote.tags.contains(tag))
                                    }
                                }.fixedSize().disabled(tags.isEmpty)
                            }
                        }
                        HStack {
                            Text(dirty ? "先保存修改，再预览这条笔记。" : "预览只展示这条笔记，不改变随机回顾计划。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("预览这条", action: editor.previewSelected)
                                .disabled(!editor.loaded || dirty || !model.canRemind)
                        }
                    } else {
                        Spacer()
                        Text(editor.drafts.isEmpty ? "还没有笔记，点击“新增一条”开始。" : filtered.isEmpty ? "没有匹配的笔记，试试其他关键词或标签。" : "从左侧选择一条笔记。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    }
                }.padding(20).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let failure = editor.importFailure {
                    Text(failure).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    if let failure = editor.failure {
                        Text(failure).foregroundStyle(.red).font(.callout)
                    } else if dirty {
                        Text("有未保存的修改 · 切换笔记会保留草稿").foregroundStyle(.secondary).font(.callout)
                    } else if let message = editor.message {
                        Text(message).foregroundStyle(.secondary).font(.callout)
                    }
                    if editor.loaded && dirty {
                        Spacer()
                        Button("导出草稿", action: editor.exportDrafts).fixedSize()
                    }
                }
                if let result = editor.draftExportResult {
                    switch result {
                    case .success(let url):
                        HStack {
                            Text("草稿副本已另存；之后的修改需重新导出。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("查看文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    case .failure(let error):
                        Text("草稿导出失败：\(error.localizedDescription)").foregroundStyle(.red).font(.callout)
                    }
                }
                if let result = editor.savedExportResult {
                    switch result {
                    case .success(let url):
                        HStack {
                            Text("已保存内容已导出，不含未保存草稿；之后的修改需重新导出。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("查看导出文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                    case .failure(let error):
                        Text("已保存内容导出失败：\(error.localizedDescription)").foregroundStyle(.red).font(.callout)
                    }
                }
                if model.settings.isPaused {
                    Text("回顾展示已暂停，可从菜单栏或设置恢复。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("打开数据目录") { model.openDataDirectory() }
                    Button("恢复备份") {
                        showBackups = true
                    }.disabled(!editor.loaded)
                    Button("导出已保存 JSON") { editor.exportSavedContent() }.disabled(!editor.loaded)
                    Text("空白不保存，同正文去重。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存并生效", action: { editor.save() })
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!editor.loaded || !dirty)
                }
            }.padding(16)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { if !editor.loaded { editor.load() } }
        .onChange(of: editor.searchText) { _, _ in editor.selectSearchResult() }
        .onChange(of: editor.tagFilter) { _, _ in editor.selectSearchResult() }
        .sheet(item: Binding(get: { editor.pendingImport }, set: { if $0 == nil { editor.cancelImport() } })) { pending in
            ContentImportView(editor: editor, pending: pending)
        }
        .sheet(isPresented: $showBackups) {
            VStack(alignment: .leading, spacing: 16) {
                Text("恢复备份").font(.title2.bold())
                Text("保留最近 10 份 App 保存前备份。选择后先载入为草稿，检查后保存才会生效。")
                    .foregroundStyle(.secondary)
                if let backupError {
                    Text(backupError).foregroundStyle(.red)
                } else if backups.isEmpty {
                    Text("暂无备份。修改已有内容并保存时会自动创建。")
                } else {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(backups) { backup in
                                HStack {
                                    Text(backup.date.formatted(date: .numeric, time: .standard))
                                    Spacer()
                                    Button("载入为草稿") {
                                        pendingBackup = backup
                                        if editor.dirty { confirmBackup = true }
                                        else { editor.loadBackup(backup); showBackups = false }
                                    }
                                }
                            }
                        }
                    }.frame(maxHeight: 300)
                }
                HStack {
                    Spacer()
                    Button("取消") { showBackups = false }.keyboardShortcut(.cancelAction)
                }
            }.padding(24).frame(width: 480)
            .onAppear {
                do {
                    backups = try model.store.backups()
                    backupError = nil
                } catch {
                    backups = []
                    backupError = "无法读取备份：\(error.localizedDescription)"
                }
            }
            .alert("放弃未保存的修改并载入备份？", isPresented: $confirmBackup, presenting: pendingBackup) { backup in
                Button("取消", role: .cancel) { pendingBackup = nil }
                Button("载入备份", role: .destructive) {
                    editor.loadBackup(backup)
                    pendingBackup = nil
                    showBackups = false
                }
            } message: { _ in
                Text("备份将替换当前草稿。内容文件仅在点击“保存并生效”后更新。")
            }
        }
        .alert("放弃未保存的修改并重新载入？", isPresented: $confirmReload) {
            Button("取消", role: .cancel) { }
            Button("重新载入", role: .destructive) { editor.load() }
        }
    }
}

/// Equatable so a keystroke re-renders only the edited row instead of every row in the list.
private struct DraftRow: View, Equatable {
    let draft: QuoteDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新笔记" : draft.text)
                .lineLimit(2)
            if !draft.source.isEmpty {
                Text(draft.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(draft.quote.tags.isEmpty ? "默认" : draft.quote.tags.map { "#\($0)" }.joined(separator: "  "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(.vertical, 5)
    }
}

struct ContentImportView: View {
    @ObservedObject var editor: ContentEditorSession
    let pending: ContentEditorSession.PendingImport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入 JSON 预览").font(.title2.bold())
            Text(pending.url.lastPathComponent).lineLimit(2).textSelection(.enabled)
            Text("新增 \(pending.preview.addedCount) 条 · 重复 \(pending.preview.duplicateCount) 条 · 空白 \(pending.preview.blankCount) 条")
                .font(.headline)
            Text("按去除首尾空白后的正文去重，保留已有条目或文件中第一条的来源和标签。确认后自动备份已有文件并合并生效。")
                .font(.callout).foregroundStyle(.secondary)
            if pending.preview.addedCount == 0 {
                Text("没有可新增的内容，不会写入文件或创建备份。")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(pending.preview.entries.indices, id: \.self) { index in
                        let entry = pending.preview.entries[index]
                        VStack(alignment: .leading, spacing: 5) {
                            Text("第 \(index + 1) 条 · \(entry.disposition.rawValue)").font(.headline)
                            Text(entry.disposition == .blank ? "（空白正文）" : entry.quote.text)
                            Text("来源：\(entry.quote.source ?? "（无）")")
                            Text("标签：\(entry.quote.tags.isEmpty ? "（无）" : entry.quote.tags.joined(separator: "、"))")
                        }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        Divider()
                    }
                }
            }.frame(height: 260)
            if let failure = editor.importFailure { Text(failure).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { editor.cancelImport() }.keyboardShortcut(.cancelAction)
                Button("确认合并并生效") { editor.confirmImport() }
                    .disabled(pending.preview.addedCount == 0)
            }
        }.padding(24).frame(width: 520)
    }
}
