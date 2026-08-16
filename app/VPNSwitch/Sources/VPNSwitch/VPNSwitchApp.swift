import SwiftUI
import AppKit

@main
struct VPNSwitchApp: App {
    @StateObject private var model = AppModel()

    init() {
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
            if let missing = model.scriptMissingPath {
                Text("vpn-ctl.sh not found at \(missing)")
            } else if model.isSwitching {
                Text("Switching…")
            } else if let message = model.headerMessage {
                Text(message)
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

            // AX NOTE (dns-config-qsk.6 fold-in from qsk.5 review): these two
            // toggle Buttons carry `.disabled(model.isSwitching)`, which is
            // the real, authoritative guard -- runToggle() in AppModel also
            // independently refuses to start a second toggle while one is
            // in flight (`guard !isSwitching else { return }`), so a click
            // that slips past the disabled UI state cannot cause overlapping
            // vpn-ctl.sh invocations either way.
            //
            // Whether System Events ("enabled of menu item") reliably
            // observes this disabled state during the in-flight window was
            // spot-checked live (dns-config-qsk.6 verification) by toggling
            // Tailscale and re-sampling `enabled of menu item "Tailscale"`
            // via AppleScript immediately after the click. In practice a
            // real vpn-ctl.sh tailscale toggle (esp. turning an
            // already-authenticated Tailscale back on) can complete in well
            // under a second -- faster than a second osascript round-trip
            // takes to reopen the menu and re-read it -- so the sample
            // consistently landed after isSwitching had already cleared and
            // read back `true` (enabled) both times. This is inconclusive
            // for the disabled window specifically, not a negative result:
            // it does not demonstrate that AX fails to expose the disabled
            // state, only that this particular black-box probe couldn't
            // outrace a fast toggle to observe it. Documented here as a
            // known limitation per the review's guidance rather than
            // claimed as verified; the header's "Switching…" line plus the
            // two independent code guards above are what this app actually
            // relies on for correctness.
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
