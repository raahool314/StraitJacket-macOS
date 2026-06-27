import Foundation

/// Helpers for the newline-delimited policy files (`blocklist.txt`,
/// `appblock.txt`, …). Comments (`#`) and blank lines are preserved on read
/// only as needed; mutations operate on the meaningful entries.
public enum ListFile {
    /// All non-empty, non-comment entries (trimmed), in file order.
    public static func entries(_ path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    /// Append `entry` if not already present (case-insensitive). Returns true
    /// if the file was modified.
    @discardableResult
    public static func add(_ entry: String, to path: String) throws -> Bool {
        let e = entry.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty else { return false }
        var lines = entries(path)
        if lines.contains(where: { $0.caseInsensitiveCompare(e) == .orderedSame }) {
            return false
        }
        lines.append(e)
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }

    /// Remove every case-insensitive match of `entry`. Returns true if changed.
    @discardableResult
    public static func remove(_ entry: String, from path: String) throws -> Bool {
        let e = entry.trimmingCharacters(in: .whitespaces)
        let lines = entries(path)
        let kept = lines.filter { $0.caseInsensitiveCompare(e) != .orderedSame }
        guard kept.count != lines.count else { return false }
        try (kept.isEmpty ? "" : kept.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return true
    }
}
