import Foundation
import Network

/// Forwards a raw DNS query to an upstream resolver over UDP and returns the
/// raw response. One short-lived `NWConnection` per query keeps this simple;
/// DNS over UDP is request/response so we just read the first datagram.
final class UpstreamResolver {
    private let endpoints: [NWEndpoint]
    private let queue = DispatchQueue(label: "straitjacket.upstream")

    init(servers: [String]) {
        // Fall back to Cloudflare if config somehow has none.
        let list = servers.isEmpty ? ["1.1.1.1"] : servers
        endpoints = list.map { NWEndpoint.hostPort(host: NWEndpoint.Host($0), port: 53) }
    }

    /// Resolve via the first server that answers within `timeout` seconds.
    /// `completion` is always called exactly once (nil on total failure).
    func resolve(_ query: [UInt8], timeout: TimeInterval = 3, completion: @escaping ([UInt8]?) -> Void) {
        attempt(index: 0, query: query, timeout: timeout, completion: completion)
    }

    private func attempt(index: Int, query: [UInt8], timeout: TimeInterval,
                         completion: @escaping ([UInt8]?) -> Void) {
        guard index < endpoints.count else { completion(nil); return }

        let conn = NWConnection(to: endpoints[index], using: .udp)
        var finished = false
        let finish: ([UInt8]?) -> Void = { [weak self] result in
            if finished { return }
            finished = true
            conn.cancel()
            if let result {
                completion(result)
            } else {
                // Try the next upstream server.
                self?.attempt(index: index + 1, query: query, timeout: timeout, completion: completion)
            }
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                conn.send(content: Data(query), completion: .contentProcessed { err in
                    if err != nil { finish(nil); return }
                    conn.receiveMessage { data, _, _, recvErr in
                        if let data, recvErr == nil, !data.isEmpty {
                            finish([UInt8](data))
                        } else {
                            finish(nil)
                        }
                    }
                })
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
    }
}
