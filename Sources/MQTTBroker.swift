import Combine
import Foundation
@preconcurrency import Network

public struct ConnectionInfo {
    public let clientID: String
    public let username: String?
    public let password: Data?
    public let keepAliveSeconds: UInt16
}

/// A small foreground-only MQTT 3.1/3.1.1 broker for local A3 experiments.
/// It intentionally has no authentication, persistence, retained messages, or QoS 2.
@MainActor
public final class MQTTBroker: ObservableObject {
    public struct Publication {
        public let clientID: String
        public let topic: String
        public let payload: Data
        public let qos: UInt8
        public let packetIdentifier: UInt16?
        public let retained: Bool
    }

    public enum ClientEvent {
        case connected(clientID: String)
        case disconnected(clientID: String?)
    }

    @Published public private(set) var isRunning = false
    @Published public private(set) var connectionCount = 0
    @Published public private(set) var status = "未启动"

    /// Optional endpoint filter evaluated before a connection is admitted.
    /// When unset, only private, link-local, or loopback IP endpoints are accepted.
    public var allowsConnection: ((NWEndpoint) -> Bool)?

    /// Called for listener failures with a credential-free summary.
    public var onError: ((String) -> Void)?
    /// Called for one client's protocol, timeout, or transport failure; listener stays running.
    public var onClientError: ((String) -> Void)?
    /// Called when the app asks the broker to publish an invalid or oversized packet.
    public var onOperationError: ((String) -> Void)?
    public var onClient: ((ClientEvent) -> Void)?
    /// Called once after a valid CONNECT. Credentials are passed only to this callback.
    public var onConnect: ((ConnectionInfo) -> Void)?
    /// Called after a valid SUBSCRIBE has been installed. QoS grants are always 0.
    public var onSubscription: ((String, [String]) -> Void)?
    /// Called for inbound QoS 0/1 publications. Payloads are not logged or interpreted.
    public var onPublication: ((Publication) -> Void)?

    private let queue = DispatchQueue(label: "cn.sudohg.airwater.mqtt-broker")
    private let port = NWEndpoint.Port(rawValue: 1883)!
    private let maxConnections = 8
    private let maxPacketSize = MQTTStreamDecoder.maximumPacketSize
    private let connectTimeoutSeconds: UInt64 = 12
    private let idleTimeoutSeconds: UInt64 = 180
    private var listener: NWListener?
    private var listenerGeneration = UUID()
    private var clients: [UUID: MQTTClient] = [:]

    public init() {}

