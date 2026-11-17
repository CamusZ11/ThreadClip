import ServiceManagement
import SwiftUI
import ThreadHangerCore

struct HangerSettingsView: View {
    @ObservedObject var runtime: HangerRuntime
    let allowsLoginItem: Bool

    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var loginError: String?

    var body: some View {
        Form {
            Toggle("监控 Codex", isOn: Binding(
                get: { runtime.preferences.isMonitoring },
                set: runtime.setMonitoring
            ))
            Toggle("暂停自动弹出", isOn: Binding(
                get: { runtime.preferences.isPaused },
                set: runtime.setPaused
            ))
            Stepper(value: Binding(
                get: { runtime.preferences.highlightSeconds },
                set: runtime.setHighlightSeconds
            ), in: 1...30) {
                Text("高亮时长（\(runtime.preferences.highlightSeconds.formatted()) 秒）")
            }
            Stepper(value: Binding(
                get: { runtime.preferences.recentThreadCount },
                set: runtime.setRecentThreadCount
            ), in: 0...HangerPreferences.maximumRecentThreadCount) {
                Text("最近对话数量（\(runtime.preferences.recentThreadCount)）")
            }
            if allowsLoginItem {
                Toggle("登录时启动", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                if let loginError {
                    Text(loginError)
                        .foregroundStyle(.red)
                } else if loginStatus == .requiresApproval {
                    Button("在系统设置中批准登录项") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if !runtime.diagnostic.isEmpty {
                LabeledContent("监控状态") {
                    Text(runtime.diagnostic)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 410, idealWidth: 460, minHeight: 280, idealHeight: 335)
        .onAppear {
            if allowsLoginItem { loginStatus = SMAppService.mainApp.status }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}
