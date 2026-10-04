import Foundation

public final class QuoteStore {
    public let fileURL: URL
    public private(set) var quotes: [Quote] = []
    public private(set) var errorMessage: String?

    public init(fileURL: URL) { self.fileURL = fileURL }

    /// Called only at startup. Reload never recreates a deleted user file.
    public func initializeIfMissing(sample: Data) throws {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: fileURL.path) else { return }
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sample.write(to: fileURL, options: .withoutOverwriting)
    }

    @discardableResult
    public func reload() -> Bool {
        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try Self.decode(data)
            quotes = loaded
            errorMessage = nil
            return true
        } catch let error as ContentError {
            errorMessage = error.message
        } catch {
            errorMessage = "无法读取 quotes.json，请检查文件是否存在及是否可读。"
        }
        return false
    }

    public static func decode(_ data: Data) throws -> [Quote] {
        normalize(try decodeRaw(data)).quotes
    }

    private static func decodeRaw(_ data: Data) throws -> [Quote] {
        guard String(data: data, encoding: .utf8) != nil else { throw ContentError.invalidEncoding }
        let raw: [Quote]
        do { raw = try JSONDecoder().decode([Quote].self, from: data) }
        catch { throw ContentError.invalidFormat }
        return raw
    }

    public struct ImportPreview {
        public enum Disposition: String { case added = "新增", duplicate = "重复，跳过", blank = "空白，跳过" }
        public struct Entry {
            public let quote: Quote
            public let disposition: Disposition
        }
        public let entries: [Entry]
        public let merged: [Quote]
        public var addedCount: Int { entries.filter { $0.disposition == .added }.count }
        public var duplicateCount: Int { entries.filter { $0.disposition == .duplicate }.count }
        public var blankCount: Int { entries.filter { $0.disposition == .blank }.count }
    }

    /// Use the same normalization as saving; existing entries win over incoming metadata.
    public static func previewImport(_ data: Data, existing: [Quote]) throws -> ImportPreview {
        let incoming = try decodeRaw(data)
        let result = normalize(existing + incoming)
        let discarded = Set(result.discardedIndices)
        let entries = incoming.enumerated().map { index, quote in
            let blank = quote.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return ImportPreview.Entry(quote: quote, disposition: blank ? .blank
                : discarded.contains(existing.count + index) ? .duplicate : .added)
        }
        return ImportPreview(entries: entries, merged: result.quotes)
    }

    /// Shared by file loading, saving and the editor's pre-save warning.
    public static func normalize(_ raw: [Quote]) -> (quotes: [Quote], discardedIndices: [Int]) {
        var seen = Set<String>()
        var quotes: [Quote] = []
        var discarded: [Int] = []
        for (index, quote) in raw.enumerated() {
            let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else {
                discarded.append(index)
                continue
            }
            quotes.append(Quote(text: text, source: quote.source, tags: quote.tags))
        }
        return (quotes, discarded)
    }

    public enum ContentError: LocalizedError {
        public var errorDescription: String? { message }
        case invalidEncoding, invalidFormat
        var message: String {
            switch self {
            case .invalidEncoding: "内容 JSON 必须是 UTF-8 文本。"
            case .invalidFormat: "内容 JSON 格式错误：顶层须为数组，text 和可选 source 须为字符串，可选 tags 须为字符串数组。"
            }
        }
    }
}

public struct QuoteSelection {
    public private(set) var current: Quote?
    private let randomIndex: (Range<Int>) -> Int

    public init(randomIndex: @escaping (Range<Int>) -> Int = { Int.random(in: $0) }) {
        self.randomIndex = randomIndex
    }

    public mutating func reconcile(with quotes: [Quote]) {
        if let retained = quotes.first(where: { $0.text == current?.text }) {
            current = retained
        } else { selectNext(from: quotes) }
    }

    public mutating func selectNext(from quotes: [Quote]) {
        let candidates = quotes.count > 1 ? quotes.filter { $0.text != current?.text } : quotes
        guard !candidates.isEmpty else { current = nil; return }
        current = candidates[randomIndex(candidates.indices)]
    }
}

extension QuoteStore {
    public struct Backup: Identifiable {
        public let url: URL
        public let date: Date
        public var id: URL { url }
    }

    private var backupDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("editor-backups", isDirectory: true)
    }

    public func backups() throws -> [Backup] {
        guard FileManager.default.fileExists(atPath: backupDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix("quotes-") && $0.pathExtension == "json" }
            .compactMap { url in
                let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true, let date = values.contentModificationDate else { return nil }
                return Backup(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    private func backUp(_ data: Data) throws {
        do {
            try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            let url = backupDirectory.appendingPathComponent("quotes-\(UUID().uuidString).json")
            try data.write(to: url, options: .withoutOverwriting)
            // Keep the new backup even if the system clock has moved backwards.
            for backup in try backups().filter({ $0.url.lastPathComponent != url.lastPathComponent }).dropFirst(9) {
                try FileManager.default.removeItem(at: backup.url)
            }
        } catch { throw SaveError.backupFailed }
    }

    public struct EditorSnapshot {
        public let quotes: [Quote]
        public let fileData: Data?
    }

    public enum SaveError: LocalizedError {
        case changedOnDisk, backupFailed
        public var errorDescription: String? {
            switch self {
            case .changedOnDisk:
                "内容文件已被其他操作修改，当前草稿尚未保存。可先导出草稿，再重新载入后继续编辑。"
            case .backupFailed:
                "无法创建或整理保存前备份，内容文件未写入。请检查数据目录是否可写，当前草稿尚未保存。"
            }
        }
    }

    public func editorSnapshot() throws -> EditorSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return EditorSnapshot(quotes: [], fileData: nil)
        }
        let data = try Data(contentsOf: fileURL)
        return EditorSnapshot(quotes: try Self.decode(data), fileData: data)
    }

    /// Keep the editor draft on failure; update the live pool only after the atomic write succeeds.
    @discardableResult
    public func save(_ draft: [Quote], expectedFileData: Data?) throws -> EditorSnapshot {
        let current = FileManager.default.fileExists(atPath: fileURL.path)
            ? try Data(contentsOf: fileURL) : nil
        guard current == expectedFileData else { throw SaveError.changedOnDisk }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let normalized = Self.normalize(draft).quotes
        let data = try encoder.encode(normalized)
        if let current, current != data { try backUp(current) }
        let latest = FileManager.default.fileExists(atPath: fileURL.path)
            ? try Data(contentsOf: fileURL) : nil
        guard latest == expectedFileData else { throw SaveError.changedOnDisk }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        quotes = normalized
        errorMessage = nil
        return EditorSnapshot(quotes: normalized, fileData: data)
    }
}
