import Foundation

/// Minimal DNS wire-format helpers: extract the queried name from a request,
/// and synthesize a "sinkhole" answer pointing the name at 0.0.0.0 / ::.
///
/// We only need enough of RFC 1035 to read the first question and build an
/// answer; anything we can't parse is simply forwarded upstream unchanged.
enum DNSPacket {
    /// DNS header is 12 bytes; the question section follows immediately.
    static let headerLength = 12

    /// QTYPE / QCLASS we care about.
    static let typeA: UInt16 = 1
    static let typeAAAA: UInt16 = 28
    static let classIN: UInt16 = 1

    struct Question {
        let name: String        // lowercased, dot-joined, no trailing dot
        let qtype: UInt16
        let qclass: UInt16
        let endOffset: Int      // index just past the question section
    }

    /// Parse the first question from a query. Returns nil on malformed input
    /// (caller should then forward upstream rather than guess).
    static func firstQuestion(_ data: [UInt8]) -> Question? {
        guard data.count > headerLength else { return nil }
        // QDCOUNT must be >= 1.
        let qdcount = UInt16(data[4]) << 8 | UInt16(data[5])
        guard qdcount >= 1 else { return nil }

        var i = headerLength
        var labels: [String] = []
        while i < data.count {
            let len = Int(data[i])
            if len == 0 { i += 1; break }
            // Compression pointers shouldn't appear in a question name.
            if len & 0xC0 != 0 { return nil }
            i += 1
            guard i + len <= data.count else { return nil }
            labels.append(String(decoding: data[i..<i+len], as: UTF8.self))
            i += len
        }
        guard i + 4 <= data.count else { return nil }
        let qtype = UInt16(data[i]) << 8 | UInt16(data[i+1])
        let qclass = UInt16(data[i+2]) << 8 | UInt16(data[i+3])
        let name = labels.joined(separator: ".").lowercased()
        return Question(name: name, qtype: qtype, qclass: qclass, endOffset: i + 4)
    }

    /// Build a sinkhole response for `query`: copy the question, set QR/RA, and
    /// append a single A (0.0.0.0) or AAAA (::) answer with a short TTL.
    /// Returns nil if the query isn't a simple A/AAAA we want to sink.
    static func sinkholeResponse(for query: [UInt8], question q: Question) -> [UInt8]? {
        guard q.qclass == classIN, q.qtype == typeA || q.qtype == typeAAAA else {
            return nil
        }
        var r = Array(query[0..<q.endOffset])   // header + question

        // Header flags: QR=1, copy Opcode/RD from request, RA=1, RCODE=0.
        let rd = query[2] & 0x01
        r[2] = 0x80 | (query[2] & 0x78) | rd     // QR + opcode + RD
        r[3] = 0x80                              // RA, RCODE 0
        // ANCOUNT = 1; NSCOUNT/ARCOUNT = 0.
        r[6] = 0; r[7] = 1
        r[8] = 0; r[9] = 0
        r[10] = 0; r[11] = 0

        // Answer: name pointer to offset 12 (the question name).
        r.append(0xC0); r.append(0x0C)
        // TYPE
        r.append(UInt8(q.qtype >> 8)); r.append(UInt8(q.qtype & 0xFF))
        // CLASS IN
        r.append(0x00); r.append(0x01)
        // TTL = 60s
        r.append(contentsOf: [0x00, 0x00, 0x00, 0x3C])
        if q.qtype == typeA {
            r.append(0x00); r.append(0x04)                  // RDLENGTH 4
            r.append(contentsOf: [0, 0, 0, 0])              // 0.0.0.0
        } else {
            r.append(0x00); r.append(0x10)                  // RDLENGTH 16
            r.append(contentsOf: Array(repeating: 0, count: 16)) // ::
        }
        return r
    }
}
