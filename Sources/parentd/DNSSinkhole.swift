import Foundation
import Network
import SJCore

/// Local DNS server bound to 127.0.0.1:53. Blocked names are answered with
/// 0.0.0.0 / ::; everything else is forwarded to the configured upstream
/// resolvers and relayed back verbatim.
///
/// The blocklist is held behind a lock and can be hot-swapped by the
/// enforcement loop when policy or feeds change.
final class DNSSinkhole {
    private let port: NWEndpoint.Port = 53
    private let queue = DispatchQueue(label: "straitjacket.dns")
    private var listener: NWListener?
    private let upstream: UpstreamResolver

    private let lock = NSLock()
    private var blocklist: DomainBlocklist

    init(blocklist: DomainBlocklist, upstreamServers: [String]) {
        self.blocklist = blocklist
        self.upstream = UpstreamResolver(servers: upstreamServers)
    }

    /// Replace the active blocklist (called after feed updates / policy edits).
    func updateBlocklist(_ new: DomainBlocklist) {
        lock.lock(); blocklist = new; lock.unlock()
    }

    private func isBlocked(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blocklist.isBlocked(name)
    }

    /// Start listening. Throws if the port can't be bound (e.g. another
    /// resolver already owns :53) — the caller logs and continues without
    /// the DNS layer (the /etc/hosts layer still applies).
    func start() throws {
        let params = NWParameters.udp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                Log.info("DNS sinkhole listening on 127.0.0.1:53")
            case .failed(let err):
                Log.error("DNS listener failed: \(err)")
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // Each inbound datagram arrives as a new UDP "connection" flow.
    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receiveMessage { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else { conn.cancel(); return }
            let query = [UInt8](data)
            self.respond(to: query, on: conn)
        }
    }

    private func respond(to query: [UInt8], on conn: NWConnection) {
        let send: ([UInt8]) -> Void = { bytes in
            conn.send(content: Data(bytes), completion: .contentProcessed { _ in
                conn.cancel()
            })
        }

        if let q = DNSPacket.firstQuestion(query), isBlocked(q.name),
           let sink = DNSPacket.sinkholeResponse(for: query, question: q) {
            Log.info("DNS block \(q.name)")
            send(sink)
            return
        }

        // Not blocked (or unparseable / non-A) → forward upstream.
        upstream.resolve(query) { reply in
            if let reply {
                send(reply)
            } else {
                conn.cancel()
            }
        }
    }
}