    /// Starts listening on TCP 1883. `isRunning` becomes true only after NWListener is ready.
    public func start() throws {
        guard listener == nil else { return }
        do {
            let newListener = try NWListener(using: .tcp, on: port)
            let generation = UUID()
            listenerGeneration = generation
            listener = newListener
            status = "正在启动 MQTT 监听"

            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerGeneration == generation else { return }
                    self.handleListenerState(state)
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    guard let self, self.listenerGeneration == generation else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
            }
            newListener.start(queue: queue)
        } catch {
            listener = nil
            isRunning = false
            status = "MQTT 监听启动失败"
            onError?("MQTT 监听启动失败：\(error.localizedDescription)")
            throw error
        }
    }

    public func stop() {
        listenerGeneration = UUID()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for id in Array(clients.keys) {
            closeClient(id, notify: true)
        }
        isRunning = false
        status = "已停止"
    }

    /// Sends a QoS 0 publication to each connected client with at least one matching filter.
    /// Returns the number of clients for which a send was queued.
    @discardableResult
    public func publish(topic: String, payload: Data) -> Int {
        guard Self.isValidTopicName(topic) else {
            onOperationError?("拒绝发布：Topic 名称无效")
            return 0
        }
        let topicBytes = Array(topic.utf8)
        guard payload.count <= maxPacketSize - topicBytes.count - 8 else {
            onOperationError?("拒绝发布：MQTT 报文超过 64 KiB")
            return 0
        }
        var body = MQTTBytes()
        body.appendUTF8Bytes(topicBytes)
        body.append(contentsOf: Array(payload))
        guard let packet = MQTTWire.encode(type: 3, flags: 0, body: body.bytes), packet.count <= maxPacketSize else {
            onOperationError?("拒绝发布：MQTT 报文超过 64 KiB")
            return 0
        }

        var sentCount = 0
        for client in clients.values where client.isConnected {
            if client.subscriptions.contains(where: { Self.topicMatches(filter: $0, topic: topic) }) {
                send(packet, to: client)
                sentCount += 1
            }
        }
        return sentCount
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            status = "监听中 · TCP 1883 · 客户端 \(connectionCount)"
        case .failed(let error):
            isRunning = false
            status = "MQTT 监听失败"
            onError?("MQTT 监听失败：\(error.localizedDescription)")
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            for id in Array(clients.keys) { closeClient(id, notify: true) }
        case .cancelled:
            isRunning = false
            if listener == nil { status = "已停止" }
        case .waiting(let error):
            isRunning = false
            status = "监听等待：\(error.localizedDescription)"
        case .setup:
            isRunning = false
            status = "正在启动 MQTT 监听"
        @unknown default:
            isRunning = false
            status = "MQTT 监听状态未知"
        }
    }

    private func accept(_ connection: NWConnection) {
        let endpoint = connection.endpoint
        guard isEndpointAllowed(endpoint) else {
            connection.cancel()
            return
        }
        guard clients.count < maxConnections else {
            connection.cancel()
            return
        }

        let client = MQTTClient(connection: connection)
        clients[client.id] = client
        updateConnectionCount()
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let client else { return }
            Task { @MainActor [weak self] in
                guard let self, self.clients[client.id] === client else { return }
                if case .failed = state {
                    self.closeClient(client.id, notify: true)
                }
            }
        }
        connection.start(queue: queue)
        armTimeout(for: client, seconds: connectTimeoutSeconds)
        receiveNext(for: client)
    }

    private func isEndpointAllowed(_ endpoint: NWEndpoint) -> Bool {
        if let allowsConnection { return allowsConnection(endpoint) }
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = Array(address.rawValue)
            guard bytes.count == 4 else { return false }
            return bytes[0] == 10
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 192 && bytes[1] == 168)
                || bytes[0] == 127
                || (bytes[0] == 169 && bytes[1] == 254)
        case .ipv6(let address):
            if address.isLoopback || address.isLinkLocal { return true }
            let bytes = Array(address.rawValue)
            if bytes.count == 16, (bytes[0] & 0xfe) == 0xfc { return true }
            if address.isIPv4Mapped, bytes.count == 16 {
                let v4 = Array(bytes.suffix(4))
                return v4[0] == 10
                    || (v4[0] == 172 && (16...31).contains(v4[1]))
                    || (v4[0] == 192 && v4[1] == 168)
                    || v4[0] == 127
                    || (v4[0] == 169 && v4[1] == 254)
            }
            return false
        case .name:
            return false
        @unknown default:
            return false
        }
    }

    private func receiveNext(for client: MQTTClient) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self, weak client] data, _, isComplete, error in
            guard let client else { return }
            Task { @MainActor [weak self] in
                guard let self, self.clients[client.id] === client else { return }
                if let data, !data.isEmpty {
                    self.armTimeout(for: client, seconds: client.isConnected ? self.clientTimeoutSeconds(client) : self.connectTimeoutSeconds)
                    do {
                        let packets = try client.decoder.append(data)
                        for packet in packets {
                            guard self.clients[client.id] === client else { return }
                            try self.handle(packet, from: client)
                        }
                    } catch {
                        self.failClient(client, message: "收到无效或超限的 MQTT 报文")
                        return
                    }
                }
                if let error {
                    self.failClient(client, message: "MQTT 客户端连接中断：\(error.localizedDescription)")
                } else if isComplete {
                    self.closeClient(client.id, notify: true)
                } else {
                    self.receiveNext(for: client)
                }
            }
        }
    }

    private func handle(_ packet: MQTTPacket, from client: MQTTClient) throws {
        if !client.isConnected {
            guard packet.type == 1 else { throw MQTTBrokerError.protocolViolation }
            try handleConnect(packet, from: client)
            return
        }

        switch packet.type {
        case 3:
            try handlePublish(packet, from: client)
        case 8:
            try handleSubscribe(packet, from: client)
        case 12:
            guard packet.flags == 0, packet.body.isEmpty else { throw MQTTBrokerError.protocolViolation }
            send(MQTTWire.packet(type: 13, flags: 0, body: []), to: client)
        case 14:
            guard packet.flags == 0, packet.body.isEmpty else { throw MQTTBrokerError.protocolViolation }
            closeClient(client.id, notify: true)
        default:
            throw MQTTBrokerError.protocolViolation
        }
    }

    private func handleConnect(_ packet: MQTTPacket, from client: MQTTClient) throws {
        guard packet.flags == 0 else { throw MQTTBrokerError.protocolViolation }
        var cursor = MQTTBytes(packet.body)
        let protocolName = try cursor.readUTF8()
        let level = try cursor.readByte()
        let flags = try cursor.readByte()
        let keepAlive = try cursor.readUInt16()
        let version: MQTTVersion
        if protocolName == "MQTT", level == 4 {
            version = .v311
        } else if protocolName == "MQIsdp", level == 3 {
            version = .v31
        } else {
            send(MQTTWire.packet(type: 2, flags: 0, body: [0, 1]), to: client)
            throw MQTTBrokerError.unsupportedVersion
        }

        let cleanSession = (flags & 0x02) != 0
        let willFlag = (flags & 0x04) != 0
        let willQoS = (flags >> 3) & 0x03
        let willRetain = (flags & 0x20) != 0
        let passwordFlag = (flags & 0x40) != 0
        let usernameFlag = (flags & 0x80) != 0
        guard (flags & 0x01) == 0,
              !(passwordFlag && !usernameFlag),
              (willFlag || (willQoS == 0 && !willRetain)),
              willQoS <= 2 else {
            send(MQTTWire.packet(type: 2, flags: 0, body: [0, 1]), to: client)
            throw MQTTBrokerError.protocolViolation
        }

        var clientID = try cursor.readUTF8()
        if clientID.isEmpty {
            guard version == .v311, cleanSession else {
                send(MQTTWire.packet(type: 2, flags: 0, body: [0, 2]), to: client)
                throw MQTTBrokerError.protocolViolation
            }
            clientID = "anonymous-\(client.id.uuidString)"
        }
        if willFlag {
            _ = try cursor.readUTF8() // Will Topic
            _ = try cursor.readBinary() // Will Message
        }
        let username = usernameFlag ? try cursor.readUTF8() : nil
        let password = passwordFlag ? Data(try cursor.readBinary()) : nil
        guard cursor.isAtEnd else { throw MQTTBrokerError.protocolViolation }

        // MQTT 3.1 and 3.1.1 both use a two-byte CONNACK body; this broker starts clean.
        send(MQTTWire.packet(type: 2, flags: 0, body: [0, 0]), to: client)
        for existing in clients.values where existing !== client && existing.isConnected && existing.clientID == clientID {
            closeClient(existing.id, notify: true)
        }
        client.clientID = clientID
        client.version = version
        client.keepAliveSeconds = keepAlive
        client.isConnected = true
        client.subscriptions.removeAll(keepingCapacity: true)
        onClient?(.connected(clientID: clientID))
        onConnect?(ConnectionInfo(
            clientID: clientID,
            username: username,
            password: password,
            keepAliveSeconds: keepAlive
        ))
        armTimeout(for: client, seconds: clientTimeoutSeconds(client))
        status = isRunning ? "监听中 · TCP 1883 · 客户端 \(connectionCount)" : status
    }

    private func handleSubscribe(_ packet: MQTTPacket, from client: MQTTClient) throws {
        guard packet.flags == 2 else { throw MQTTBrokerError.protocolViolation }
        var cursor = MQTTBytes(packet.body)
        let packetID = try cursor.readUInt16()
        guard packetID != 0 else { throw MQTTBrokerError.protocolViolation }

        var filters: [(String, UInt8)] = []
        while !cursor.isAtEnd {
            let filter = try cursor.readUTF8()
            let requestedQoS = try cursor.readByte()
            filters.append((filter, requestedQoS))
        }
        guard !filters.isEmpty else { throw MQTTBrokerError.protocolViolation }

        var grants: [UInt8] = []
        var acceptedFilters: [String] = []
        for (filter, requestedQoS) in filters {
            if requestedQoS <= 2, Self.isValidTopicFilter(filter) {
                grants.append(0)
                acceptedFilters.append(filter)
                client.subscriptions.insert(filter)
            } else {
                grants.append(0x80)
            }
        }
        var body = MQTTBytes()
        body.appendUInt16(packetID)
        body.append(contentsOf: grants)
        send(MQTTWire.packet(type: 9, flags: 0, body: body.bytes), to: client)
        if !acceptedFilters.isEmpty {
            onSubscription?(client.clientID, acceptedFilters)
        }
    }

    private func handlePublish(_ packet: MQTTPacket, from client: MQTTClient) throws {
        let qos = (packet.flags >> 1) & 0x03
        let duplicate = (packet.flags & 0x08) != 0
        let retained = (packet.flags & 0x01) != 0
        guard qos != 2, qos != 3, !(qos == 0 && duplicate) else {
            throw MQTTBrokerError.protocolViolation
        }

        var cursor = MQTTBytes(packet.body)
        let topic = try cursor.readUTF8()
        guard Self.isValidTopicName(topic) else { throw MQTTBrokerError.protocolViolation }
        let packetID: UInt16?
        if qos == 1 {
            let identifier = try cursor.readUInt16()
            guard identifier != 0 else { throw MQTTBrokerError.protocolViolation }
            packetID = identifier
        } else {
            packetID = nil
        }
        let payload = Data(cursor.remainingBytes)

        let isDuplicateQoS1 = qos == 1 && duplicate && client.recentQoS1PacketIDs.contains(packetID!)
        if !isDuplicateQoS1 {
            onPublication?(Publication(
                clientID: client.clientID,
                topic: topic,
                payload: payload,
                qos: qos,
                packetIdentifier: packetID,
                retained: retained
            ))
            if let packetID, qos == 1 {
                client.recentQoS1PacketIDs.insert(packetID)
                client.recentQoS1Order.append(packetID)
                if client.recentQoS1Order.count > 256 {
                    let expired = client.recentQoS1Order.removeFirst()
                    client.recentQoS1PacketIDs.remove(expired)
                }
            }
        }
        if let packetID, qos == 1 {
            send(MQTTWire.packet(type: 4, flags: 0, body: MQTTWire.uint16(packetID)), to: client)
        }
    }

    private func armTimeout(for client: MQTTClient, seconds: UInt64) {
        client.timeoutTask?.cancel()
        client.timeoutTask = Task { @MainActor [weak self, weak client] in
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            guard let self, let client, self.clients[client.id] === client else { return }
            self.failClient(client, message: client.isConnected ? "MQTT 客户端空闲超时" : "等待 MQTT CONNECT 超时")
        }
    }

    private func clientTimeoutSeconds(_ client: MQTTClient) -> UInt64 {
        guard client.keepAliveSeconds > 0 else { return idleTimeoutSeconds }
        return max(1, UInt64(client.keepAliveSeconds) * 3 / 2)
    }

    private func send(_ data: Data, to client: MQTTClient) {
        guard data.count <= maxPacketSize else { return }
        client.connection.send(content: data, completion: .contentProcessed { [weak self, weak client] error in
            guard let error, let client else { return }
            Task { @MainActor [weak self] in
                guard let self, self.clients[client.id] === client else { return }
                self.failClient(client, message: "发送 MQTT 响应失败：\(error.localizedDescription)")
            }
        })
    }

    private func failClient(_ client: MQTTClient, message: String) {
        onClientError?(message)
        closeClient(client.id, notify: true)
    }

    private func closeClient(_ id: UUID, notify: Bool) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.timeoutTask?.cancel()
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        updateConnectionCount()
        if notify, client.isConnected {
            onClient?(.disconnected(clientID: client.clientID))
        }
    }

    private func updateConnectionCount() {
        connectionCount = clients.count
        if isRunning { status = "监听中 · TCP 1883 · 客户端 \(connectionCount)" }
    }

    private static func isValidTopicName(_ topic: String) -> Bool {
        !topic.isEmpty && topic.utf8.count <= 65_535 && !topic.utf8.contains(0) && !topic.contains("+") && !topic.contains("#")
    }

    private static func isValidTopicFilter(_ filter: String) -> Bool {
        guard !filter.isEmpty, !filter.utf8.contains(0) else { return false }
        let levels = filter.split(separator: "/", omittingEmptySubsequences: false)
        for (index, level) in levels.enumerated() {
            if level == "#" {
                return index == levels.count - 1
            }
            if level.contains("#") { return false }
            if level.contains("+"), level != "+" { return false }
        }
        return true
    }

    nonisolated static func topicMatches(filter: String, topic: String) -> Bool {
        if topic.hasPrefix("$"), filter.first == "#" || filter.first == "+" {
            return false
        }
        let filterLevels = filter.split(separator: "/", omittingEmptySubsequences: false)
        let topicLevels = topic.split(separator: "/", omittingEmptySubsequences: false)
        var index = 0
        while index < filterLevels.count {
            let filterLevel = filterLevels[index]
            if filterLevel == "#" { return true }
            guard index < topicLevels.count else { return false }
            if filterLevel != "+", filterLevel != topicLevels[index] { return false }
            index += 1
        }
        return index == topicLevels.count
    }
}

