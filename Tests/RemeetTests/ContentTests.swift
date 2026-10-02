import Foundation
import Testing
@testable import RemeetCore

@Test func contentNormalizationAndSourceRetention() throws {
    let input = #"[{"text":" 你好 🌱 \n","source":"第一条"},{"text":"你好 🌱","source":"第二条"},{"text":"  "},{"text":"另一段\n内容"}]"#
    let result = try QuoteStore.decode(Data(input.utf8))
    #expect(result == [Quote(text: "你好 🌱", source: "第一条"), Quote(text: "另一段\n内容")])
}

@Test(arguments: [#"{}"#, #"[{"text":1}]"#, #"[{"source":"缺少正文"}]"#,
                  #"[{"text":"有效"},{"text":"下一条","source":null}]"#,
                  #"[{"text":"有效","tags":null}]"#, #"[{"text":"有效","tags":"工作"}]"#,
                  #"[{"text":"有效","tags":["工作",1]}]"#, "["])
func rejectsEntireInvalidFile(input: String) {
    #expect(throws: (any Error).self) { try QuoteStore.decode(Data(input.utf8)) }
}

@Test func optionalTagsNormalizeAndSurviveStoreRoundTrip() throws {
    let input = #"[{"text":"旧格式"},{"text":" 新格式 ","source":"来源","tags":[" 工作 ","","工作","阅读 🌱"]},{"text":"新格式","tags":["重复条目"]},{"text":"空标签","tags":[]}]"#
    let quotes = try QuoteStore.decode(Data(input.utf8))
    #expect(quotes == [Quote(text: "旧格式"), Quote(text: "新格式", source: "来源", tags: ["工作", "阅读 🌱"]), Quote(text: "空标签")])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = QuoteStore(fileURL: directory.appendingPathComponent("quotes.json"))
    let saved = try store.save(quotes, expectedFileData: nil)
    #expect(saved.quotes == quotes)
    #expect(store.reload())
    #expect(store.quotes == quotes)
    let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [[String: Any]])
    #expect(rows[0]["tags"] == nil)
    #expect(rows[1]["tags"] as? [String] == ["工作", "阅读 🌱"])
    #expect(rows[2]["tags"] == nil)
}

@Test func reloadFailurePreservesDataButValidEmptyReplacesIt() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = QuoteStore(fileURL: dir.appendingPathComponent("quotes.json"))
    try store.initializeIfMissing(sample: Data(#"[{"text":"旧内容"}]"#.utf8))
    #expect(store.reload())
    try Data("bad json".utf8).write(to: store.fileURL)
    #expect(!store.reload())
    #expect(store.quotes == [Quote(text: "旧内容")])
    #expect(store.errorMessage != nil)
    try Data("[]".utf8).write(to: store.fileURL)
    #expect(store.reload())
    #expect(store.quotes.isEmpty)
    #expect(store.errorMessage == nil)
    try Data(#"[{"text":"修复"}]"#.utf8).write(to: store.fileURL)
    #expect(store.reload())
    #expect(store.quotes == [Quote(text: "修复")])
    try FileManager.default.removeItem(at: store.fileURL)
    #expect(!store.reload())
    #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    #expect(store.quotes == [Quote(text: "修复")])
}

@Test func initializationNeverOverwritesExistingFile() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = QuoteStore(fileURL: dir.appendingPathComponent("quotes.json"))
    let original = Data(#"[{"text":"用户内容"}]"#.utf8)
    try store.initializeIfMissing(sample: original)
    try store.initializeIfMissing(sample: Data("[]".utf8))
    #expect(try Data(contentsOf: store.fileURL) == original)
}

@Test func selectionAvoidsImmediateRepeatAndRefreshesSource() {
    var selection = QuoteSelection(randomIndex: { $0.lowerBound })
    let quotes = [Quote(text: "A", source: "旧来源"), Quote(text: "B"), Quote(text: "C")]
    selection.reconcile(with: quotes)
    #expect(selection.current?.text == "A")
    selection.reconcile(with: [Quote(text: "A", source: "新来源"), Quote(text: "B")])
    #expect(selection.current?.source == "新来源")
    selection.selectNext(from: quotes)
    #expect(selection.current?.text == "B")
    selection.selectNext(from: quotes)
    #expect(selection.current?.text == "A")
    selection.reconcile(with: [Quote(text: "只有一条")])
    selection.selectNext(from: [Quote(text: "只有一条")])
    #expect(selection.current?.text == "只有一条")
    selection.reconcile(with: [])
    #expect(selection.current == nil)
}

@Test func preferencesPersistAndInvalidValuesFallBack() throws {
    let suite = "Remeet.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = PreferenceStore(defaults: defaults)
    #expect(store.load() == RecallSettings())
    var settings = RecallSettings()
    settings.autoPresent = false
    settings.hoverPresent = false
    settings.showIndicator = false
    settings.isPaused = true
    settings.readingSeconds = 30
    settings.frequency = .halfHour
    settings.screen = "chosen-screen-uuid"
    settings.fontSize = 22
    settings.panelWidth = 620
    settings.maxTextHeight = 400
    store.save(settings)
    #expect(PreferenceStore(defaults: defaults).load() == settings)
    // Slider positions between the former presets must survive relaunch.
    settings.fontSize = 17
    settings.panelWidth = 537
    settings.maxTextHeight = 289
    store.save(settings)
    #expect(PreferenceStore(defaults: defaults).load() == settings)
    settings.frequency = .custom
    settings.customIntervalMinutes = 137
    settings.readingSeconds = 47
    store.save(settings)
    #expect(PreferenceStore(defaults: defaults).load() == settings)
    defaults.set(0, forKey: "customIntervalMinutes")
    #expect(store.load().customIntervalMinutes == RecallSettings().customIntervalMinutes)
    defaults.set(-1, forKey: "readingSeconds")
    defaults.set(17, forKey: "frequencyMinutes")
    #expect(store.load().readingSeconds == 10)
    #expect(store.load().frequency == .hourly)
    #expect(store.load().isPaused)
    defaults.set(99, forKey: "fontSize")
    defaults.set(-1, forKey: "panelWidth")
    defaults.set(0, forKey: "maxTextHeight")
    #expect(store.load().fontSize == 16)
    #expect(store.load().panelWidth == 420)
    #expect(store.load().maxTextHeight == 240)
}

@Test func editorSavesNormalizedContentAndPreservesExternalChanges() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = QuoteStore(fileURL: dir.appendingPathComponent("quotes.json"))
    let initial = try store.editorSnapshot()
    #expect(initial.quotes.isEmpty)
    let saved = try store.save([Quote(text: " 我的提醒\n", source: "自己"),
                                Quote(text: "我的提醒"), Quote(text: " ")], expectedFileData: initial.fileData)
    #expect(saved.quotes == [Quote(text: "我的提醒", source: "自己")])
    let reopened = QuoteStore(fileURL: store.fileURL)
    #expect(reopened.reload())
    #expect(reopened.quotes == saved.quotes)
    let external = Data(#"[{"text":"外部编辑"}]"#.utf8)
    try external.write(to: store.fileURL)
    #expect(throws: QuoteStore.SaveError.self) {
        try store.save([Quote(text: "过期草稿")], expectedFileData: saved.fileData)
    }
    #expect(try Data(contentsOf: store.fileURL) == external)
    #expect(store.quotes == saved.quotes)
    let refreshed = try store.editorSnapshot()
    let cleared = try store.save([], expectedFileData: refreshed.fileData)
    #expect(cleared.quotes.isEmpty)
    #expect(reopened.reload())
    #expect(reopened.quotes.isEmpty)
}

@Test func editorReadOrWriteFailureNeverClearsLiveContent() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = QuoteStore(fileURL: dir.appendingPathComponent("quotes.json"))
    let snapshot = try store.save([Quote(text: "保留")], expectedFileData: nil)
    try FileManager.default.removeItem(at: store.fileURL)
    try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: false)
    #expect(throws: (any Error).self) { try store.save([], expectedFileData: snapshot.fileData) }
    #expect(store.quotes == snapshot.quotes)
    #expect(throws: (any Error).self) { try store.editorSnapshot() }
}

