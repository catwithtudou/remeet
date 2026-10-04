import Combine
import ServiceManagement

@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?
    private let readStatus: () -> SMAppService.Status
    private let updateRegistration: (Bool) throws -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         updateRegistration: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         }) {
        self.readStatus = readStatus
        self.updateRegistration = updateRegistration
        status = readStatus()
    }

    var isEnabled: Bool { status == .enabled }

    var explanation: String {
        switch status {
        case .enabled: "下次登录时启动；启动后保持收起，并保留暂停状态。"
        case .notRegistered: "开启后，登录 Mac 时自动启动回见；暂停状态仍会保留。"
        case .requiresApproval: "尚未启用。请在系统设置的登录项中允许回见。"
        case .notFound: "尚未找到登录项，可尝试开启。"
        @unknown default: "无法确认系统登录项状态，请在系统设置中检查。"
        }
    }

    func refresh() {
        let latest = readStatus()
        if status != latest { errorMessage = nil }
        status = latest
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        errorMessage = nil
        // A system-disabled item needs user approval, not another registration attempt.
        if enabled && (status == .enabled || status == .requiresApproval) { return }
        if !enabled && status == .notRegistered { return }
        do { try updateRegistration(enabled) }
        catch { errorMessage = "无法\(enabled ? "开启" : "关闭")登录时启动：\(error.localizedDescription)" }
        status = readStatus()
    }
}
