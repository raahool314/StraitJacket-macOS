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
    private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func info(_ msg: String) { emit("INFO", msg) }
    public static func warn(_ msg: String) { emit("WARN", msg) }
    public static func error(_ msg: String) { emit("ERROR", msg) }

    private static func emit(_ level: String, _ msg: String) {
        let line = "\(fmt.string(from: Date())) [\(level)] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