@Test func editorBackupsPreserveOriginalBytesAndKeepTenWithoutTouchingImports() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = QuoteStore(fileURL: directory.appendingPathComponent("quotes.json"))
    #expect(try store.backups().isEmpty)
    var snapshot = try store.save([Quote(text: "0", source: "来源", tags: ["阅读"])], expectedFileData: nil)
    #expect(try store.backups().isEmpty)
    let original = try #require(snapshot.fileData)
    let imports = directory.appendingPathComponent("import-backups", isDirectory: true)
    try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
    let imported = imports.appendingPathComponent("quotes-import.json")
    try original.write(to: imported)
    snapshot = try store.save([Quote(text: "1")], expectedFileData: snapshot.fileData)
    let first = try #require(store.backups().first)
    #expect(try Data(contentsOf: first.url) == original)
    #expect(try QuoteStore.decode(Data(contentsOf: first.url)) == [Quote(text: "0", source: "来源", tags: ["阅读"])])
    _ = try store.save(snapshot.quotes, expectedFileData: snapshot.fileData)
    #expect(try store.backups().count == 1)
    for index in 2...14 {
        snapshot = try store.save([Quote(text: String(index))], expectedFileData: snapshot.fileData)
    }
    let backups = try store.backups()
    #expect(backups.count == 10)
    let texts = try backups.flatMap { try QuoteStore.decode(Data(contentsOf: $0.url)).map(\.text) }
    #expect(Set(texts) == Set((4...13).map(String.init)))
    #expect(try Data(contentsOf: imported) == original)
    #expect(try store.editorSnapshot().quotes == [Quote(text: "14")])
}

@Test func failedBackupAndSaveConflictLeaveDiskAndLivePoolIntact() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = QuoteStore(fileURL: directory.appendingPathComponent("quotes.json"))
    let snapshot = try store.save([Quote(text: "保留")], expectedFileData: nil)
    // A file at the backup-directory path reliably simulates failure even when running as root.
    try Data("blocked".utf8).write(to: directory.appendingPathComponent("editor-backups"))
    #expect(throws: QuoteStore.SaveError.backupFailed) {
        try store.save([], expectedFileData: snapshot.fileData)
    }
    #expect(try Data(contentsOf: store.fileURL) == snapshot.fileData)
    #expect(store.quotes == snapshot.quotes)
    let external = Data(#"[{"text":"外部修改"}]"#.utf8)
    try external.write(to: store.fileURL)
    #expect(throws: QuoteStore.SaveError.changedOnDisk) {
        try store.save([], expectedFileData: snapshot.fileData)
    }
    #expect(try Data(contentsOf: store.fileURL) == external)
    #expect(store.quotes == snapshot.quotes)
}
