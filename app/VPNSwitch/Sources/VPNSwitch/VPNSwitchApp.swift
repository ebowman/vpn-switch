import SwiftUI

@main
struct VPNSwitchApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: MenuIcon.symbolName(for: model.status))
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let missing = model.scriptMissingPath {
                Text("vpn-ctl.sh not found at \(missing)")
            } else if model.isSwitching {
                Text("Switching…")
            } else if let message = model.headerMessage {
                Text(message)
            }

            Text("NordVPN: \(model.status.nord.label)")
            Text("Tailscale: \(model.status.ts.label)")

            Divider()

            Button {
                model.toggleNord()
            } label: {
                HStack {
                    if model.status.nord.isOn {
                        Image(systemName: "checkmark")
                    }
                    Text("NordVPN")
                }
            }
            .disabled(model.isSwitching)

            Button {
                model.toggleTailscale()
            } label: {
                HStack {
                    if model.status.ts.isOn {
                        Image(systemName: "checkmark")
                    }
                    Text("Tailscale")
                }
            }
            .disabled(model.isSwitching)

            Divider()

            Button("Refresh") {
                model.refresh()
            }
            .disabled(model.isSwitching)

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            if model.status == VPNStatus() {
                model.refresh()
            }
        }
    }
}
