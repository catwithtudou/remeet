import AppKit
import ServiceManagement
import SwiftUI
#if SWIFT_PACKAGE
import RemeetCore
#endif

struct SettingsView: View {
    @ObservedObject var model: RecallModel
    @ObservedObject var updater: UpdateController
    var openContentEditor: () -> Void
    @StateObject private var loginItem = LoginItemController()
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
            Section("启动") {
                Toggle("登录时启动", isOn: Binding(get: { loginItem.isEnabled },
                    set: { value in loginItem.setEnabled(value) }))
                    .disabled(loginItem.status == .requiresApproval)
                Text(loginItem.explanation).font(.caption).foregroundStyle(.secondary)
                if let error = loginItem.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                if loginItem.status == .requiresApproval || loginItem.status == .notFound || loginItem.errorMessage != nil {
                    Button("打开系统登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            UpdateSettingsView(updater: updater)
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
            loginItem.refresh()
            frequencyChoice = model.settings.frequency
            intervalText = intervalString(Double(model.settings.customIntervalMinutes))
            readingText = String(model.settings.readingSeconds)
            customReading = !RecallSettings.readingOptions.contains(model.settings.readingSeconds)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItem.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            loginItem.refresh()
        }
        .onChange(of: intervalUnit) { old, _ in
            let minutes = Double(intervalText).flatMap { $0.isFinite ? $0 * Double(old) : nil }
            intervalText = intervalString(minutes.flatMap { $0.isFinite ? $0 : nil } ?? Double(model.settings.customIntervalMinutes))
        }
    }
}
