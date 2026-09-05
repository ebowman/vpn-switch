import SwiftUI
import AppKit

@main
struct VPNSwitchApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--selftest-queue") {
            SelfTest.runQueueCasesAndExit()
        }
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
        // CLI flags for the install/uninstall scripts (dns-config-qsk.7):
        // register/unregister the login item without presenting the UI.
        if CommandLine.arguments.contains("--register-login-item") {
            if let error = LoginItem.register() {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
            print("Login item registered.")
            exit(0)
        }
        if CommandLine.arguments.contains("--unregister-login-item") {
            if let error = LoginItem.unregister() {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                exit(1)
            }
            print("Login item unregistered.")
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            // The label (menu bar icon) is rendered immediately at launch,
            // unlike MenuContentView above, which SwiftUI builds lazily and
            // only on first menu-open. Polling therefore starts here, not
            // in MenuContentView's onAppear, so the icon/header stay
            // truthful even if the user never opens the menu -- and so wake
            // handling and external-change notifications work passively.
            Group {
                if MenuIcon.isErrorState(model.status) {
                    Label("VPN Switch", systemImage: MenuIcon.symbolName(for: model.status))
                        .labelStyle(.iconOnly)
                } else {
                    Image(systemName: MenuIcon.symbolName(for: model.status))
                }
            }
            .onAppear {
                model.startPolling()
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel

    /// True when the current status is the ERROR state per dns-config-qsk.6:
    /// nord=app or nord=app+ikev2 -- the NordVPN app's own tunnel collides
    /// with Tailscale's 100.64/10 range. Rendered distinctly (⚠︎ prefix,
    /// explanation line, no auto-fix) rather than folded into the ordinary
    /// "App tunnel (unsupported)" label alone.
    private var isAppTunnelError: Bool {
        switch model.status.nord {
        case .app, .appPlusIkev2: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            Group {
                if let missing = model.scriptMissingPath {
                    Text("vpn-ctl.sh not found at \(missing)")
                } else if model.isSwitching {
                    Text("Switching: \(model.activeActionLabel ?? "…")…")
                    if !model.queuedActionLabels.isEmpty {
                        Text("Queued: " + model.queuedActionLabels.joined(separator: ", "))
                    }
                } else if let message = model.headerMessage {
                    Text(message)
                }
            }

            if isAppTunnelError {
                Text("⚠︎ NordVPN: \(model.status.nord.label)")
            } else {
                Text("NordVPN: \(model.status.nord.label)")
            }
            Text("Tailscale: \(model.status.ts.label)")

            if isAppTunnelError {
                Text("NordVPN app tunnel detected — 100.64.0.2 collides with Tailscale; disconnect the NordVPN app and use the IKEv2 profile")
            }

            if shouldShowWebFailWarning {
                Text("⚠ Internet check failed")
            }

            if model.status.ts == .needsLogin {
                Button("Open Tailscale…") {
                    model.openTailscaleApp()
                }
            }

            Divider()

            // None of the items below are ever disabled: each click records
            // an absolute intent (target state captured from the currently
            // displayed status) into AppModel's ActionQueue, which runs one
            // vpn-ctl.sh invocation at a time and coalesces duplicate/
            // opposite intents rather than relying on the UI to prevent
            // overlap. See ActionQueue.swift for the coalescing rules.
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

            Button("Turn All VPNs On") {
                model.turnAllOn()
            }

            // Always enabled, like every item above: both "Turn All" actions
            // are idempotent no-ops when nothing needs to change, so there is
            // no "nothing to turn off/on" state to disable for. This
            // deliberately supersedes the open UX question raised in
            // dns-config-5cn.
            Button("Turn All VPNs Off") {
                model.turnAllOff()
            }

            Divider()

            Button("Refresh") {
                model.refresh()
            }

            Toggle("Notify on external changes", isOn: $model.notifyOnExternalChanges)

            Divider()

            if model.loginItemEligible {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.loginItemRegistered },
                    set: { _ in model.toggleLoginItem() }
                ))
            } else {
                Text("Launch at login")
                Text("Install to /Applications first")
            }

            Divider()

            Button("Quit") {
                model.stopPolling()
                // Discard any not-yet-started queued intents so teardown
                // doesn't start a new vpn-ctl.sh process right as we're
                // quitting -- only a command already in flight (handled by
                // terminateAllInFlight below) can still be running.
                model.discardPendingActions()
                // Belt-and-braces for the case where a poll or toggle is
                // synchronously blocked inside VPNCtl.run right now (Task
                // cancellation from stopPolling cannot interrupt a blocking
                // waitpid/read loop) -- without this, quitting mid-run would
                // orphan that child (and any grandchildren) under launchd.
                VPNCtl.terminateAllInFlight()
                NSApplication.shared.terminate(nil)
            }
        }
        // Polling is started from the MenuBarExtra label's onAppear (see
        // VPNSwitchApp.body) since that view renders at launch; this
        // content view is built lazily on first menu-open and would delay
        // the first poll until the user opened the menu. startPolling() is
        // idempotent (guards on pollTask == nil), so no extra call is
        // needed here.
        //
        // This view IS rebuilt on every menu open (unlike the label above),
        // so onAppear here is the right place to re-read SMAppService's real
        // status each time the menu is opened (dns-config-qsk.7) -- reflects
        // a change made in System Settings > Login Items directly, not just
        // changes made from this app's own toggle.
        .onAppear {
            model.refreshLoginItemStatus()
        }
    }

    /// "web=fail while both toggles report up" per the reshaped spec: a
    /// warning line, not an error state (no icon change, no explanation
    /// item -- just a one-line heads-up that the internet check itself
    /// failed even though Nord and Tailscale both look connected).
    private var shouldShowWebFailWarning: Bool {
        model.status.web == "fail" && model.status.nord.isOn && model.status.ts.isOn
    }
}
