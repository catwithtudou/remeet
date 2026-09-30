import Foundation

public struct Quote: Codable, Equatable, Sendable {
    public let text: String
    public let source: String?
    public let tags: [String]

    public init(text: String, source: String? = nil, tags: [String] = []) {
        self.text = text
        self.source = source
        var seen = Set<String>()
        self.tags = tags.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(text: try container.decode(String.self, forKey: .text),
                  source: container.contains(.source) ? try container.decode(String.self, forKey: .source) : nil,
                  tags: container.contains(.tags) ? try container.decode([String].self, forKey: .tags) : [])
    }

    private enum CodingKeys: String, CodingKey { case text, source, tags }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(source, forKey: .source)
        if !tags.isEmpty { try container.encode(tags, forKey: .tags) }
    }
}
