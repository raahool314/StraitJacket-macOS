import Foundation
import SJCore

// parentctl — admin-only CLI for managing StraitJacket policy.
//
// Requires root (run via `sudo`), so a Standard child account cannot use it.
// It edits the policy files under the root-owned support directory and nudges
// the daemon to reload; the daemon's slow cycle re-applies within seconds.

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func touchReload() {
    FileManager.default.createFile(atPath: Paths.reloadSignalFile, contents: Data())
}

let usage = """
StraitJacket for macOS — parentctl

Usage: sudo parentctl <command> [args]

Domains:
  add-domain <domain>       Block a domain (and its www. variant)
  remove-domain <domain>    Unblock a domain
  update-feeds              Re-download remote blocklist feeds now

Apps:
  block-app <id|path|name>  Block an app (bundle id, .app path, or exec name)
  unblock-app <id|path|name>  Unblock an app (also drops its ACL)

General:
  status                    Show daemon state and policy counts
  list                      List blocked domains and apps
  set-child <username>      Set the restricted (Standard) account
  pause [minutes]           Temporarily lift all blocks (default 30 min)
  resume                    Re-apply blocks now
  reload                    Ask the daemon to reload policy
"""

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(0) }

// Every mutating/inspecting command needs root to read the support dir.
guard getuid() == 0 else {
    die("parentctl must be run with sudo (root). Try: sudo parentctl \(args.joined(separator: " "))")
}

func arg(_ i: Int, _ name: String) -> String {
    guard args.count > i else { die("missing <\(name)>") }
    return args[i]
}

func daemonRunning() -> Bool {
    let r = Shell.run("/bin/launchctl", ["print", "system/\(Paths.label)"])
    return r.ok
}

switch cmd {
case "add-domain":
    let d = arg(1, "domain")
    let changed = (try? ListFile.add(d, to: Paths.blocklistFile)) ?? false
    touchReload()
    print(changed ? "blocked \(d)" : "\(d) was already blocked")

case "remove-domain":
    let d = arg(1, "domain")
    let changed = (try? ListFile.remove(d, from: Paths.blocklistFile)) ?? false
    touchReload()
    print(changed ? "unblocked \(d)" : "\(d) was not in the blocklist")

case "block-app":
    let a = arg(1, "id|path|name")
    let changed = (try? ListFile.add(a, to: Paths.appBlockFile)) ?? false
    touchReload()
    print(changed ? "blocked app \(a)" : "\(a) was already blocked")

case "unblock-app":
    let a = arg(1, "id|path|name")
    let changed = (try? ListFile.remove(a, from: Paths.appBlockFile)) ?? false
    // Drop the ACL immediately so the child can launch it again.
    let cfg = Config.load()
    AppBlocker(username: cfg.childUsername, entries: [a]).removeACLs()
    touchReload()
    print(changed ? "unblocked app \(a)" : "\(a) was not blocked")

case "update-feeds":
    print("downloading feeds…")
    if let n = FeedUpdater.update() {
        touchReload()
        print("cached \(n) domains")
    } else {
        die("no feeds reachable (check \(Paths.feedsFile))")
    }

case "set-child":
    let user = arg(1, "username")
    guard getpwnam(user) != nil else { die("no such user: \(user)") }
    var cfg = Config.load()
    cfg.childUsername = user
    do { try cfg.save() } catch { die("could not save config: \(error)") }
    touchReload()
    print("restricted account set to \(user)")

case "pause":
    let minutes = args.count > 1 ? (Int(args[1]) ?? 30) : 30
    let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
    let iso = ISO8601DateFormatter().string(from: until)
    do {
        try iso.write(toFile: Paths.pauseStateFile, atomically: true, encoding: .utf8)
    } catch { die("could not write pause state: \(error)") }
    print("blocks paused until \(iso) (\(minutes) min)")

case "resume":
    try? FileManager.default.removeItem(atPath: Paths.pauseStateFile)
    touchReload()
    print("blocks resumed")

case "list":
    let domains = ListFile.entries(Paths.blocklistFile)
    let apps = ListFile.entries(Paths.appBlockFile)
    let feeds = ListFile.entries(Paths.feedCacheFile)
    print("Blocked domains (curated): \(domains.count)")
    domains.forEach { print("  \($0)") }
    print("Blocked apps: \(apps.count)")
    apps.forEach { print("  \($0)") }
    print("Feed domains (cached): \(feeds.count)")

case "status":
    let cfg = Config.load()
    let paused: String
    if let s = try? String(contentsOfFile: Paths.pauseStateFile, encoding: .utf8),
       let until = ISO8601DateFormatter().date(from: s.trimmingCharacters(in: .whitespacesAndNewlines)),
       until > Date() {
        paused = "PAUSED until \(ISO8601DateFormatter().string(from: until))"
    } else {
        paused = "active"
    }
    print("daemon:        \(daemonRunning() ? "running" : "NOT running")")
    print("enforcement:   \(paused)")
    print("child account: \(cfg.childUsername) (uid \(getpwnam(cfg.childUsername)?.pointee.pw_uid.description ?? "—"))")
    print("upstream DNS:  \(cfg.upstreamDNS.joined(separator: ", "))")
    print("curated domains: \(ListFile.entries(Paths.blocklistFile).count)")
    print("feed domains:    \(ListFile.entries(Paths.feedCacheFile).count)")
    print("blocked apps:    \(ListFile.entries(Paths.appBlockFile).count)")

case "reload":
    touchReload()
    print("reload requested")

case "-h", "--help", "help":
    print(usage)

default:
    die("unknown command: \(cmd)\n\n\(usage)")
}
