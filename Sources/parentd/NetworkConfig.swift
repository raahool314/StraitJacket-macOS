import Foundation
import SJCore

/// Points every active network service's DNS at our local sinkhole, and can
/// restore the system default. Uses `networksetup`, which the daemon (root)
/// is allowed to invoke. Re-asserted each slow cycle so a Standard user who
/// fiddles with network settings is reverted within ~30s.
enum NetworkConfig {
    /// All configured network service names (Wi-Fi, Ethernet, …), skipping
    /// the asterisk-prefixed "disabled" markers networksetup emits.
    static func serviceNames() -> [String] {
        let r = Shell.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
        guard r.ok else { return [] }
        return r.stdout
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.lowercased().contains("denotes that") }
    }

    /// Set DNS for every service to 127.0.0.1. Returns true if at least one
    /// service was updated.
    @discardableResult
    static func pointToSinkhole() -> Bool {
        var any = false
        for svc in serviceNames() {
            let r = Shell.run("/usr/sbin/networksetup", ["-setdnsservers", svc, "127.0.0.1"])
            if r.ok { any = true } else {
                Log.warn("networksetup failed for \(svc): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        return any
    }

    /// Restore DNS to DHCP-provided defaults (used by uninstall / pause).
    static func restoreDefault() {
        for svc in serviceNames() {
            // "Empty" clears the manual list so DHCP DNS is used again.
            Shell.run("/usr/sbin/networksetup", ["-setdnsservers", svc, "Empty"])
        }
        flushDNSCache()
    }

    /// Flush mDNSResponder so changes to /etc/hosts and resolver take effect.
    static func flushDNSCache() {
        Shell.run("/usr/bin/dscacheutil", ["-flushcache"])
        Shell.run("/usr/bin/killall", ["-HUP", "mDNSResponder"])
    }
}
