import Foundation
import SJCore

/// Maintains a marked region in /etc/hosts as a belt-and-suspenders layer
/// beneath the DNS sinkhole. Regenerated idempotently each slow cycle, so any
/// tampering by a Standard user (who can't write /etc/hosts anyway) or a stale
/// region is repaired. Entries point at 0.0.0.0.
enum HostsManager {
    /// Rewrite /etc/hosts so its managed region exactly lists `domains`.
    /// Returns true if the file changed.
    @discardableResult
    static func apply(domains: [String]) -> Bool {
        let existing = (try? String(contentsOfFile: Paths.hostsFile, encoding: .utf8)) ?? ""
        let preserved = stripManagedRegion(existing)

        var region = [Paths.hostsBeginMarker]
        for d in domains {
            region.append("0.0.0.0 \(d)")
        }
        region.append(Paths.hostsEndMarker)

        var newContents = preserved
        if !newContents.isEmpty && !newContents.hasSuffix("\n") { newContents += "\n" }
        newContents += region.joined(separator: "\n") + "\n"

        if newContents == existing { return false }
        do {
            try newContents.write(toFile: Paths.hostsFile, atomically: true, encoding: .utf8)
            return true
        } catch {
            Log.error("failed to write /etc/hosts: \(error)")
            return false
        }
    }

    /// Remove our managed region entirely (uninstall).
    static func remove() {
        guard let existing = try? String(contentsOfFile: Paths.hostsFile, encoding: .utf8) else { return }
        let cleaned = stripManagedRegion(existing)
        try? cleaned.write(toFile: Paths.hostsFile, atomically: true, encoding: .utf8)
    }

    /// Return `text` with any `BEGIN…END` managed block (and surrounding blank
    /// lines) removed, preserving the user's own host entries.
    private static func stripManagedRegion(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        var out: [String] = []
        var inside = false
        for line in lines {
            if line == Paths.hostsBeginMarker { inside = true; continue }
            if line == Paths.hostsEndMarker { inside = false; continue }
            if !inside { out.append(line) }
        }
        // Trim trailing blank lines for a tidy file.
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            out.removeLast()
        }
        return out.joined(separator: "\n")
    }
}