/// Access to mutable fields is serialized on MQTTBroker's main actor.
private final class MQTTClient: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    var decoder = MQTTStreamDecoder()
    var isConnected = false
    var clientID = ""
    var version: MQTTVersion?
    var keepAliveSeconds: UInt16 = 0
    var subscriptions = Set<String>()
    var recentQoS1PacketIDs = Set<UInt16>()
    var recentQoS1Order: [UInt16] = []
    var timeoutTask: Task<Void, Never>?

    init(connection: NWConnection) { self.connection = connection }
}

private enum MQTTVersion {
    case v31
    case v311
}

private enum MQTTBrokerError: Error {
    case protocolViolation
    case unsupportedVersion
}

struct MQTTPacket {
    let type: UInt8
    let flags: UInt8
    let body: [UInt8]
}

/// Pure stream framing parser, kept independent of Network so its edge cases can be tested offline.
struct MQTTStreamDecoder {
    static let maximumPacketSize = 65_536
    static let maximumBufferedBytes = maximumPacketSize + 16_384
    private(set) var buffer: [UInt8] = []

    mutating func append(_ data: Data) throws -> [MQTTPacket] {
        let input = Array(data)
        var output: [MQTTPacket] = []
        var offset = 0
        while offset < input.count {
            let end = min(offset + 16_384, input.count)
            let nextChunk = input[offset..<end]
            guard buffer.count + nextChunk.count <= Self.maximumBufferedBytes else {
                throw MQTTDecoderError.bufferLimitExceeded
            }
            buffer.append(contentsOf: nextChunk)
            offset = end
            try drain(into: &output)
        }
        return output
    }

