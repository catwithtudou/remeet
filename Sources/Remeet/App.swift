import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import RemeetCore
#endif

@main
enum RemeetApp {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--reload-content" {
            guard CommandLine.arguments.count == 3 else {
                print("{\"status\":\"invalid_arguments\"}")
                return
            }
            ContentReloadBridge.request(path: CommandLine.arguments[2])
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.mainMenu = makeMainMenu()
        withExtendedLifetime(delegate) { app.run() }
    }

    @MainActor static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let application = NSMenuItem()
        application.submenu = NSMenu(title: "Remeet")
        application.submenu?.addItem(withTitle: "退出回见", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(application)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "编辑")
        // Nil targets let AppKit route shortcuts to the focused native editor.
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = menu
        main.addItem(edit)
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = RecallModel()
    private lazy var editor = ContentEditorSession(model: model)
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var contentWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = RemeetArtwork.image(size: 18, template: true)
        item.button?.toolTip = "回见 · Remeet"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item
        model.panel.onOpenSettings = { [weak self] in self?.showSettings() }
        model.start()
        #if DEBUG
        if CommandLine.arguments.contains("--preview") { model.remindCurrent() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        #endif
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add("立即回顾", action: #selector(remindCurrent), to: menu, enabled: model.canRemind)
        add("换一条回顾", action: #selector(remindNext), to: menu, enabled: model.canRemind)
        if let error = model.errorMessage {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else if model.isEmpty {
            let item = NSMenuItem(title: "暂无可用内容，请在“我的内容”中添加并保存笔记", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add("我的内容", action: #selector(showContentEditor), to: menu)
        add("打开数据目录", action: #selector(openDataDirectory), to: menu)
        add("重新加载内容", action: #selector(reload), to: menu)
        menu.addItem(.separator())
        add(model.settings.isPaused ? "恢复展示" : "暂停展示", action: #selector(togglePause), to: menu)
        add("设置", action: #selector(showSettings), to: menu)
        #if DEBUG
        add("模拟定时触发（调试）", action: #selector(simulateTick), to: menu)
        #endif
        menu.addItem(.separator())
        add("退出", action: #selector(quit), to: menu)
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc private func remindCurrent() { model.remindCurrent() }
    @objc private func remindNext() { model.remindNext() }
    @objc private func reload() { model.reload() }
    @objc private func openDataDirectory() { model.openDataDirectory() }
    @objc private func togglePause() { model.updateSettings { $0.isPaused.toggle() } }
    @objc private func quit() { NSApp.terminate(nil) }
    #if DEBUG
    @objc private func simulateTick() { model.handleScheduledEvent(.scheduled) }
    #endif

    @objc private func showSettings() {
        model.panel.collapse()
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 680),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "回见 · Remeet 设置"
            window.identifier = NSUserInterfaceItemIdentifier("settingsWindow")
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(model: model, openContentEditor: { [weak self] in self?.showContentEditor() }))
            window.center()
            settingsWindow = window
        }
        // Only an explicit request to open settings activates the app.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showContentEditor() {
        model.panel.collapse(immediately: true)
        if contentWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 720, height: 480)
            window.title = "回见 · Remeet 我的内容"
            window.identifier = NSUserInterfaceItemIdentifier("contentEditor")
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: ContentEditorView(model: model, editor: editor))
            window.center()
            contentWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        if !editor.dirty { editor.load() }
        contentWindow?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === contentWindow else { return true }
        return canLeaveEditor(quitting: false)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        canLeaveEditor(quitting: true) ? .terminateNow : .terminateCancel
    }

    private func canLeaveEditor(quitting: Bool) -> Bool {
        // Commit the current field before checking whether its text has changed.
        guard contentWindow?.makeFirstResponder(nil) != false else { return false }
        return editor.prepareToClose {
            NSApp.activate(ignoringOtherApps: true)
            contentWindow?.makeKeyAndOrderFront(nil)
            let alert = NSAlert()
            alert.messageText = "保存对笔记的修改？"
            alert.informativeText = "还有未保存的修改。保存失败时会保留草稿，方便继续处理。"
            alert.addButton(withTitle: quitting ? "保存并退出" : "保存并关闭")
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "放弃修改")
            alert.buttons[1].keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn: return .save
            case .alertThirdButtonReturn: return .discard
            default: return .cancel
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) { model.shutdown() }
}

/// Same-user local IPC. The CLI does not launch a second UI or activate a window.
@MainActor
enum ContentReloadBridge {
    // Stable pre-Remeet IPC names allow existing local integrations to reload content.
    static let requestName = Notification.Name("local.NotchRecall.reloadContent")
    static let replyName = Notification.Name("local.NotchRecall.reloadContentReply")
    @MainActor private final class Reply { var data: Data? }

    static func request(path: String) {
        let center = DistributedNotificationCenter.default()
        let identifier = UUID().uuidString
        let reply = Reply()
        let token = center.addObserver(forName: replyName, object: identifier, queue: .main) { notification in
            let data = notification.userInfo.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            MainActor.assumeIsolated { reply.data = data }
        }
        defer { center.removeObserver(token) }
        center.postNotificationName(requestName, object: URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path,
                                    userInfo: ["requestID": identifier], deliverImmediately: true)
        let deadline = Date().addingTimeInterval(2)
        while reply.data == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let fallback = ["status": "not_acknowledged", "reason": "应用未运行、版本不支持重载或数据路径不匹配；请从菜单重新加载内容。"]
        if let data = reply.data ?? (try? JSONSerialization.data(withJSONObject: fallback)),
           let text = String(data: data, encoding: .utf8) { print(text) }
    }
}
