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
        guard String(data: data, encoding: .utf8) != nil else { throw ContentError.invalidEncoding }
        let raw: [Quote]
        do { raw = try JSONDecoder().decode([Quote].self, from: data) }
        catch { throw ContentError.invalidFormat }
        var seen = Set<String>()
        return raw.compactMap { quote in
            let text = quote.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text).inserted else { return nil }
            return Quote(text: text, source: quote.source, tags: quote.tags)
        }
    }

    public enum ContentError: LocalizedError {
        public var errorDescription: String? { message }
        case invalidEncoding, invalidFormat
        var message: String {
            switch self {
            case .invalidEncoding: "quotes.json 必须是 UTF-8 文本。"
            case .invalidFormat: "quotes.json 格式错误：顶层须为数组，text 和可选 source 须为字符串，可选 tags 须为字符串数组。"
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
    public struct EditorSnapshot {
        public let quotes: [Quote]
        public let fileData: Data?
    }

    public enum SaveError: LocalizedError {
        case changedOnDisk
        public var errorDescription: String? {
            "内容文件已被其他操作修改。请重新载入后再编辑，当前草稿尚未保存。"
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
        let normalized = try Self.decode(encoder.encode(draft))
        let data = try encoder.encode(normalized)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        quotes = normalized
        errorMessage = nil
        return EditorSnapshot(quotes: normalized, fileData: data)
    }
}
