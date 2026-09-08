import SwiftUI
import AppKit

@main
struct VPNSwitchApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Syncs the bundled control scripts into the installed location
        // (~/Library/Application Support/vpn-switch) and exits -- used by
        // the install script / for scripting and diagnostics. Same sync
        // AppModel.startPolling() performs on ordinary launch
        // (dns-config-8v7.3).
        if CommandLine.arguments.contains("--sync-scripts") {
            let written = ScriptBundle.syncIfNeeded()
            if written.isEmpty {
                print("scripts up to date")
            } else {
                for path in written {
                    print(path)
                }
            }
            exit(0)
        }
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

    /// Reconcile header lines to render below Switching/Queued and above
    /// headerMessage (dns-config-l40.4 step 2). Computed fresh per render
    /// via `AppModel.reconcileHeaderLines(now:)`.
    private var reconcileHeaderLines: [String] {
        model.reconcileHeaderLines()
    }

    /// " · kept on" suffix appended to the "NordVPN: " status line
    /// (dns-config-l40.4 step 1) when Nord is in model.keptConnected and
    /// the master toggle is on; empty string otherwise (step 5).
    private var nordKeptOnSuffix: String {
        model.keepVPNsConnected && model.keptConnected.contains(.nord) ? " · kept on" : ""
    }

    /// " · kept on" suffix appended to the "Tailscale: " status line, same
    /// gating as `nordKeptOnSuffix` above.
    private var tailscaleKeptOnSuffix: String {
        model.keepVPNsConnected && model.keptConnected.contains(.tailscale) ? " · kept on" : ""
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
                }
                // Reconcile header lines (dns-config-l40.4 step 2): one per
                // model.reconcileActivity entry, Nord then Tailscale,
                // rendered below Switching/Queued and above headerMessage.
                // Empty (hidden) when keepVPNsConnected is off, per step 5.
                ForEach(reconcileHeaderLines, id: \.self) { line in
                    Text(line)
                }
                // headerMessage duplicates a reconcile line while a reconcile
                // attempt is in flight/paused (see AppModel.apply(outcome:)'s
                // currentReconcileHeaderLine() fallback) -- skip it here so
                // that line isn't shown twice.
                if !model.isSwitching, model.scriptMissingPath == nil,
                    let message = model.headerMessage,
                    !reconcileHeaderLines.contains(message) {
                    Text(message)
                }
                if let update = model.availableUpdate {
                    Text("Update available: \(update.latestVersion)")
                }
            }

            if isAppTunnelError {
                Text("⚠︎ NordVPN: \(model.status.nord.label)\(nordKeptOnSuffix)")
            } else {
                Text("NordVPN: \(model.status.nord.label)\(nordKeptOnSuffix)")
            }
            Text("Tailscale: \(model.status.ts.label)\(tailscaleKeptOnSuffix)")

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

            Group {
                Toggle("Keep VPNs connected", isOn: $model.keepVPNsConnected)
                    .help("Reconnect a VPN automatically if it drops after you turned it on here")
                Toggle("Notify on external changes", isOn: $model.notifyOnExternalChanges)
                Toggle("Check for updates automatically", isOn: $model.autoUpdateCheckEnabled)
            }

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

            Group {
                if let update = model.availableUpdate {
                    Group {
                        Button("Install Update \(update.latestVersion)…") {
                            model.installAvailableUpdate()
                        }

                        Button("Skip This Version") {
                            model.skipAvailableUpdate()
                        }
                    }
                }

                Button("Check for Updates…") {
                    model.checkForUpdates()
                }

                Button("Quit") {
                    // prepareForTermination() covers everything Quit needs
                    // to tear down cleanly (stop polling/wake observer,
                    // discard not-yet-started queued intents, and terminate
                    // any vpn-ctl.sh child already in flight so no child
                    // outlives the app under launchd) -- see AppModel for
                    // the full rationale. It's also shared with the
                    // "Check for Updates…" -> "Install and Relaunch" path
                    // (dns-config-8v7.6), which needs the exact same
                    // teardown immediately before its own irreversible
                    // termination.
                    model.prepareForTermination()
                    NSApplication.shared.terminate(nil)
                }
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
