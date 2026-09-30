import AppKit
import Combine
#if SWIFT_PACKAGE
import RemeetCore
#endif

@MainActor
final class RecallModel: ObservableObject {
    let panel = NotchPanelController()
    let store: QuoteStore
    private let preferences: PreferenceStore
    private var selection = QuoteSelection()
    private var activity = ActivityGate()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var startupIssue: String?
    @Published private(set) var settings: RecallSettings
    private(set) var screens: [(id: String, name: String)] = []
    @Published private(set) var nextRecallDate: Date?
    private lazy var scheduler = RecallScheduler(frequency: settings.frequency,
        customMinutes: settings.customIntervalMinutes,
        onNextDate: { [weak self] in self?.nextRecallDate = $0 }) { [weak self] event in
        self?.handleScheduledEvent(event)
    }

    var isEmpty: Bool { store.quotes.isEmpty }
    var errorMessage: String? { startupIssue ?? store.errorMessage }
    var canRemind: Bool { !settings.isPaused && activity.isActive && !isEmpty }
    #if DEBUG
    var currentQuote: Quote? { selection.current }
    #endif

    init(dataDirectory: URL? = nil, userDefaults: UserDefaults? = nil) {
        // Keep the pre-Remeet data directory so upgrades reuse saved notes and backups.
        var directory = dataDirectory ?? URL.applicationSupportDirectory.appending(path: "NotchRecall", directoryHint: .isDirectory)
        var defaults = userDefaults ?? UserDefaults.standard
        #if DEBUG
        // Isolated native smoke runs never need to touch a user's content or preferences.
        if dataDirectory == nil, let override = ProcessInfo.processInfo.environment["REMEET_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        }
        if userDefaults == nil, let suite = ProcessInfo.processInfo.environment["REMEET_DEFAULTS_SUITE"],
           let isolated = UserDefaults(suiteName: suite) { defaults = isolated }
        #endif
        store = QuoteStore(fileURL: directory.appendingPathComponent("quotes.json"))
        preferences = PreferenceStore(defaults: defaults)
        settings = preferences.load()
    }

    func start() {
        if !FileManager.default.fileExists(atPath: store.fileURL.path) {
            do {
                if let url = Bundle.main.url(forResource: "quotes.example", withExtension: "json") {
                    try store.initializeIfMissing(sample: Data(contentsOf: url))
                } else {
                    startupIssue = "未找到随附示例。请运行完整 Remeet.app，或在数据目录创建 quotes.json。"
                }
            } catch { startupIssue = "无法初始化数据文件，请检查数据目录权限。" }
        }
        panel.onNext = { [weak self] in self?.remindNext() }
        refreshScreens()
        installObservers()
        reload()
        scheduler.start()
    }

    func reload() {
        objectWillChange.send()
        if store.reload() {
            startupIssue = nil
            selection.reconcile(with: store.quotes)
        }
        syncPanel()
    }

    func saveContent(_ quotes: [Quote], expectedFileData: Data?) throws -> QuoteStore.EditorSnapshot {
        let snapshot = try store.save(quotes, expectedFileData: expectedFileData)
        objectWillChange.send()
        startupIssue = nil
        selection.reconcile(with: store.quotes)
        syncPanel()
        return snapshot
    }

    func remindCurrent() {
        guard canRemind else { return }
        objectWillChange.send()
        if selection.current == nil { selection.reconcile(with: store.quotes) }
        syncPanel()
        panel.present(duration: Double(settings.readingSeconds))
    }

    func preview(_ quote: Quote) {
        guard canRemind, store.quotes.contains(quote) else { return }
        syncPanel()
        panel.preview(quote, duration: Double(settings.readingSeconds))
    }

    func remindNext() {
        guard canRemind else { return }
        objectWillChange.send()
        selection.selectNext(from: store.quotes)
        syncPanel()
        panel.present(duration: Double(settings.readingSeconds))
    }

    func handleScheduledEvent(_ event: RecallScheduler.Event) {
        guard activity.isActive else { return }
        objectWillChange.send()
        let wasPresented = panel.isPresented
        selection.selectNext(from: store.quotes)
        if event == .recovered { panel.collapse(immediately: true) }
        syncPanel()
        if event == .scheduled, canRemind, settings.autoPresent || wasPresented {
            panel.present(duration: Double(settings.readingSeconds))
        }
    }

    func updateSettings(_ update: (inout RecallSettings) -> Void) {
        let old = settings
        update(&settings)
        preferences.save(settings)
        if old.frequency != settings.frequency || (settings.frequency == .custom && old.customIntervalMinutes != settings.customIntervalMinutes) {
            scheduler.changeFrequency(settings.frequency, customMinutes: settings.customIntervalMinutes)
        }
        syncPanel()
    }

    func openDataDirectory() {
        do {
            let directory = store.fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(directory)
        } catch {
            objectWillChange.send()
            startupIssue = "无法打开数据目录，请检查目录权限。"
        }
    }

    private func syncPanel() {
        panel.configure(quote: selection.current, active: activity.isActive && !settings.isPaused,
                        hoverEnabled: settings.hoverPresent, showIndicator: settings.showIndicator, screen: settings.screen,
                        fontSize: settings.fontSize, panelWidth: settings.panelWidth, maxTextHeight: settings.maxTextHeight)
    }

    private func refreshScreens() {
        objectWillChange.send()
        screens = NSScreen.screens.map { ($0.stableID, $0.localizedName) }
        panel.relocate()
    }

    private func changeActivity(_ reason: ActivityGate.Reason, inactive: Bool) {
        objectWillChange.send()
        let wasActive = activity.isActive
        activity.set(reason, inactive: inactive)
        guard wasActive != activity.isActive else { return }
        if activity.isActive {
            panel.relocate()
            scheduler.resumeOrRealign()
        } else { scheduler.suspend() }
        syncPanel()
    }

    private func realignTime() {
        panel.collapse(immediately: true)
        if activity.isActive { scheduler.resumeOrRealign() }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         perform: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { perform() }
        }
        observers.append((center, token))
    }

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Notification.Name, ActivityGate.Reason)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .screenSleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .inactiveSession)
        ]
        for (off, on, reason) in pairs {
            observe(workspace, off) { [weak self] in self?.changeActivity(reason, inactive: true) }
            observe(workspace, on) { [weak self] in self?.changeActivity(reason, inactive: false) }
        }
        // Supplemental distributed notifications. These names are not a documented
        // Apple contract; public workspace sleep/session notifications remain in use.
        let distributed = DistributedNotificationCenter.default()
        let reloadToken = distributed.addObserver(forName: ContentReloadBridge.requestName,
            object: store.fileURL.standardizedFileURL.resolvingSymlinksInPath().path, queue: .main) { [weak self] notification in
            guard let requestID = notification.userInfo?["requestID"] as? String else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reload()
                var response: [String: Any] = ["status": self.errorMessage == nil ? "reloaded" : "reload_failed",
                                               "count": self.store.quotes.count,
                                               "target": self.store.fileURL.standardizedFileURL.resolvingSymlinksInPath().path]
                if let error = self.errorMessage { response["reason"] = error }
                distributed.postNotificationName(ContentReloadBridge.replyName, object: requestID,
                                                 userInfo: response, deliverImmediately: true)
            }
        }
        observers.append((distributed, reloadToken))
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in
            self?.changeActivity(.locked, inactive: true)
        }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in
            self?.changeActivity(.locked, inactive: false)
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.refreshScreens() }
        observe(.default, .NSSystemClockDidChange) { [weak self] in self?.realignTime() }
        observe(.default, .NSSystemTimeZoneDidChange) { [weak self] in self?.realignTime() }
    }

    func shutdown() {
        scheduler.stop()
        panel.shutdown()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
    }
}
