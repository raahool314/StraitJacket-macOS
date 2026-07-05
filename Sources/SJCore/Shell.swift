import Foundation

/// Thin wrapper around `Process` for invoking system tools
/// (`networksetup`, `chmod`, `dscacheutil`, `launchctl`, …).
public enum Shell {
    public struct Result {
        public let status: Int32
        public let stdout: String
        public let stderr: String
        public var ok: Bool { status == 0 }
    }

    /// Run `tool` with `args`, capturing output. Never throws — a failure to
    /// launch is reported as a non-zero status so callers can stay simple.
    @discardableResult
    public static func run(_ tool: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do {
            try p.run()
        } catch {
            return Result(status: 127, stdout: "", stderr: "\(error)")
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            status: p.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self))
    }
}

/// Timestamped logging to stderr (captured into the daemon log by launchd).
public enum Log {
    /// Days of history retained by `prune`.
    public static let retentionDays = 14

    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Serializes every write and prune so a rewrite can't interleave with a line.
    private static let queue = DispatchQueue(label: "straitjacket.log")

    /// When set (daemon only), lines are appended here instead of stderr and the
    /// file can be pruned by age. The CLI leaves this nil and logs to the terminal.
    private static var handle: FileHandle?
    private static var filePath: String?

    /// Route logging into `path` (append mode). Called once by the daemon at
    /// startup; falls back to stderr if the file can't be opened. The handle is
    /// O_APPEND, so it stays correct even after `prune` truncates the file.
    public static func startFileLogging(path: String) {
        queue.sync {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }   // keep logging to stderr
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            filePath = path
        }
    }

    public static func info(_ msg: String) { emit("INFO", msg) }
    public static func warn(_ msg: String) { emit("WARN", msg) }
    public static func error(_ msg: String) { emit("ERROR", msg) }

    private static func emit(_ level: String, _ msg: String) {
        let line = "\(fmt.string(from: Date())) [\(level)] \(msg)\n"
        let data = Data(line.utf8)
        queue.sync {
            (handle ?? FileHandle.standardError).write(data)
        }
    }

    /// Drop log lines whose leading timestamp is older than `retainingDays`,
    /// rewriting the file in place (same inode, so the append handle and
    /// launchd's redirect keep working). No-op unless file logging is active.
    /// Returns the number of lines removed.
    @discardableResult
    public static func prune(retainingDays days: Int = retentionDays) -> Int {
        queue.sync {
            guard let path = filePath,
                  let data = FileManager.default.contents(atPath: path),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else { return 0 }

            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let endsWithNewline = text.hasSuffix("\n")
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let kept = lines.filter { line in
                // Keep lines we can't date (blanks, continuations) and recent ones.
                guard let ts = leadingTimestamp(line) else { return true }
                return ts >= cutoff
            }
            let removed = lines.count - kept.count
            guard removed > 0 else { return 0 }

            var out = kept.joined(separator: "\n")
            if endsWithNewline, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }

            // Rewrite via a separate non-append fd so seek/truncate take effect.
            if let wh = FileHandle(forWritingAtPath: path) {
                let d = Data(out.utf8)
                wh.seek(toFileOffset: 0)
                wh.write(d)
                wh.truncateFile(atOffset: UInt64(d.count))
                wh.closeFile()
            }
            return removed
        }
    }

    /// The ISO-8601 instant at the start of a log line (`2026-07-05T06:33:31Z …`).
    private static func leadingTimestamp(_ line: String) -> Date? {
        guard let sp = line.firstIndex(of: " ") else { return nil }
        return fmt.date(from: String(line[..<sp]))
    }
}
