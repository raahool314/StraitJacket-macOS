import Foundation

/// In-memory set of blocked domains with suffix (wildcard) matching.
///
/// A query for `ads.tracker.example.com` is blocked if the set contains that
/// exact name or any parent suffix (`tracker.example.com`, `example.com`,
/// `com`). Lookups are O(number of labels) — a handful of `Set` probes.
public final class DomainBlocklist {
    private var domains: Set<String> = []

    public init() {}

    public var count: Int { domains.count }

    /// Normalize a domain: lowercase, strip trailing dot and leading `*.`/`www.`
    /// is *not* stripped here — `www` variants are added explicitly by callers.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty, !s.hasPrefix("#") else { return nil }
        if s.hasSuffix(".") { s.removeLast() }
        // Reject anything that isn't a plausible hostname.
        guard !s.isEmpty, !s.contains(" "), s.contains(".") || !s.contains("/") else {
            return nil
        }
        return s
    }

    /// Add a single domain (and its `www.` variant) if valid.
    @discardableResult
    public func insert(_ raw: String) -> Bool {
        guard let d = DomainBlocklist.normalize(raw) else { return false }
        domains.insert(d)
        if !d.hasPrefix("www.") { domains.insert("www." + d) }
        return true
    }

    public func remove(_ raw: String) {
        guard let d = DomainBlocklist.normalize(raw) else { return }
        domains.remove(d)
        domains.remove("www." + d)
    }

    public func removeAll() { domains.removeAll(keepingCapacity: true) }

    /// True if `name` or any parent domain is in the set.
    public func isBlocked(_ name: String) -> Bool {
        guard var s = DomainBlocklist.normalize(name) else { return false }
        while true {
            if domains.contains(s) { return true }
            guard let dot = s.firstIndex(of: ".") else { return false }
            s = String(s[s.index(after: dot)...])
            if s.isEmpty { return false }
        }
    }

    /// Bulk-load from newline-delimited text. Lines may be bare domains or
    /// hosts-file style (`0.0.0.0 domain`); the last whitespace token is taken.
    public func load(linesFrom text: String, addWWW: Bool = true) {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // hosts-file form: take the hostname token, skip the IP.
            let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.map(String.init) ?? line
            guard let d = DomainBlocklist.normalize(token) else { continue }
            domains.insert(d)
            if addWWW && !d.hasPrefix("www.") { domains.insert("www." + d) }
        }
    }

    /// Snapshot of all entries (sorted) — used to regenerate `/etc/hosts`.
    public func sortedDomains() -> [String] { domains.sorted() }
}
