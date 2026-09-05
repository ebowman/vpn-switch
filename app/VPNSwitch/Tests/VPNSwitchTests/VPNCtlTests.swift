import Testing
import Foundation
@testable import VPNSwitch

/// Covers VPNCtl.childEnvironment, the pure allowlist function that decides
/// what environment a vpn-ctl.sh child process is spawned with
/// (dns-config-ci5).
struct VPNCtlTests {

    @Test func childEnvironmentAllowlistsOnlyExpectedKeys() {
        let parent: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "HOME": "/Users/tester",
            "USER": "tester",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
            "TS_CTL_BIN": "/tmp/evil-tailscale",
            "FOO": "bar",
        ]

        let result = VPNCtl.childEnvironment(from: parent)

        #expect(result == [
            "PATH": VPNCtl.childPATH,
            "HOME": "/Users/tester",
            "USER": "tester",
        ])
    }

    @Test func childEnvironmentOmitsHomeWhenParentHasNone() {
        let parent: [String: String] = [
            "PATH": "/opt/homebrew/bin",
            "USER": "tester",
        ]

        let result = VPNCtl.childEnvironment(from: parent)

        #expect(result["HOME"] == nil)
        #expect(result["USER"] == "tester")
        #expect(result["PATH"] == VPNCtl.childPATH)
    }

    @Test func childPATHExcludesHomebrewAndStartsWithUsrBin() {
        #expect(!VPNCtl.childPATH.contains("/opt/homebrew"))
        #expect(VPNCtl.childPATH.hasPrefix("/usr/bin"))
    }

    @Test func childEnvironmentKeysAreExactSet() {
        let parent: [String: String] = [
            "PATH": "/opt/homebrew/bin",
            "HOME": "/Users/tester",
            "USER": "tester",
            "LOGNAME": "tester",
            "TMPDIR": "/tmp",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "LC_CTYPE": "en_US.UTF-8",
            "NORD_SHORTCUT_ON": "evil",
            "VPN_CTL_LOCKDIR": "/tmp/evil-lock",
            "LAN_DNS_SUPPORT_DIR": "/tmp/evil-dns",
        ]

        let result = VPNCtl.childEnvironment(from: parent)

        #expect(Set(result.keys) == Set([
            "PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
        ]))
    }
}
