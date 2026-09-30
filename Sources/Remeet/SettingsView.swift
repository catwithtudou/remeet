import SwiftUI
#if SWIFT_PACKAGE
import RemeetCore
#endif

struct SettingsView: View {
    @ObservedObject var model: RecallModel
    var openContentEditor: () -> Void
    @EditorState private var frequencyChoice = RecallFrequency.hourly
    @EditorState private var intervalText = "45"
    @EditorState private var intervalUnit = 1
    @EditorState private var customReading = false
    @EditorState private var readingText = "10"

    private var customMinutes: Int? {
        guard let amount = Double(intervalText.trimmingCharacters(in: .whitespaces)), amount.isFinite else { return nil }
        let minutes = amount * Double(intervalUnit)
        guard minutes.isFinite, minutes >= 1, minutes <= 1440,
              abs(minutes - minutes.rounded()) < 0.000001 else { return nil }
        return Int(minutes.rounded())
    }

    private var customSeconds: Int? {
        guard let value = Int(readingText), RecallSettings.readingSecondsRange.contains(value) else { return nil }
        return value
    }

    private func intervalString(_ minutes: Double) -> String {
        let value = minutes / Double(intervalUnit)
        return value == value.rounded() ? String(format: "%.0f", value) : String(value)
    }

    private func binding<Value>(_ key: WritableKeyPath<RecallSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: key] },
                set: { value in model.updateSettings { $0[keyPath: key] = value } })
    }

    private func appearanceSlider(_ title: String, key: WritableKeyPath<RecallSettings, Int>,
                                  range: ClosedRange<Int>,
                                  lower: String, upper: String) -> some View {
        let standard = RecallSettings()[keyPath: key]
        let percent = Int((Double(model.settings[keyPath: key]) / Double(standard) * 100).rounded())
        return VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(percent)%").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(model.settings[keyPath: key]) },
                set: { value in model.updateSettings { $0[keyPath: key] = Int(value.rounded()) } }),
                in: Double(range.lowerBound)...Double(range.upperBound))
                .labelsHidden()
                .tint(Color(red: 0.27, green: 0.67, blue: 0.55))
                .accessibilityLabel(title)
                .accessibilityValue("\(percent)%")
            HStack {
                Text(lower)
                Spacer()
                Text(upper)
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    var body: some View {
        Form {
            Section("我的内容") {
                Button("我的内容", action: openContentEditor)
                Text("放入想再读一遍的笔记、摘录或问题。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("回顾") {
                Picker("回顾频率", selection: Binding(
                    get: { frequencyChoice },
                    set: { value in
                        frequencyChoice = value
                        if value != .custom { model.updateSettings { $0.frequency = value } }
                    })) {
                    ForEach(RecallFrequency.allCases, id: \.self) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                if frequencyChoice == .custom {
                    HStack {
                        TextField("间隔", text: $intervalText).frame(width: 90)
                            .accessibilityLabel("自定义回顾间隔")
                        Picker("单位", selection: $intervalUnit) {
                            Text("分钟").tag(1)
                            Text("小时").tag(60)
                        }.labelsHidden().frame(width: 90)
                        Button("应用") {
                            if let minutes = customMinutes {
                                model.updateSettings { $0.frequency = .custom; $0.customIntervalMinutes = minutes }
                            }
                        }.disabled(customMinutes == nil || (model.settings.frequency == .custom && customMinutes == model.settings.customIntervalMinutes))
                    }
                    Text(customMinutes == nil ? "请输入 1 分钟至 24 小时，精确到分钟。" : "从生效时开始按间隔回顾；重启后重新计时。")
                        .font(.caption).foregroundStyle(customMinutes == nil ? .red : .secondary)
                } else {
                    Text("按本机时钟的整点、半点或偶数整点对齐。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let next = model.nextRecallDate {
                    Text("\(model.settings.autoPresent && !model.settings.isPaused ? "下一次回顾" : "下一次内容更新")：\(next.formatted(date: .omitted, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("立即回顾") { model.remindCurrent() }
                    Button("换一条回顾") { model.remindNext() }
                }
                .disabled(!model.canRemind)
                Toggle("自动展开", isOn: binding(\.autoPresent))
                Text("关闭后仍定时换句，可随时手动查看。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("阅读外观") {
                appearanceSlider("文字大小", key: \.fontSize, range: RecallSettings.fontSizeRange,
                                 lower: "小", upper: "大")
                appearanceSlider("面板宽度", key: \.panelWidth, range: RecallSettings.panelWidthRange,
                                 lower: "窄", upper: "宽")
                appearanceSlider("阅读区域高度", key: \.maxTextHeight, range: RecallSettings.textHeightRange,
                                 lower: "紧凑", upper: "舒展")
                Text("100% 是默认大小。短内容自动收紧，长内容滚动阅读；面板会避让刘海并适应屏幕。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("恢复默认外观") {
                    model.updateSettings {
                        let defaults = RecallSettings()
                        $0.fontSize = defaults.fontSize
                        $0.panelWidth = defaults.panelWidth
                        $0.maxTextHeight = defaults.maxTextHeight
                    }
                }
            }
            Section("展示") {
                Picker("阅读时长", selection: Binding(
                    get: { customReading ? 0 : model.settings.readingSeconds },
                    set: { value in
                        customReading = value == 0
                        if value != 0 { model.updateSettings { $0.readingSeconds = value } }
                        readingText = String(model.settings.readingSeconds)
                    })) {
                    ForEach(RecallSettings.readingOptions, id: \.self) { seconds in
                        Text("\(seconds) 秒").tag(seconds)
                    }
                    Text("自定义").tag(0)
                }
                if customReading {
                    HStack {
                        TextField("秒数", text: $readingText).frame(width: 90)
                            .accessibilityLabel("自定义阅读秒数")
                        Text("秒")
                        Button("应用") {
                            if let seconds = customSeconds { model.updateSettings { $0.readingSeconds = seconds } }
                        }.disabled(customSeconds == nil || customSeconds == model.settings.readingSeconds)
                    }
                    Text(customSeconds == nil ? "请输入 1–3600 的整数秒数。" : "鼠标停留时保持展开，下一次展开使用新时长。")
                        .font(.caption).foregroundStyle(customSeconds == nil ? .red : .secondary)
                }
                Toggle("显示运行标识", isOn: binding(\.showIndicator))
                Toggle("悬停展开", isOn: binding(\.hoverPresent))
                Picker("显示屏幕", selection: binding(\.screen)) {
                    Text("自动选择（优先内置刘海屏）").tag("auto")
                    Text("系统主显示器").tag("primary")
                    ForEach(model.screens, id: \.id) { screen in
                        Text(screen.name).tag(screen.id)
                    }
                    if model.settings.screen != "auto", model.settings.screen != "primary",
                       !model.screens.contains(where: { $0.id == model.settings.screen }) {
                        Text("指定显示器未连接（已自动回退）").tag(model.settings.screen)
                    }
                }
            }
            Section("与其他刘海应用共存") {
                Button("让出刘海区域") {
                    model.updateSettings {
                        $0.showIndicator = false
                        $0.hoverPresent = false
                        $0.autoPresent = false
                    }
                    model.panel.collapse(immediately: true)
                }
                Text("关闭运行标识、悬停和自动展开，仍可从菜单栏手动回顾。需要时可分别重新开启。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.settings.isPaused {
                    HStack {
                        Text("展示已暂停")
                        Spacer()
                        Button("恢复展示") { model.updateSettings { $0.isPaused = false } }
                    }
                }
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                } else if model.isEmpty {
                    Text("暂无可用内容，请在“我的内容”中添加并保存笔记。")
                        .foregroundStyle(.secondary)
                }
                Text("自定义时间点击“应用”生效，其他设置自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 680)
        .onAppear {
            frequencyChoice = model.settings.frequency
            intervalText = intervalString(Double(model.settings.customIntervalMinutes))
            readingText = String(model.settings.readingSeconds)
            customReading = !RecallSettings.readingOptions.contains(model.settings.readingSeconds)
        }
        .onChange(of: intervalUnit) { old, _ in
            let minutes = Double(intervalText).flatMap { $0.isFinite ? $0 * Double(old) : nil }
            intervalText = intervalString(minutes.flatMap { $0.isFinite ? $0 : nil } ?? Double(model.settings.customIntervalMinutes))
        }
    }
}

struct QuoteDraft: Identifiable {
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
    var availableTags: [String] {
        Array(Set(drafts.flatMap { $0.quote.tags })).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var selectedDraft: QuoteDraft? { drafts.first { $0.id == selectedID } }
    var filteredDrafts: [QuoteDraft] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
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
        drafts.remove(at: index)
        selectedID = drafts.isEmpty ? nil : drafts[min(index, drafts.count - 1)].id
        selectSearchResult()
        message = nil
    }

    func selectSearchResult() {
        if !filteredDrafts.contains(where: { $0.id == selectedID }) { selectedID = filteredDrafts.first?.id }
    }

    func previewSelected() {
        guard loaded, !dirty, let quote = selectedDraft?.quote else { return }
        model.preview(quote)
    }

    @Published private(set) var loaded = false
    @Published var message: String?
    @Published private(set) var failure: String?
    private var baseline: [Quote] = []
    private var fileData: Data?
    var dirty: Bool { drafts.map(\.quote) != baseline }

    init(model: RecallModel) { self.model = model }

    func load() {
        do {
            apply(try model.store.editorSnapshot())
            message = nil
        } catch { failure = "无法载入内容：\(error.localizedDescription)" }
    }

    @discardableResult
    func save() -> Bool {
        do {
            apply(try model.saveContent(drafts.map(\.quote), expectedFileData: fileData))
            message = "已保存，回顾内容已更新。"
            return true
        } catch {
            failure = "保存失败：\(error.localizedDescription)"
            return false
        }
    }

    /// Both window close and app termination use the same save/conflict policy.
    func prepareToClose(decide: () -> CloseDecision) -> Bool {
        guard dirty else { return true }
        switch decide() {
        case .cancel: return false
        case .save: return save()
        case .discard:
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
    }
}

struct ContentEditorView: View {
    @ObservedObject var model: RecallModel
    @ObservedObject var editor: ContentEditorSession
    @EditorState private var confirmReload = false

    private func textBinding(_ id: UUID, _ key: WritableKeyPath<QuoteDraft, String>) -> Binding<String> {
        Binding(get: { editor.drafts.first { $0.id == id }?[keyPath: key] ?? "" },
                set: { value in
                    guard let index = editor.drafts.firstIndex(where: { $0.id == id }) else { return }
                    editor.drafts[index][keyPath: key] = value
                })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("我的内容").font(.title2.bold())
                Text("\(editor.drafts.count) 条").foregroundStyle(.secondary)
                Spacer()
                Button("新增一条", action: editor.addDraft).disabled(!editor.loaded)
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
                        ForEach(editor.availableTags, id: \.self) { tag in
                            Text("#\(tag)").tag(ContentEditorSession.TagFilter.tag(tag))
                        }
                        if case .tag(let tag) = editor.tagFilter, !editor.availableTags.contains(tag) {
                            Text("#\(tag)（0 条）").tag(ContentEditorSession.TagFilter.tag(tag))
                        }
                    }.padding(.horizontal, 12).accessibilityLabel("按标签筛选")
                    List(selection: $editor.selectedID) {
                        ForEach(editor.filteredDrafts) { draft in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新笔记" : draft.text)
                                    .lineLimit(2)
                                if !draft.source.isEmpty {
                                    Text(draft.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(draft.quote.tags.isEmpty ? "默认" : draft.quote.tags.map { "#\($0)" }.joined(separator: "  "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 5).tag(draft.id)
                        }
                    }.listStyle(.sidebar)
                    Text("\(editor.filteredDrafts.count) / \(editor.drafts.count) 条")
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
                                if draft.tags.isEmpty { Text("默认（无标签）").font(.caption).foregroundStyle(.secondary) }
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
                                    ForEach(editor.availableTags, id: \.self) { tag in
                                        Button(tag) { editor.addTag(tag) }.disabled(draft.quote.tags.contains(tag))
                                    }
                                }.fixedSize().disabled(editor.availableTags.isEmpty)
                            }
                        }
                        HStack {
                            Text(editor.dirty ? "先保存修改，再预览这条笔记。" : "预览只展示这条笔记，不改变随机回顾计划。")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("预览这条", action: editor.previewSelected)
                                .disabled(!editor.loaded || editor.dirty || !model.canRemind)
                        }
                    } else {
                        Spacer()
                        Text(editor.drafts.isEmpty ? "还没有笔记，点击“新增一条”开始。" : editor.filteredDrafts.isEmpty ? "没有匹配的笔记，试试其他关键词或标签。" : "从左侧选择一条笔记。")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        Spacer()
                    }
                }.padding(20).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let failure = editor.failure {
                    Text(failure).foregroundStyle(.red).font(.callout)
                } else if editor.dirty {
                    Text("有未保存的修改 · 切换笔记会保留草稿").foregroundStyle(.secondary).font(.callout)
                } else if let message = editor.message {
                    Text(message).foregroundStyle(.secondary).font(.callout)
                }
                if model.settings.isPaused {
                    Text("回顾展示已暂停，可从菜单栏或设置恢复。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("打开数据目录") { model.openDataDirectory() }
                    Text("空白不保存，同正文去重。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存并生效", action: { editor.save() })
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!editor.loaded || !editor.dirty)
                }
            }.padding(16)
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { if !editor.loaded { editor.load() } }
        .onChange(of: editor.searchText) { _, _ in editor.selectSearchResult() }
        .onChange(of: editor.tagFilter) { _, _ in editor.selectSearchResult() }
        .alert("放弃未保存的修改并重新载入？", isPresented: $confirmReload) {
            Button("取消", role: .cancel) { }
            Button("重新载入", role: .destructive) { editor.load() }
        }
    }
}
