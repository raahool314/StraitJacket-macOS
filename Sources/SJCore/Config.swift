import Foundation

/// On-disk policy knobs (`config.json`). Lists of domains/apps live in their
/// own text files so the parent can edit them by hand or via `parentctl`.
public struct Config: Codable, Equatable {
    /// The Standard account these restrictions target (app-kill scope, ACLs).
    public var childUsername: String

    /// How often to scan and kill blocked apps for the child UID.
    public var appPollSeconds: Int

    /// How often to re-assert DNS settings, /etc/hosts, and ACLs (tamper repair).
    public var reassertSeconds: Int

    /// How often to re-download remote feeds.
    public var feedUpdateHours: Int

    /// Upstream resolvers for non-blocked DNS queries.
    public var upstreamDNS: [String]

    public init(
        childUsername: String = "child",
        appPollSeconds: Int = 2,
        reassertSeconds: Int = 30,
        feedUpdateHours: Int = 24,
        upstreamDNS: [String] = ["1.1.1.1", "8.8.8.8"]
    ) {
        self.childUsername = childUsername
        self.appPollSeconds = appPollSeconds
        self.reassertSeconds = reassertSeconds
        self.feedUpdateHours = feedUpdateHours
        self.upstreamDNS = upstreamDNS
    }

    // Defaults fill in any keys missing from a hand-edited file.
    enum CodingKeys: String, CodingKey {
        case childUsername, appPollSeconds, reassertSeconds, feedUpdateHours, upstreamDNS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        childUsername = try c.decodeIfPresent(String.self, forKey: .childUsername) ?? d.childUsername
        appPollSeconds = try c.decodeIfPresent(Int.self, forKey: .appPollSeconds) ?? d.appPollSeconds
        reassertSeconds = try c.decodeIfPresent(Int.self, forKey: .reassertSeconds) ?? d.reassertSeconds
        feedUpdateHours = try c.decodeIfPresent(Int.self, forKey: .feedUpdateHours) ?? d.feedUpdateHours
        upstreamDNS = try c.decodeIfPresent([String].self, forKey: .upstreamDNS) ?? d.upstreamDNS
    }

    /// Load from `Paths.configFile`, falling back to defaults if absent/unreadable.
    public static func load() -> Config {
        guard let data = FileManager.default.contents(atPath: Paths.configFile) else {
            return Config()
        }
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            FileHandle.standardError.write(
                Data("straitjacket: malformed config.json, using defaults: \(error)\n".utf8))
            return Config()
        }
    }

    /// Write back to `Paths.configFile` (pretty-printed, stable key order).
    public func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: URL(fileURLWithPath: Paths.configFile), options: .atomic)
    }
}
