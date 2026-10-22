import Darwin
import Foundation

struct DNSProbeReport: Encodable {
    let startedAt: String
    var finishedAt: String?
    var phase: String
    let testDomain = "a3-probe.invalid"
    let answerAddress = "192.0.2.123"
    var initialInterfaces: [InterfaceAddress]
    var finalInterfaces: [InterfaceAddress] = []
    var otherPacketCount = 0
    var matchingQueryCount = 0
    var responseBytes = 0
    var errorCode: Int32?
    var detail: String
}

enum DNSProbe {
    // Only answer this diagnostic A/IN question. Never save other query names.
    static let question: [UInt8] = [8] + Array("a3-probe".utf8)
        + [7] + Array("invalid".utf8) + [0, 0, 1, 0, 1]

    static func response(to query: [UInt8]) -> [UInt8]? {
        guard query.count >= 12 + question.count,
              query[2] & 0xF8 == 0, query[4] == 0, query[5] == 1,
              Array(query[12..<(12 + question.count)]) == question else { return nil }
        let header: [UInt8] = [query[0], query[1], 0x80 | (query[2] & 1), 0,
                               0, 1, 0, 1, 0, 0, 0, 0]
        // Documentation-only address, TTL 0, no recursion or forwarding.
        let answer: [UInt8] = [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 0,
                               0, 4, 192, 0, 2, 123]
        return header + question + answer
    }

    static func save(_ report: DNSProbeReport) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("dns-probe.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    static func run(duration: TimeInterval = 45) -> DNSProbeReport {
        var report = DNSProbeReport(startedAt: ISO8601DateFormatter().string(from: Date()),
                                    phase: "starting", initialInterfaces: NetworkProbe.interfaces(),
                                    detail: "Only a3-probe.invalid is answered. Other packet contents are discarded.")
        let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
        guard descriptor >= 0 else {
            report.phase = "socket-failed"
            report.errorCode = errno
            _ = try? save(report)
            return report
        }
        // No reuse options: determine whether binding before hotspot activation works.
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = UInt16(53).bigEndian
        let status = withUnsafePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if status != 0 {
            report.phase = "bind-failed"
            report.errorCode = errno
            report.detail = String(cString: strerror(errno))
            close(descriptor)
            report.finishedAt = ISO8601DateFormatter().string(from: Date())
            _ = try? save(report)
            return report
        }
        report.phase = "listening"
        _ = try? save(report)
        let end = ProcessInfo.processInfo.systemUptime + min(max(duration, 1), 45)
        while ProcessInfo.processInfo.systemUptime < end {
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorState, 1, 200)
            if ready < 0 {
                if errno == EINTR { continue }
                report.errorCode = errno
                report.detail = "poll failed: " + String(cString: strerror(errno))
                break
            }
            guard ready > 0, descriptorState.revents & Int16(POLLIN) != 0 else { continue }
            var source = sockaddr_storage()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let received = withUnsafeMutablePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(descriptor, &buffer, buffer.count, 0, $0, &sourceLength)
                }
            }
            guard received >= 0 else { continue }
            guard let packet = response(to: Array(buffer.prefix(received))) else {
                report.otherPacketCount += 1
                continue
            }
            report.matchingQueryCount += 1
            let sent = withUnsafePointer(to: &source) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { destination in
                    packet.withUnsafeBytes {
                        sendto(descriptor, $0.baseAddress, packet.count, 0, destination, sourceLength)
                    }
                }
            }
            if sent >= 0 { report.responseBytes = sent }
            else {
                report.errorCode = errno
                report.detail = "sendto failed: " + String(cString: strerror(errno))
            }
            break
        }
        close(descriptor)
        report.phase = report.matchingQueryCount > 0 ? "test-query-received-and-closed" : "timed-out-and-closed"
        report.finishedAt = ISO8601DateFormatter().string(from: Date())
        report.finalInterfaces = NetworkProbe.interfaces()
        _ = try? save(report)
        return report
    }
}
