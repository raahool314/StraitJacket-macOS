import Foundation

/// Downloads remote blocklist feeds (URLs in `feeds.txt`), extracts domains,
/// and writes the union to `feedcache.txt`. Feeds may be plain domain lists or
/// hosts-file format (`0.0.0.0 domain`); both are handled by
/// `DomainBlocklist.load`.
public enum FeedUpdater {
    /// Fetch all feeds and persist the merged cache. Returns the number of
    /// unique domains cached, or nil if no feeds were reachable.
    @discardableResult
    public static func update(timeout: TimeInterval = 30) -> Int? {
        guard let feedsText = try? String(contentsOfFile: Paths.feedsFile, encoding: .utf8) else {
            return nil
        }
        let urls = feedsText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !urls.isEmpty else { return nil }

        let merged = DomainBlocklist()
        var anyOK = false
        let sem = DispatchSemaphore(value: 0)
        let lock = NSLock()

        let session = URLSession(configuration: .ephemeral)
        for urlStr in urls {
            guard let url = URL(string: urlStr) else { sem.signal(); continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = timeout
            let task = session.dataTask(with: req) { data, _, err in
                defer { sem.signal() }
                guard let data, err == nil,
                      let text = String(data: data, encoding: .utf8) else {
                    Log.warn("feed fetch failed: \(urlStr) \(err.map { "\($0)" } ?? "")")
                    return
                }
                lock.lock()
                merged.load(linesFrom: text, addWWW: false)
                anyOK = true
                lock.unlock()
                Log.info("fetched feed \(urlStr)")
            }
            task.resume()
        }
        for _ in urls { sem.wait() }

        guard anyOK else { return nil }
        let domains = merged.sortedDomains()
        let out = domains.joined(separator: "\n") + "\n"
        do {
            try out.write(toFile: Paths.feedCacheFile, atomically: true, encoding: .utf8)
        } catch {
            Log.error("failed to write feed cache: \(error)")
        }
        return domains.count
    }
}
