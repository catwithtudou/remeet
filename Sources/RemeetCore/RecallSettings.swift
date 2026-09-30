import Foundation

public enum RecallFrequency: Int, CaseIterable, Sendable {
    case halfHour = 30, hourly = 60, twoHours = 120, custom = 0
    public var label: String {
        switch self {
        case .custom: "自定义"
        case .halfHour: "每 30 分钟"
        case .hourly: "每小时"
        case .twoHours: "每 2 小时"
        }
    }
}

public struct RecallSettings: Equatable, Sendable {
    public var autoPresent = true
    public var hoverPresent = true
    public var showIndicator = true
    public var readingSeconds = 10
    public var frequency = RecallFrequency.hourly
    public var customIntervalMinutes = 45
    public var screen = "auto"
    public var isPaused = false
    public var fontSize = 16
    public var panelWidth = 420
    public var maxTextHeight = 240
    public static let fontSizeRange = 12...24
    public static let panelWidthRange = 336...840
    public static let textHeightRange = 120...480
    public static let customIntervalRange = 1...1440
    public static let readingSecondsRange = 1...3600
    public static let readingOptions = [5, 10, 20, 30]
    public init() {}
}

public struct PreferenceStore {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> RecallSettings {
        var settings = RecallSettings()
        settings.autoPresent = defaults.object(forKey: "autoPresent") as? Bool ?? settings.autoPresent
        settings.hoverPresent = defaults.object(forKey: "hoverPresent") as? Bool ?? settings.hoverPresent
        settings.showIndicator = defaults.object(forKey: "showIndicator") as? Bool ?? settings.showIndicator
        settings.isPaused = defaults.bool(forKey: "isPaused")
        let duration = defaults.integer(forKey: "readingSeconds")
        settings.readingSeconds = RecallSettings.readingSecondsRange.contains(duration) ? duration : settings.readingSeconds
        settings.frequency = (defaults.object(forKey: "frequencyMinutes") as? Int)
            .flatMap(RecallFrequency.init(rawValue:)) ?? settings.frequency
        let interval = defaults.integer(forKey: "customIntervalMinutes")
        settings.customIntervalMinutes = RecallSettings.customIntervalRange.contains(interval) ? interval : settings.customIntervalMinutes
        let fontSize = defaults.integer(forKey: "fontSize")
        settings.fontSize = RecallSettings.fontSizeRange.contains(fontSize) ? fontSize : settings.fontSize
        let panelWidth = defaults.integer(forKey: "panelWidth")
        settings.panelWidth = RecallSettings.panelWidthRange.contains(panelWidth) ? panelWidth : settings.panelWidth
        let maxTextHeight = defaults.integer(forKey: "maxTextHeight")
        settings.maxTextHeight = RecallSettings.textHeightRange.contains(maxTextHeight) ? maxTextHeight : settings.maxTextHeight
        settings.screen = defaults.string(forKey: "screen") ?? settings.screen
        return settings
    }

    public func save(_ settings: RecallSettings) {
        defaults.set(settings.autoPresent, forKey: "autoPresent")
        defaults.set(settings.hoverPresent, forKey: "hoverPresent")
        defaults.set(settings.showIndicator, forKey: "showIndicator")
        defaults.set(settings.isPaused, forKey: "isPaused")
        defaults.set(settings.readingSeconds, forKey: "readingSeconds")
        defaults.set(settings.frequency.rawValue, forKey: "frequencyMinutes")
        defaults.set(settings.customIntervalMinutes, forKey: "customIntervalMinutes")
        defaults.set(settings.fontSize, forKey: "fontSize")
        defaults.set(settings.panelWidth, forKey: "panelWidth")
        defaults.set(settings.maxTextHeight, forKey: "maxTextHeight")
        defaults.set(settings.screen, forKey: "screen")
    }
}
