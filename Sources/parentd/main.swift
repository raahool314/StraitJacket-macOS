import Foundation
import SJCore

// parentd — the StraitJacket-for-macOS enforcement daemon.
//
// Runs as root under launchd (RunAtLoad + KeepAlive). Brings up the DNS
// sinkhole and starts the enforcement loop, then parks on the dispatch main
// queue so the timers fire forever. launchd restarts us if we ever exit.

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("parentd must run as root\n".utf8))
    exit(1)
}

Log.info("parentd starting (\(Paths.label))")

let config = Config.load()

// Seed the sinkhole with whatever policy already exists on disk; the loop
// refreshes it immediately on its first slow cycle.
let initialBlocklist = DomainBlocklist()
if let t = try? String(contentsOfFile: Paths.blocklistFile, encoding: .utf8) { initialBlocklist.load(linesFrom: t) }
if let t = try? String(contentsOfFile: Paths.hostsOnlyFile, encoding: .utf8) { initialBlocklist.load(linesFrom: t) }
if let t = try? String(contentsOfFile: Paths.dnsOnlyFile, encoding: .utf8) { initialBlocklist.load(linesFrom: t) }
if let t = try? String(contentsOfFile: Paths.feedCacheFile, encoding: .utf8) { initialBlocklist.load(linesFrom: t, addWWW: false) }

let sinkhole = DNSSinkhole(blocklist: initialBlocklist, upstreamServers: config.upstreamDNS)
do {
    try sinkhole.start()
} catch {
    // Port 53 in use, etc. — continue with the /etc/hosts layer only.
    Log.warn("DNS sinkhole unavailable (\(error)); continuing with hosts layer only")
}

let loop = EnforcementLoop(config: config, sinkhole: sinkhole)
loop.start()

dispatchMain()
