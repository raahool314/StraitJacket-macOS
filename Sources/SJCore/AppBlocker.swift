import Foundation

/// Blocks apps for the child account using two complementary layers:
///
///  1. **Filesystem ACLs** — deny the child `execute` on the app's Mach-O
///     binary, so Finder/Dock launches fail outright. Skipped for SIP-protected
///     `/System` apps (which can't be modified).
///  2. **Poll-and-kill** — list the child's processes and `SIGKILL` anything
///     matching the blocklist. Backstop for copied/reinstalled apps and SIP
///     apps the ACL layer can't touch.
///
/// `appblock.txt` entries may be bundle IDs (`com.valvesoftware.steam`),
/// `.app` paths (`/Applications/Steam.app`), or bare executable names (`steam`).
///
/// Lives in SJCore so both the daemon (apply/kill) and the CLI (unblock →
/// remove a single ACL) can use it.
public struct AppBlocker {
    public let username: String
    private let entries: [String]

    public init(username: String, entries: [String]) {
        self.username = username
        self.entries = entries.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Resolve the child's numeric UID, or nil if the account doesn't exist.
    public var childUID: uid_t? {
        guard let pw = getpwnam(username) else { return nil }
        return pw.pointee.pw_uid
    }

    // MARK: Entry resolution

    /// Absolute `.app` bundle paths for every entry we can resolve.
    private func resolvedAppPaths() -> [String] {
        var paths: [String] = []
        for e in entries {
            if e.hasSuffix(".app") {
                paths.append(e)
            } else if e.contains(".") && !e.contains("/") {
                if let p = Self.appPath(forBundleID: e) { paths.append(p) }
            }
        }
        return paths
    }

    /// Lowercased bare executable-name needles for kill matching.
    private func execNameNeedles() -> [String] {
        entries
            .filter { !$0.hasSuffix(".app") && !$0.contains("/") && !$0.contains(".") }
            .map { $0.lowercased() }
    }

    /// Resolve a bundle ID to its `.app` path via Spotlight metadata.
    public static func appPath(forBundleID id: String) -> String? {
        let r = Shell.run("/usr/bin/mdfind", ["kMDItemCFBundleIdentifier == '\(id)'"])
        guard r.ok else { return nil }
        return r.stdout.split(separator: "\n").map(String.init)
            .first { $0.hasSuffix(".app") }
    }

    /// The Mach-O executable inside an `.app` (from CFBundleExecutable).
    public static func executable(inApp appPath: String) -> String? {
        let plist = "\(appPath)/Contents/Info.plist"
        let r = Shell.run("/usr/bin/defaults", ["read", plist, "CFBundleExecutable"])
        let name = r.ok ? r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let exec = name.isEmpty
            ? (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
            : name
        return "\(appPath)/Contents/MacOS/\(exec)"
    }

    // MARK: Layer 1 — ACLs

    /// Apply deny-execute ACLs for the child on every resolvable app binary.
    public func applyACLs() {
        for app in resolvedAppPaths() {
            if app.hasPrefix("/System/") { continue }   // SIP-protected
            guard let bin = Self.executable(inApp: app),
                  FileManager.default.fileExists(atPath: bin) else { continue }
            let r = Shell.run("/bin/chmod", ["+a", "user:\(username) deny execute", bin])
            if !r.ok {
                Log.warn("chmod ACL failed for \(bin): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
    }

    /// Remove the deny-execute ACLs (uninstall / unblock).
    public func removeACLs() {
        for app in resolvedAppPaths() {
            guard let bin = Self.executable(inApp: app),
                  FileManager.default.fileExists(atPath: bin) else { continue }
            Shell.run("/bin/chmod", ["-a", "user:\(username) deny execute", bin])
        }
    }

    // MARK: Layer 2 — poll and kill

    /// Kill any blocked process owned by the child.
    public func killBlockedProcesses() {
        guard let uid = childUID else { return }
        let appPaths = resolvedAppPaths()
        let execNeedles = execNameNeedles()
        if appPaths.isEmpty && execNeedles.isEmpty { return }

        let r = Shell.run("/bin/ps", ["-axww", "-o", "pid=,uid=,comm="])
        guard r.ok else { return }

        for line in r.stdout.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let pid = Int32(parts[0]),
                  let puid = UInt32(parts[1]),
                  puid == uid else { continue }
            let path = String(parts[2])
            if matches(path: path, appPaths: appPaths, execNeedles: execNeedles) {
                if kill(pid, SIGKILL) == 0 {
                    Log.info("killed blocked app pid=\(pid) \(path)")
                }
            }
        }
    }

    private func matches(path: String, appPaths: [String], execNeedles: [String]) -> Bool {
        let lower = path.lowercased()
        for app in appPaths where lower.contains(app.lowercased() + "/") {
            return true
        }
        let base = (path as NSString).lastPathComponent.lowercased()
        return execNeedles.contains(base)
    }
}
