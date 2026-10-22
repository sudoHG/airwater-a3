import Foundation
import Network

struct LocalHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
}

struct LocalHTTPResponse {
    let status: Int
    let contentType: String
    let body: Data

    static func json(_ value: [String: Any], status: Int = 200) -> LocalHTTPResponse {
        LocalHTTPResponse(status: status, contentType: "application/json; charset=utf-8",
                          body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8))
    }

    var bytes: Data {
        let reason = status == 200 ? "OK" : "Error"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        return Data(headers.utf8) + body
    }
}

@MainActor
final class HTTPServer {
    private struct Client {
        let connection: NWConnection
        let generation: UUID
        var bytes = Data()
    }
    private var listener: NWListener?
    private var generation = UUID()
    private var clients: [UUID: Client] = [:]
    private(set) var isReady = false
    var onRequest: ((LocalHTTPRequest) -> LocalHTTPResponse)?
    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?
    var allowsConnection: ((NWEndpoint) -> Bool)?

    func start() throws {
        guard listener == nil else { return }
        let listener = try NWListener(using: .tcp, on: 80)
        let generation = UUID()
        self.generation = generation
        isReady = false
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                switch state {
                case .ready:
                    self.isReady = true
                    self.onReady?()
                case .failed(let error): self.fail(generation: generation, detail: error.localizedDescription)
                case .waiting:
                    self.isReady = false
                case .cancelled:
                    self.fail(generation: generation, detail: "HTTP 监听被系统取消")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection, generation: generation) }
        }
        listener.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        isReady = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
    }

    private func fail(generation: UUID, detail: String) {
        guard self.generation == generation else { return }
        self.generation = UUID()
        isReady = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        onError?(detail)
    }

    private func accept(_ connection: NWConnection, generation: UUID) {
        guard self.generation == generation, isReady, listener != nil, clients.count < 8,
              allowsConnection?(connection.endpoint) ?? false else { connection.cancel(); return }
        let id = UUID()
        clients[id] = Client(connection: connection, generation: generation)
        connection.start(queue: .main)
        receive(id, generation: generation)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            self?.close(id, generation: generation)
        }
    }

    private func close(_ id: UUID, generation: UUID) {
        guard clients[id]?.generation == generation else { return }
        clients.removeValue(forKey: id)?.connection.cancel()
    }

    private func receive(_ id: UUID, generation: UUID) {
        guard self.generation == generation, let client = clients[id], client.generation == generation else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation,
                      var client = self.clients[id], client.generation == generation else { return }
                if let data { client.bytes.append(data) }
                guard client.bytes.count <= 32768 else { self.close(id, generation: generation); return }
                self.clients[id] = client
                do {
                    if let request = try Self.parse(client.bytes) {
                        let response = self.onRequest?(request) ?? .json(["error": "not found"], status: 404)
                        client.connection.send(content: response.bytes, completion: .contentProcessed { [weak self] _ in
                            Task { @MainActor [weak self] in self?.close(id, generation: generation) }
                        })
                        return
                    }
                } catch { self.close(id, generation: generation); return }
                if error != nil || complete { self.close(id, generation: generation) }
                else { self.receive(id, generation: generation) }
            }
        }
    }

    enum ParseError: Error { case invalid }

    nonisolated static func parse(_ data: Data) throws -> LocalHTTPRequest? {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { throw ParseError.invalid }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = (lines.first ?? "").split(separator: " ")
        guard requestLine.count == 3, ["GET", "POST"].contains(String(requestLine[0])),
              requestLine[1].first == "/", requestLine[2].hasPrefix("HTTP/1.") else { throw ParseError.invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.invalid }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { throw ParseError.invalid }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? "0"), length >= 0, length <= 16384 else { throw ParseError.invalid }
        let end = split.upperBound + length
        guard data.count >= end else { return nil }
        return LocalHTTPRequest(method: String(requestLine[0]), target: String(requestLine[1]),
                                headers: headers, body: Data(data[split.upperBound..<end]))
    }
}
