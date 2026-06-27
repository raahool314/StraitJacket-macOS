import Foundation
import SJCore

/// Ties the layers together and drives the periodic re-apply / repair cycles.
///
///  - **Fast timer** (`appPollSeconds`): kill blocked apps for the child.
///  - **Slow timer** (`reassertSeconds`): reload policy from disk, re-point DNS
///    to the sinkhole, regenerate `/etc/hosts`, re-apply ACLs, repair tampering.
///  - **Feed timer** (`feedUpdateHours`): refresh remote blocklists.
///
/// A `pause-until` file (written by `parentctl pause`) temporarily lifts
/// enforcement so the parent can browse unfiltered; the loop restores blocks
/// automatically when it expires.
final class EnforcementLoop {
    private var config: Config
    private let sinkhole: DNSSinkhole
    private let queue = DispatchQueue(label: "straitjacket.enforce")

    private var fastTimer: DispatchSourceTimer?
    private var slowTimer: DispatchSourceTimer?
    private var feedTimer: DispatchSourceTimer?

    /// Tracks pause state so we only restore/re-apply on transitions.
    private var wasPaused = false

    init(config: Config, sinkhole: DNSSinkhole) {
        self.config = config
        self.sinkhole = sinkhole
    }

    // MARK: Policy assembly

    private func readLines(_ path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Full DNS blocklist: curated lists + hosts-only list + downloaded feeds.
    private func buildDNSBlocklist() -> DomainBlocklist {
        let bl = DomainBlocklist()
        if let t = try? String(contentsOfFile: Paths.blocklistFile, encoding: .utf8) { bl.load(linesFrom: t) }
        if let t = try? String(contentsOfFile: Paths.hostsOnlyFile, encoding: .utf8) { bl.load(linesFrom: t) }
        if let t = try? String(contentsOfFile: Paths.dnsOnlyFile, encoding: .utf8) { bl.load(linesFrom: t) }
        if let t = try? String(contentsOfFile: Paths.feedCacheFile, encoding: .utf8) { bl.load(linesFrom: t, addWWW: false) }
        return bl
    }

    /// The curated subset mirrored into /etc/hosts (feeds stay DNS-only).
    private func buildHostsDomains() -> [String] {
        let bl = DomainBlocklist()
        if let t = try? String(contentsOfFile: Paths.blocklistFile, encoding: .utf8) { bl.load(linesFrom: t) }
        if let t = try? String(contentsOfFile: Paths.hostsOnlyFile, encoding: .utf8) { bl.load(linesFrom: t) }
        return bl.sortedDomains()
    }

    private func appBlocker() -> AppBlocker {
        AppBlocker(username: config.childUsername, entries: readLines(Paths.appBlockFile))
    }

    // MARK: Pause

    /// True while a future `pause-until` instant is set.
    private func isPaused() -> Bool {
        guard let s = try? String(contentsOfFile: Paths.pauseStateFile, encoding: .utf8) else {
            return false
        }
        let iso = ISO8601DateFormatter()
        guard let until = iso.date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return until > Date()
    }

    // MARK: Cycles

    /// Fast cycle: kill blocked apps unless paused.
    private func fastCycle() {
        if isPaused() { return }
        appBlocker().killBlockedProcesses()
    }

    /// Slow cycle: reload policy and re-assert every layer (or tear down while paused).
    private func slowCycle() {
        config = Config.load()

        let paused = isPaused()
        if paused {
            if !wasPaused {
                Log.info("paused — lifting blocks")
                NetworkConfig.restoreDefault()
                HostsManager.remove()
                appBlocker().removeACLs()
                NetworkConfig.flushDNSCache()
            }
            wasPaused = true
            return
        }
        if wasPaused { Log.info("resumed — re-applying blocks") }
        wasPaused = false

        // DNS: refresh blocklist + re-point resolvers.
        sinkhole.updateBlocklist(buildDNSBlocklist())
        NetworkConfig.pointToSinkhole()

        // Hosts + ACLs.
        let hostsChanged = HostsManager.apply(domains: buildHostsDomains())
        appBlocker().applyACLs()

        if hostsChanged { NetworkConfig.flushDNSCache() }
    }

    /// Feed cycle: download remote lists, then refresh the DNS blocklist.
    private func feedCycle() {
        if let n = FeedUpdater.update() {
            Log.info("feeds updated: \(n) domains cached")
            if !isPaused() { sinkhole.updateBlocklist(buildDNSBlocklist()) }
        }
    }

    // MARK: Lifecycle

    func start() {
        // Run an immediate slow + feed pass so blocks are live at boot.
        queue.async { [weak self] in
            self?.slowCycle()
            self?.feedCycle()
        }

        let fast = DispatchSource.makeTimerSource(queue: queue)
        fast.schedule(deadline: .now() + .seconds(config.appPollSeconds),
                      repeating: .seconds(max(1, config.appPollSeconds)))
        fast.setEventHandler { [weak self] in self?.fastCycle() }
        fast.resume()
        fastTimer = fast

        let slow = DispatchSource.makeTimerSource(queue: queue)
        slow.schedule(deadline: .now() + .seconds(config.reassertSeconds),
                      repeating: .seconds(max(5, config.reassertSeconds)))
        slow.setEventHandler { [weak self] in self?.slowCycle() }
        slow.resume()
        slowTimer = slow

        let feed = DispatchSource.makeTimerSource(queue: queue)
        let feedInterval = max(1, config.feedUpdateHours) * 3600
        feed.schedule(deadline: .now() + .seconds(feedInterval),
                      repeating: .seconds(feedInterval))
        feed.setEventHandler { [weak self] in self?.feedCycle() }
        feed.resume()
        feedTimer = feed
    }
}