    private mutating func drain(into output: inout [MQTTPacket]) throws {
        while buffer.count >= 2 {
            var multiplier = 1
            var remainingLength = 0
            var encodedLengthBytes = 0
            var hasTerminator = false
            for offset in 1...min(4, buffer.count - 1) {
                let byte = buffer[offset]
                encodedLengthBytes += 1
                remainingLength += Int(byte & 0x7f) * multiplier
                if byte & 0x80 == 0 {
                    hasTerminator = true
                    if encodedLengthBytes > 1 {
                        let minimum = 1 << (7 * (encodedLengthBytes - 1))
                        guard remainingLength >= minimum else { throw MQTTDecoderError.malformedRemainingLength }
                    }
                    break
                }
                if encodedLengthBytes == 4 { throw MQTTDecoderError.malformedRemainingLength }
                multiplier *= 128
            }
            guard hasTerminator else { return }
            let totalLength = 1 + encodedLengthBytes + remainingLength
            guard totalLength <= Self.maximumPacketSize else { throw MQTTDecoderError.packetTooLarge }
            guard buffer.count >= totalLength else { return }
            let firstByte = buffer[0]
            let bodyStart = 1 + encodedLengthBytes
            let body = Array(buffer[bodyStart..<totalLength])
            output.append(MQTTPacket(type: firstByte >> 4, flags: firstByte & 0x0f, body: body))
            buffer.removeFirst(totalLength)
        }
    }
}

