import Darwin
import Foundation

/// Foreground research server, for a hotspot dedicated to the user's A3.
/// It does not forward or record unrelated DNS names.
@MainActor
final class LocalDNSServer {
    private var source: DispatchSourceRead?
    private var generation = UUID()
    private var closingGeneration: UUID?
    private var closeInProgress = false
    private var closeWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    var onQuery: ((String, Bool) -> Void)?

    var isReady: Bool { source != nil && !closeInProgress }

    func start(retryUntil deadline: Date) async throws {
        try await waitForPreviousClose(until: deadline)
        try Task.checkCancellation()
        guard source == nil else { return }
        while true {
            try Task.checkCancellation()
            let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            guard descriptor >= 0 else { throw Self.posixError() }
            var endpoint = sockaddr_in()
            endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            endpoint.sin_family = sa_family_t(AF_INET)
            endpoint.sin_port = UInt16(53).bigEndian
            let bound = withUnsafePointer(to: &endpoint) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else {
                let error = Self.posixError()
                close(descriptor)
                guard error.code == Int(EADDRINUSE), Date() < deadline else { throw error }
                try await Task.sleep(nanoseconds: 150_000_000)
                try await waitForPreviousClose(until: deadline)
                continue
            }
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
            installReader(descriptor)
            return
        }
    }

    private func installReader(_ descriptor: Int32) {
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                                  queue: DispatchQueue(label: "a3.dns"))
        let generation = UUID()
        self.generation = generation
        reader.setEventHandler { [weak self] in
            // Bound the work per event as well as the packet size.
            for _ in 0..<32 {
                var peer = sockaddr_storage()
                var peerSize = socklen_t(MemoryLayout<sockaddr_storage>.size)
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(descriptor, &bytes, bytes.count, 0, $0, &peerSize)
                    }
                }
                guard count >= 0 else { break }
                var peerText = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let addressStatus = withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, peerSize, &peerText, socklen_t(peerText.count), nil, 0, NI_NUMERICHOST)
                    }
                }
                guard addressStatus == 0, NetworkProbe.hotspotContains(String(cString: peerText)) else { continue }
                let hotspotAddress = NetworkProbe.interfaces()
                    .first { $0.name.hasPrefix("bridge") || $0.name.hasPrefix("ap") }?.address
                guard let reply = Self.answer(Array(bytes.prefix(count)), address: hotspotAddress) else { continue }
                _ = withUnsafePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { target in
                        reply.bytes.withUnsafeBytes {
                            sendto(descriptor, $0.baseAddress, reply.bytes.count, 0, target, peerSize)
                        }
                    }
                }
                if let allowedName = reply.loggedName {
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == generation else { return }
                        self.onQuery?(allowedName, reply.hasAddress)
                    }
                }
            }
        }
        reader.setCancelHandler { [weak self] in
            close(descriptor)
            Task { @MainActor [weak self] in self?.didClose(generation: generation) }
        }
        source = reader
        reader.resume()
    }

    func stop() {
        guard let source else { return }
        self.source = nil
        closingGeneration = generation
        generation = UUID()
        closeInProgress = true
        source.setEventHandler {}
        source.cancel()
    }

    private func waitForPreviousClose(until deadline: Date) async throws {
        guard closeInProgress else { return }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw LifecycleError.closeTimedOut }
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                try await self.waitForClose()
                return true
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                return false
            }
            guard let finished = try await group.next() else { throw LifecycleError.closeTimedOut }
            group.cancelAll()
            guard finished else { throw LifecycleError.closeTimedOut }
        }
    }

    private func waitForClose() async throws {
        guard closeInProgress else { return }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if closeInProgress {
                    closeWaiters[waiterID] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelCloseWaiter(waiterID) }
        }
    }

    private func cancelCloseWaiter(_ id: UUID) {
        closeWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func didClose(generation: UUID) {
        guard closingGeneration == generation else { return }
        closingGeneration = nil
        closeInProgress = false
        let waiters = Array(closeWaiters.values)
        closeWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private enum LifecycleError: LocalizedError {
        case closeTimedOut
        var errorDescription: String? { "DNS 端口仍被占用，等待释放超时" }
    }

    nonisolated static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    struct Reply {
        let bytes: [UInt8]
        let loggedName: String?
        let hasAddress: Bool
    }

    nonisolated static func answer(_ query: [UInt8], address: String?) -> Reply? {
        guard query.count >= 12, query[2] & 0xF8 == 0,
              query[4] == 0, query[5] == 1 else { return nil }
        var cursor = 12
        var labels: [String] = []
        while cursor < query.count {
            let length = Int(query[cursor])
            cursor += 1
            if length == 0 { break }
            // Compressed or malformed questions are ignored; never follow pointers.
            guard length <= 63, cursor + length < query.count,
                  let label = String(bytes: query[cursor..<(cursor + length)], encoding: .ascii) else { return nil }
            labels.append(label)
            cursor += length
            guard cursor - 12 <= 253 else { return nil }
        }
        guard cursor > 12, query[cursor - 1] == 0, cursor + 4 <= query.count else { return nil }
        let type = UInt16(query[cursor]) << 8 | UInt16(query[cursor + 1])
        let internetClass = query[cursor + 2] == 0 && query[cursor + 3] == 1
        let question = Array(query[12..<(cursor + 4)])
        let name = labels.joined(separator: ".").lowercased()
        let known = ["i.airmx.cn", "awm.airmx.cn", "a3-probe.invalid"].contains(name)
        let octets = address?.split(separator: ".").compactMap { UInt8($0) } ?? []
        let hasAddress = known && internetClass && type == 1 && octets.count == 4
        // REFUSED for unrelated domains, SERVFAIL while hotspot is not ready,
        // NOERROR/NODATA for a known name's unsupported RR type.
        let rcode: UInt8 = !known || !internetClass ? 5 : (octets.count != 4 ? 2 : 0)
        var response: [UInt8] = [query[0], query[1], 0x80 | (query[2] & 1), rcode,
                                  0, 1, 0, hasAddress ? 1 : 0, 0, 0, 0, 0]
        response += question
        if hasAddress {
            // Give the firmware resolver time to consume the cached result.
            response += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 30, 0, 4] + octets
        }
        return Reply(bytes: response, loggedName: known ? name : nil, hasAddress: hasAddress)
    }
}
