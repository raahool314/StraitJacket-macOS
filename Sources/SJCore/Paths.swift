import Foundation

/// Canonical install/runtime locations shared by the daemon and the CLI.
///
/// Everything under `supportDir` is owned by `root:wheel` so a Standard
/// (child) user cannot read or rewrite policy. The CLI refuses to run unless
/// it is `root`, so only an admin (via `sudo`) can mutate these files.
public enum Paths {
    /// Reverse-DNS label used for the launchd job and log/marker prefixes.
    public static let label = "com.straitjacket.mac"

    /// Human-facing product name, used for directories.
    public static let productName = "StraitJacket"

    // MARK: Binaries

    public static let daemonBinary = "/usr/local/sbin/parentd"
    public static let cliBinary = "/usr/local/bin/parentctl"

    // MARK: Support directory (config + lists + runtime state)

    public static let supportDir = "/Library/Application Support/\(productName)"

    public static var configFile: String { "\(supportDir)/config.json" }
    public static var blocklistFile: String { "\(supportDir)/blocklist.txt" }
    public static var hostsOnlyFile: String { "\(supportDir)/hostsonly.txt" }
    public static var appBlockFile: String { "\(supportDir)/appblock.txt" }
    public static var feedsFile: String { "\(supportDir)/feeds.txt" }

    /// Domains blocked at the DNS sinkhole ONLY (never written to /etc/hosts).
    /// Used for CNAME-collision cases: e.g. lite.duckduckgo.com is a CNAME to
    /// duckduckgo.com, so a hosts entry for duckduckgo.com would also break
    /// lite. Sinkholing it (direct query only) blocks the parent while leaving
    /// the CNAME'd sibling reachable.
    public static var dnsOnlyFile: String { "\(supportDir)/dnsonly.txt" }

    /// Cached union of all feed downloads (one domain per line).
    public static var feedCacheFile: String { "\(supportDir)/feedcache.txt" }

    /// Presence + contents (an ISO-8601 instant) signal a temporary pause.
    public static var pauseStateFile: String { "\(supportDir)/pause-until" }

    /// Touched by the CLI to ask the running daemon to reload policy.
    public static var reloadSignalFile: String { "\(supportDir)/reload" }

    // MARK: launchd + logs

    public static var launchDaemonPlist: String {
        "/Library/LaunchDaemons/\(label).plist"
    }

    public static let logDir = "/Library/Logs/\(productName)"
    public static var daemonLog: String { "\(logDir)/parentd.log" }

    // MARK: System files we manage

    public static let hostsFile = "/etc/hosts"

    /// Begin/end markers delimiting our managed region of `/etc/hosts`.
    public static let hostsBeginMarker = "# STRAITJACKET BEGIN — managed, do not edit"
    public static let hostsEndMarker = "# STRAITJACKET END"
}