private enum MQTTDecoderError: Error {
    case malformedRemainingLength
    case packetTooLarge
    case bufferLimitExceeded
}

private struct MQTTBytes {
    private(set) var bytes: [UInt8]
    private(set) var offset = 0

    init(_ bytes: [UInt8] = []) { self.bytes = bytes }

    var isAtEnd: Bool { offset == bytes.count }
    var remainingBytes: [UInt8] { Array(bytes[offset...]) }

    mutating func append(contentsOf value: [UInt8]) { bytes.append(contentsOf: value) }
    mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xff))
    }
    mutating func appendUTF8Bytes(_ value: [UInt8]) {
        appendUInt16(UInt16(value.count))
        bytes.append(contentsOf: value)
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else { throw MQTTBrokerError.protocolViolation }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readByte())
        let low = UInt16(try readByte())
        return high << 8 | low
    }

    mutating func readBinary() throws -> [UInt8] {
        let length = Int(try readUInt16())
        guard length <= bytes.count - offset else { throw MQTTBrokerError.protocolViolation }
        let value = Array(bytes[offset..<(offset + length)])
        offset += length
        return value
    }

    mutating func readUTF8() throws -> String {
        let value = try readBinary()
        guard !value.contains(0), let string = String(bytes: value, encoding: .utf8) else {
            throw MQTTBrokerError.protocolViolation
        }
        return string
    }
}

private enum MQTTWire {
    static func packet(type: UInt8, flags: UInt8, body: [UInt8]) -> Data {
        encode(type: type, flags: flags, body: body) ?? Data()
    }

    static func encode(type: UInt8, flags: UInt8, body: [UInt8]) -> Data? {
        guard type > 0, type < 16, flags < 16 else { return nil }
        var bytes: [UInt8] = [(type << 4) | flags]
        var value = body.count
        repeat {
            var digit = UInt8(value % 128)
            value /= 128
            if value > 0 { digit |= 0x80 }
            bytes.append(digit)
        } while value > 0
        bytes.append(contentsOf: body)
        return Data(bytes)
    }

    static func uint16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xff)]
    }
}
