import Combine
import CryptoKit
import Foundation
import Network
import UIKit

@MainActor
final class A3LocalSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "等待开始"
    @Published private(set) var localError: String?
    @Published private(set) var events: [String] = []
    @Published private(set) var report: [String: Int] = [:]
    @Published private(set) var connectedClients = 0
    @Published private(set) var registeredType: Int?
    @Published private(set) var commandStatus = ""
    @Published private(set) var reportSignatureVerified = false
    @Published private(set) var canRequestStatus = false
    @Published private(set) var isSendingControl = false
    @Published private(set) var settingsReport: [String: Int] = [:]
    private let dns = LocalDNSServer()
    private let http = HTTPServer()
    private let mqtt = MQTTBroker()
    private var connectionID: UUID?
    private var preparationOperationID: UUID?
    private var preparationTask: Task<UUID, Error>?
    private var expiry: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var identity: (id: Int, key: String)?
    private var pendingControl: [String: Int]?
    private var commandTimeout: Task<Void, Never>?
    private var dnsQueries = 0
    private var httpRequests = 0
    private var subscriptions = 0
    // CONNECT credentials stay in memory until a matching report proves the key.
    private var candidateKeys: [String: String] = [:]
    private var candidateDeviceIDs: [String: Int] = [:]
    private var observedClientID: String?
    private var observedDeviceID: Int?
    private var connectedClientIDs = Set<String>()
    private var subscribedClientIDs = Set<String>()
    private var verifiedReportConnectionID: UUID?
    private var verifiedReportClientID: String?
    private var verifiedReportAt: Date?
    private var lastStatusRequests: [String: Date] = [:]
    private var statusPolling: Task<Void, Never>?
    private var interfaceObservation: Task<Void, Never>?
    private var hotspotInterfaceHistory: [[String: Any]] = []
    private var powerCheck: Task<Void, Never>?
    private var powerCheckStarted = false
    private var cancellables = Set<AnyCancellable>()

    var canControl: Bool {
        guard let clientID = observedClientID, let deviceID = observedDeviceID else { return false }
        return isRunning && identity?.id == deviceID && report["power"] != nil && reportSignatureVerified
            && verifiedReportConnectionID == connectionID && verifiedReportClientID == clientID
            && connectedClientIDs.contains(clientID) && subscribedClientIDs.contains(clientID)
    }
    var canAdjustOperation: Bool { canControl && report["mode"] != 5 && !isSendingControl }
    nonisolated static let settingFields = ["hThreshold", "powerHeat", "pirLock", "strongModeThreshold", "autoShakeEnable",
                                           "fanTimer", "fanStart", "fanStop", "fanRepeat", "silentTimer", "silentStart", "silentStop", "silentRepeat",
                                           "clearTimer", "clearStart", "clearStop", "clearRepeat", "cleanNotify", "reportInterval", "logLevel",
                                           "electrolysis", "electrolysisLevel", "nightLight"]

    init() {
        if let saved = DeviceKeyStore.load() {
            identity = (saved.id, saved.key)
            registeredType = saved.type >= 0 ? saved.type : nil
        }
        dns.onQuery = { [weak self] name, answered in
            guard let self else { return }
            self.dnsQueries += 1
            self.event("DNS \(name)：\(answered ? "已回复手机地址" : "等待热点接口")")
        }
        http.allowsConnection = Self.isHotspotPeer
        mqtt.allowsConnection = Self.isHotspotPeer
        http.onRequest = { [weak self] request in
            self?.handleHTTP(request) ?? .json(["error": "stopped"], status: 503)
        }
        http.onReady = { [weak self] in self?.event("HTTP 服务已监听") }
        http.onError = { [weak self] error in self?.fail("HTTP 服务失败：\(error)") }
        mqtt.onError = { [weak self] error in self?.fail("消息服务失败：\(error)") }
        mqtt.onClientError = { [weak self] error in self?.event("单个消息连接异常：\(error)") }
        mqtt.onOperationError = { [weak self] error in self?.commandStatus = error }
        mqtt.onConnect = { [weak self] info in
            guard let self else { return }
            if let username = info.username, let id = Self.deviceID(in: username, prefix: "aw_") {
                self.candidateDeviceIDs[info.clientID] = id
            }
            if let data = info.password, !data.isEmpty, data.count <= 256,
               let key = String(data: data, encoding: .utf8) {
                self.candidateKeys[info.clientID] = key
            }
            let usernameKind = info.username?.hasPrefix("aw_") == true ? "aw_ 前缀" : (info.username == nil ? "无" : "其他格式")
            self.event("MQTT 连接信息：用户名\(usernameKind)，密码长度 \(info.password?.count ?? 0)，心跳 \(info.keepAliveSeconds) 秒；未记录凭据")
        }
        mqtt.onClient = { [weak self] event in
            guard let self else { return }
            switch event {
            case .connected(let clientID):
                self.connectedClientIDs.insert(clientID)
                self.event("收到 MQTT 连接")
            case .disconnected(let clientID):
                if let clientID {
                    self.connectedClientIDs.remove(clientID)
                    self.subscribedClientIDs.remove(clientID)
                    self.candidateKeys.removeValue(forKey: clientID)
                    self.candidateDeviceIDs.removeValue(forKey: clientID)
                    self.lastStatusRequests.removeValue(forKey: clientID)
                    if self.observedClientID == clientID {
                        self.observedClientID = nil
                        self.observedDeviceID = nil
                        self.canRequestStatus = false
                        self.verifiedReportConnectionID = nil
                        self.verifiedReportClientID = nil
                        self.verifiedReportAt = nil
                    }
                }
                self.event("MQTT 客户端已断开")
            }
        }
        mqtt.onSubscription = { [weak self] clientID, filters in
            guard let self else { return }
            self.subscriptions += filters.count
            self.event("收到 \(filters.count) 个消息订阅")
            for filter in filters {
                self.event("设备订阅：\(Self.redactedTopic(filter))")
                let usernameID = self.candidateDeviceIDs[clientID].flatMap { id in
                    MQTTBroker.topicMatches(filter: filter, topic: "airwater/01/1/0/1/\(id)") ? id : nil
                }
                if let id = Self.deviceID(in: filter, prefix: "airwater/01/1/0/1/") ?? usernameID {
                    self.subscribedClientIDs.insert(clientID)
                    if self.observedClientID != clientID || self.observedDeviceID != id {
                        self.report = [:]
                        self.settingsReport = [:]
                        self.reportSignatureVerified = false
                        self.verifiedReportConnectionID = nil
                        self.verifiedReportClientID = nil
                        self.verifiedReportAt = nil
                    }
                    self.observedClientID = clientID
                    self.observedDeviceID = id
                    self.canRequestStatus = self.candidateKeys[clientID] != nil || self.identity?.id == id
                    self.status = "加湿器已连接，等待读取真实状态"
                    self.event("订阅格式 airwater/01/1/0/1/<设备>，已有设备 ID；联网已确认")
                    self.requestStatus()
                } else {
                    self.event("订阅格式尚未匹配已知 A3 控制主题（\(filter.split(separator: "/").count) 层）；未记录标识")
                }
            }
        }
        mqtt.onPublication = { [weak self] publication in
            self?.receive(clientID: publication.clientID, topic: publication.topic, payload: publication.payload)
        }
        mqtt.$connectionCount.sink { [weak self] count in self?.connectedClients = count }.store(in: &cancellables)
        mqtt.$status.removeDuplicates().sink { [weak self] status in
            self?.event("消息服务：\(status)")
        }.store(in: &cancellables)
    }

    func start(duration: TimeInterval = 600) {
        guard !isRunning, preparationTask == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await self.prepareConnection(timeout: 12, duration: duration)
            } catch is CancellationError {
                // An explicit stop already reports why the current run ended.
            } catch { /* The preparation path records the failure on its own ticket. */ }
        }
    }

    func prepareConnection(timeout: TimeInterval = 12) async throws -> UUID {
        try Task.checkCancellation()
        return try await prepareConnection(timeout: timeout, duration: 600)
    }

    private func prepareConnection(timeout: TimeInterval, duration: TimeInterval) async throws -> UUID {
        try Task.checkCancellation()
        if isRunning, let connectionID {
            invalidateDeviceStateForFreshWait()
            requestStatus()
            return connectionID
        }

        let timeoutSeconds = timeout.isFinite ? max(0, timeout) : 12
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        let operationID: UUID
        let task: Task<UUID, Error>
        if let preparationTask, let activeOperationID = preparationOperationID {
            operationID = activeOperationID
            task = preparationTask
        } else {
            resetForNewConnection()
            let ticket = UUID()
            operationID = UUID()
            connectionID = ticket
            preparationOperationID = operationID
            isStarting = true
            status = "正在准备本地服务"
            UIApplication.shared.isIdleTimerDisabled = true
            observeHotspotInterfaces(for: ticket)

            task = Task { @MainActor [weak self] in
                guard let self else { throw CancellationError() }
                do {
                    try await self.runPreparation(ticket: ticket, operationID: operationID,
                                                  deadline: deadline, duration: duration)
                    return ticket
                } catch {
                    self.abortPreparation(ticket: ticket, operationID: operationID, error: error)
                    throw error
                }
            }
            preparationTask = task
        }

        return try await awaitPreparation(task, operationID: operationID)
    }

    func waitForDevice(connectionID ticket: UUID, timeout: TimeInterval = 45) async throws {
        guard connectionID == ticket, isRunning else { throw ConnectionFailure.invalidTicket }
        let seconds = timeout.isFinite ? max(0, timeout) : 45
        let deadline = Date().addingTimeInterval(seconds)
        do {
            while true {
                try Task.checkCancellation()
                guard connectionID == ticket else {
                    if let localError { throw ConnectionFailure.service(localError) }
                    throw CancellationError()
                }
                guard dns.isReady, http.isReady, mqtt.isRunning else {
                    throw ConnectionFailure.servicesUnavailable
                }
                if hasFreshVerifiedDevice(for: ticket) { return }
                guard Date() < deadline else { throw ConnectionFailure.timedOut("等待 A3 连接超时") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } catch {
            if connectionID == ticket {
                let cancellation = error is CancellationError
                let reason = cancellation ? "连接等待已取消，本地服务已关闭" : error.localizedDescription
                stopInternal(reason: reason, errorMessage: cancellation ? nil : error.localizedDescription,
                             expectedConnectionID: ticket, cancelPreparation: false)
            }
            throw error
        }
    }

    func stop(reason: String = "服务已关闭，请关闭个人热点") {
        stopInternal(reason: reason, errorMessage: nil, expectedConnectionID: nil, cancelPreparation: true)
    }

    func enteredBackground() {
        guard (isStarting || isRunning), let connectionID else { return }
        beginBackgroundTime(for: connectionID)
    }

    func becameActive() { endBackgroundTime() }

    func recordBluetooth(status: String) {
        // Bluetooth status strings never include Wi-Fi credentials or frames.
        event("蓝牙：\(status)")
    }

    private func endBackgroundTime() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func fail(_ detail: String) {
        guard let ticket = connectionID else { return }
        stopInternal(reason: detail, errorMessage: detail, expectedConnectionID: ticket, cancelPreparation: false)
    }

    private enum ConnectionFailure: LocalizedError {
        case invalidTicket
        case servicesUnavailable
        case timedOut(String)
        case service(String)

        var errorDescription: String? {
            switch self {
            case .invalidTicket: return "连接准备已失效，请重新运行「连接 A3」。"
            case .servicesUnavailable: return "本地服务已中断，请重新运行「连接 A3」。"
            case .timedOut(let message): return message
            case .service(let message): return message
            }
        }
    }

    private func resetForNewConnection() {
        events = []
        isRunning = false
        isStarting = false
        preparationTask = nil
        preparationOperationID = nil
        localError = nil
        report = [:]
        reportSignatureVerified = false
        pendingControl = nil
        isSendingControl = false
        settingsReport = [:]
        commandStatus = ""
        dnsQueries = 0
        httpRequests = 0
        subscriptions = 0
        candidateKeys = [:]
        candidateDeviceIDs = [:]
        observedClientID = nil
        observedDeviceID = nil
        connectedClientIDs = []
        subscribedClientIDs = []
        verifiedReportConnectionID = nil
        verifiedReportClientID = nil
        verifiedReportAt = nil
        lastStatusRequests = [:]
        powerCheckStarted = false
        canRequestStatus = false
        hotspotInterfaceHistory = []
    }

    private func runPreparation(ticket: UUID, operationID: UUID, deadline: Date,
                                duration: TimeInterval) async throws {
        try Task.checkCancellation()
        guard connectionID == ticket, preparationOperationID == operationID else { throw CancellationError() }
        let dnsDeadline = min(deadline, Date().addingTimeInterval(2))
        try await dns.start(retryUntil: dnsDeadline)
        try Task.checkCancellation()
        guard connectionID == ticket else { throw CancellationError() }
        try http.start()
        try mqtt.start()
        try await waitForLocalServices(ticket: ticket, deadline: deadline)
        guard connectionID == ticket else { throw CancellationError() }

        isStarting = false
        isRunning = true
        status = "本地服务已就绪，请开启个人热点并等待 A3 连接"
        event("本地 DNS、HTTP、MQTT 服务均已就绪")
        scheduleExpiry(for: ticket, duration: duration)
        requestStatus()
        if preparationOperationID == operationID {
            preparationOperationID = nil
            preparationTask = nil
        }
    }

    private func waitForLocalServices(ticket: UUID, deadline: Date) async throws {
        while true {
            if let localError { throw ConnectionFailure.service(localError) }
            try Task.checkCancellation()
            guard connectionID == ticket else { throw CancellationError() }
            guard Date() < deadline else { throw ConnectionFailure.timedOut("本地服务启动超时，请关闭热点后重试。") }
            if dns.isReady, http.isReady, mqtt.isRunning { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func invalidateDeviceStateForFreshWait() {
        report = [:]
        settingsReport = [:]
        reportSignatureVerified = false
        verifiedReportConnectionID = nil
        verifiedReportClientID = nil
        verifiedReportAt = nil
        status = "本地服务已就绪，正在刷新 A3 状态"
        if let observedClientID { lastStatusRequests.removeValue(forKey: observedClientID) }
    }

    private func hasFreshVerifiedDevice(for ticket: UUID) -> Bool {
        guard isRunning, reportSignatureVerified, report["power"] != nil,
              verifiedReportConnectionID == ticket,
              let clientID = verifiedReportClientID,
              clientID == observedClientID,
              connectedClientIDs.contains(clientID), subscribedClientIDs.contains(clientID),
              let receivedAt = verifiedReportAt,
              Date().timeIntervalSince(receivedAt) >= 0,
              Date().timeIntervalSince(receivedAt) <= 30,
              let deviceID = observedDeviceID,
              identity?.id == deviceID else { return false }
        return true
    }

    private func awaitPreparation(_ task: Task<UUID, Error>, operationID: UUID) async throws -> UUID {
        let ticket = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in self?.cancelPreparation(operationID: operationID) }
        }
        do {
            try Task.checkCancellation()
        } catch {
            if connectionID == ticket {
                stopInternal(reason: "连接准备已取消，本地服务已关闭", errorMessage: nil,
                             expectedConnectionID: ticket, cancelPreparation: false)
            }
            throw error
        }
        return ticket
    }

    private func cancelPreparation(operationID: UUID) {
        guard preparationOperationID == operationID, let ticket = connectionID else { return }
        stopInternal(reason: "连接准备已取消，本地服务已关闭", errorMessage: nil,
                     expectedConnectionID: ticket, cancelPreparation: true)
    }

    private func abortPreparation(ticket: UUID, operationID: UUID, error: Error) {
        guard connectionID == ticket, preparationOperationID == operationID else { return }
        stopInternal(reason: "本地服务准备失败：\(error.localizedDescription)",
                     errorMessage: error.localizedDescription, expectedConnectionID: ticket,
                     cancelPreparation: false)
    }

    private func stopInternal(reason: String, errorMessage: String?, expectedConnectionID: UUID?,
                              cancelPreparation: Bool) {
        if let expectedConnectionID, connectionID != expectedConnectionID { return }
        let pendingPreparation = preparationTask
        preparationTask = nil
        preparationOperationID = nil
        if cancelPreparation { pendingPreparation?.cancel() }
        connectionID = nil
        expiry?.cancel()
        expiry = nil
        statusPolling?.cancel()
        statusPolling = nil
        interfaceObservation?.cancel()
        interfaceObservation = nil
        powerCheck?.cancel()
        powerCheck = nil
        commandTimeout?.cancel()
        commandTimeout = nil
        pendingControl = nil
        isSendingControl = false
        dns.stop()
        http.stop()
        mqtt.stop()
        candidateKeys = [:]
        candidateDeviceIDs = [:]
        observedClientID = nil
        observedDeviceID = nil
        connectedClientIDs = []
        subscribedClientIDs = []
        lastStatusRequests = [:]
        verifiedReportConnectionID = nil
        verifiedReportClientID = nil
        verifiedReportAt = nil
        canRequestStatus = false
        report = [:]
        settingsReport = [:]
        reportSignatureVerified = false
        isStarting = false
        isRunning = false
        localError = errorMessage
        status = reason
        UIApplication.shared.isIdleTimerDisabled = false
        endBackgroundTime()
        event(reason)
    }

    private func beginBackgroundTime(for ticket: UUID) {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "开启 A3 热点") { [weak self] in
            Task { @MainActor [weak self] in
                self?.stopInternal(reason: "离开 App 时间过长，本地服务已关闭。请重新连接。",
                                   errorMessage: "离开 App 时间过长，本地服务已关闭。请重新连接。",
                                   expectedConnectionID: ticket, cancelPreparation: true)
            }
        }
    }

    private func scheduleExpiry(for ticket: UUID, duration: TimeInterval) {
        expiry?.cancel()
        let seconds = duration.isFinite ? min(max(duration, 1), 600) : 600
        expiry = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            catch { return }
            guard let self, self.connectionID == ticket else { return }
            self.stopInternal(reason: "本轮验证时间已到，服务已关闭", errorMessage: nil,
                              expectedConnectionID: ticket, cancelPreparation: false)
        }
    }

    private func observeHotspotInterfaces(for ticket: UUID) {
        interfaceObservation?.cancel()
        interfaceObservation = Task { @MainActor [weak self] in
            var previous = ""
            while !Task.isCancelled {
                guard let self, self.connectionID == ticket else { return }
                let interfaces = Self.hotspotInterfaces()
                let state = interfaces.map { "\($0["name"] ?? "")/\($0["address"] ?? "")/\($0["netmask"] ?? "")" }
                    .joined(separator: ";")
                if self.hotspotInterfaceHistory.isEmpty || state != previous {
                    self.hotspotInterfaceHistory.append([
                        "timestamp": ISO8601DateFormatter().string(from: Date()),
                        "interfaces": interfaces,
                    ])
                    if self.hotspotInterfaceHistory.count > 64 {
                        self.hotspotInterfaceHistory.removeFirst()
                    }
                    previous = state
                    self.saveRecord()
                }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { return }
            }
        }
    }

    private static func hotspotInterfaces() -> [[String: String]] {
        NetworkProbe.interfaces().filter {
            $0.name.hasPrefix("ap") || $0.name.hasPrefix("bridge")
        }.map { ["name": $0.name, "address": $0.address, "netmask": $0.netmask ?? ""] }
    }

    nonisolated static func isHotspotPeer(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        if case .ipv6(let address) = host, address.isIPv4Mapped {
            return NetworkProbe.hotspotContains(address.rawValue.suffix(4).map(String.init).joined(separator: "."))
        }
        return NetworkProbe.hotspotContains(String(describing: host))
    }

    private func event(_ message: String) {
        events.append("\(ISO8601DateFormatter().string(from: Date())) \(message)")
        if events.count > 100 { events.removeFirst(events.count - 100) }
        saveRecord()
    }

    private func handleHTTP(_ request: LocalHTTPRequest) -> LocalHTTPResponse {
        httpRequests += 1
        guard request.method == "GET" else { return .json(["status": 405], status: 405) }
        // Do not log query strings or bodies: registration contains a device key.
        if request.path == "/probe" {
            event("收到本地 HTTP 测试请求")
            return .json(["ok": true, "service": "a3-phone-probe"])
        }
        if request.path == "/gettime" {
            event("收到设备时间请求")
            return .json(["time": Int(Date().timeIntervalSince1970)])
        }
        let components = URLComponents(string: "http://localhost" + request.target)
        let values = components?.queryItems ?? []
        guard request.path == "/aw",
              values.first(where: { $0.name == "path" })?.value == "aw/GET/genId",
              let encoded = values.first(where: { $0.name == "params" })?.value,
              let data = encoded.data(using: .utf8),
              let params = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let mac = params["mac"] as? String,
              let key = params["key"] as? String, !key.isEmpty, key.utf8.count <= 256,
              let type = (params["type"] as? NSNumber)?.intValue,
              let id = Self.registrationID(mac: mac) else {
            event("收到尚不支持的 HTTP 请求；未保存参数")
            return .json(["status": 501], status: 501)
        }
        identity = (id, key)
        registeredType = type
        do { try DeviceKeyStore.save(DeviceCredential(id: id, key: key, type: type)) }
        catch { event("设备凭据暂未保存，本轮仍可验证；关闭 App 后可能需要重新连接") }
        // Same base response as the community server. Its type switch omits A3;
        // compatibility remains experimental until a real device proceeds.
        event("收到设备注册（型号代码 \(type)），已回复通用 awId；等待设备后续连接")
        status = "已收到注册，等待加湿器上线"
        return .json(["status": 200, "data": ["awId": id]])
    }

    nonisolated static func registrationID(mac: String) -> Int? {
        let compact = mac.replacingOccurrences(of: ":", with: "").lowercased()
        guard !compact.isEmpty, compact.count <= 12,
              compact.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { return nil }
        let padded = String(repeating: "0", count: 12 - compact.count) + compact
        let bytes = Array(padded.utf8)
        guard let low = UInt8(String(bytes: bytes[0..<2], encoding: .ascii)!, radix: 16),
              let high = UInt8(String(bytes: bytes[2..<4], encoding: .ascii)!, radix: 16) else { return nil }
        let id = Int(low) | Int(high) << 8
        return id > 0 ? id : nil
    }

    nonisolated static func deviceID(in topic: String, prefix: String) -> Int? {
        guard topic.hasPrefix(prefix) else { return nil }
        let suffix = topic.dropFirst(prefix.count)
        guard !suffix.isEmpty, suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
              let id = Int(suffix), id > 0, id <= Int(UInt32.max) else { return nil }
        return id
    }

    nonisolated static func redactedTopic(_ topic: String) -> String {
        let levels = topic.split(separator: "/", omittingEmptySubsequences: false)
        let safe: Set<String> = ["airwater", "airmx", "eagle", "fan", "snow", "aw", "0", "1", "2", "01", "+", "#"]
        return levels.enumerated().map { index, value in
            let text = String(value)
            if index == levels.count - 1 && text != "+" && text != "#" { return "<设备>" }
            return safe.contains(text) ? text : "<字段>"
        }.joined(separator: "/")
    }

    func requestStatus() {
        guard isRunning, canRequestStatus, let clientID = observedClientID,
              let id = observedDeviceID,
              Date().timeIntervalSince(lastStatusRequests[clientID] ?? .distantPast) >= 3,
              let key = identity?.id == id ? identity?.key : candidateKeys[clientID] else { return }
        let payload = Self.statusRequestPayload(time: Int(Date().timeIntervalSince1970), key: key)
        let recipients = mqtt.publish(topic: "airwater/01/1/0/1/\(id)", payload: payload)
        if recipients > 0 {
            lastStatusRequests[clientID] = Date()
            if !reportSignatureVerified {
                event("已请求一次短时状态上报；连接密码是否为签名密钥仍待设备响应验证")
            }
        }
    }

    nonisolated static func statusRequestPayload(time: Int, key: String) -> Data {
        // Original MqttReportInterval: waterType/cleanTime are omitted at zero.
        // The community client's documented 600/10 values request a short report window.
        let inner = "\"cmdId\":1008,\"name\":\"awInstantPush\",\"time\":\(time),\"from\":4,\"data\":{\"frequencyTime\":600,\"durationTime\":10}"
        return Data(("{" + inner + ",\"sig\":\"" + signature(inner, key: key) + "\"}").utf8)
    }

    private func receive(clientID: String, topic: String, payload: Data) {
        if topic == "diagnostic/probe" {
            event("收到本地 MQTT 测试消息")
            _ = mqtt.publish(topic: "diagnostic/reply", payload: payload)
            return
        }
        guard let id = Self.deviceID(in: topic, prefix: "airwater/01/0/1/1/"),
              (id == identity?.id || (id == observedDeviceID && clientID == observedClientID)),
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let values = object["data"] as? [String: Any] else {
            let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let command = (object?["cmdId"] as? NSNumber)?.intValue ?? -1
            event("收到尚未识别的消息：\(Self.redactedTopic(topic))，命令 \(command)；未记录载荷")
            return
        }
        let command = (object["cmdId"] as? NSNumber)?.intValue ?? -1
        let key = identity?.id == id ? identity?.key : candidateKeys[clientID]
        let verified = key.map { Self.verifyReportSignature(payload, key: $0) } ?? false
        if command == 1003 {
            guard verified else { event("设置报告签名未通过，已忽略"); return }
            settingsReport = Dictionary(uniqueKeysWithValues: Self.settingFields.compactMap { field in
                (values[field] as? NSNumber).map { (field, $0.intValue) }
            })
            event("收到签名有效的设置报告，包含 \(settingsReport.count) 个已知设置字段")
            return
        }
        guard command == 1001 else {
            event("收到已识别设备消息，命令 \(command)；等待 awStatus")
            return
        }
        let fields = Array(Set(["power", "mode", "cadr", "waterflood", "lock", "anion", "h", "h0", "gooseOnline", "water",
                               "WUD", "wetFilm", "isNeedClean", "powerHeatStatus", "electrolysisStatus", "delayOffTimer"] + Self.settingFields))
        report = Dictionary(uniqueKeysWithValues: fields.compactMap { key in
            (values[key] as? NSNumber).map { (key, $0.intValue) }
        })
        reportSignatureVerified = verified
        if reportSignatureVerified, let key, identity?.id != id {
            identity = (id, key)
            do { try DeviceKeyStore.save(DeviceCredential(id: id, key: key, type: registeredType ?? -1)) }
            catch { event("已核对设备密钥，本机安全存储暂不可用；本轮可继续") }
            event("设备状态签名已核对，已恢复原有设备身份")
        }
        if reportSignatureVerified,
           let ticket = connectionID,
           observedClientID == clientID,
           observedDeviceID == id,
           connectedClientIDs.contains(clientID),
           subscribedClientIDs.contains(clientID) {
            verifiedReportConnectionID = ticket
            verifiedReportClientID = clientID
            verifiedReportAt = Date()
        }
        status = reportSignatureVerified ? "已收到签名校验通过的设备状态" : "已收到状态，签名格式仍待核对；控制暂不可用"
        if reportSignatureVerified, let pendingControl,
           pendingControl.allSatisfy({ report[$0.key] == $0.value }) {
            if let power = pendingControl["power"] {
                commandStatus = "加湿器已确认：\(power == 1 ? "开机" : "关机")"
            } else {
                commandStatus = "加湿器已确认调节后的状态"
            }
            self.pendingControl = nil
            isSendingControl = false
            commandTimeout?.cancel()
            commandTimeout = nil
        }
        event("收到注册设备的 awStatus 状态")
        if reportSignatureVerified {
            startStatusPolling()
            startPowerCheckIfRequested()
        }
    }

    private func startStatusPolling() {
        guard statusPolling == nil else { return }
        statusPolling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) }
                catch { return }
                guard let self, self.isRunning else { return }
                self.requestStatus()
            }
        }
    }

    private func startPowerCheckIfRequested() {
        // Explicit maintenance action; never starts a roundtrip or turns the device on.
        if ProcessInfo.processInfo.arguments.contains("--ensure-device-off") {
            guard !powerCheckStarted, canControl else { return }
            powerCheckStarted = true
            if report["power"] == 1 {
                event("设备待清洗，本次仅请求关机")
                setPower(false)
            }
            return
        }
        guard ProcessInfo.processInfo.arguments.contains("--verify-power-roundtrip"),
              !powerCheckStarted, canControl, let original = report["power"], (0...1).contains(original) else { return }
        powerCheckStarted = true
        powerCheck = Task { [weak self] in
            guard let self else { return }
            defer { self.powerCheck = nil }
            let alternate = 1 - original
            self.event("开始实机电源往返核对：\(original) → \(alternate) → \(original)")
            for target in [alternate, original] {
                guard self.isRunning, !Task.isCancelled else { return }
                self.setPower(target == 1)
                let deadline = Date().addingTimeInterval(12)
                while Date() < deadline && self.isRunning && !Task.isCancelled {
                    if self.reportSignatureVerified, self.report["power"] == target, self.pendingControl == nil { break }
                    do { try await Task.sleep(nanoseconds: 200_000_000) }
                    catch { return }
                }
                guard self.isRunning, !Task.isCancelled else { return }
                guard self.reportSignatureVerified, self.report["power"] == target, self.pendingControl == nil else {
                    self.event("电源往返核对未通过：未收到目标状态；尝试恢复原电源状态")
                    self.isSendingControl = false
                    self.setPower(original == 1)
                    return
                }
                self.event("实机已回报电源 \(target)")
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
            }
            self.commandStatus = "实机开关往返验证通过，已恢复原电源状态"
            self.event(self.commandStatus)
        }
    }

    func setPower(_ enabled: Bool) {
        guard canControl, !isSendingControl else { return }
        guard let values = Self.powerValues(from: report, enabled: enabled) else {
            commandStatus = "设备状态字段不完整，暂不能安全发送控制"
            return
        }
        sendControl(values, expected: ["power": enabled ? 1 : 0])
    }

    func setMode(_ mode: Int) {
        guard canAdjustOperation,
              let values = Self.operationValues(from: report, mode: mode) else { return }
        sendControl(values, expected: ["mode": mode])
    }

    func setFan(_ percentage: Int) {
        guard canAdjustOperation,
              let values = Self.operationValues(from: report, mode: 0, fan: percentage) else { return }
        sendControl(values, expected: ["mode": 0, "cadr": percentage])
    }

    private func sendControl(_ values: [String: Int], expected: [String: Int]) {
        guard let identity else { return }
        commandTimeout?.cancel()
        let payload = Self.powerPayload(values: values, time: Int(Date().timeIntervalSince1970), key: identity.key)
        let recipients = mqtt.publish(topic: "airwater/01/1/0/1/\(identity.id)", payload: payload)
        pendingControl = recipients > 0 ? expected : nil
        isSendingControl = recipients > 0
        commandStatus = recipients > 0 ? "指令已发送，等待加湿器确认" : "加湿器尚未订阅控制消息"
        event(commandStatus)
        guard recipients > 0 else { return }
        commandTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 12_000_000_000) } catch { return }
            guard let self, self.pendingControl != nil else { return }
            self.pendingControl = nil
            self.isSendingControl = false
            self.commandStatus = "暂未收到设备确认，请检查机身状态后重试"
            self.event(self.commandStatus)
        }
    }

    nonisolated static func operationValues(from report: [String: Int], mode: Int, fan: Int? = nil) -> [String: Int]? {
        guard (0...2).contains(mode), report["mode"] != 5,
              let power = report["power"], (0...1).contains(power),
              var values = powerValues(from: report, enabled: power == 1) else { return nil }
        if let fan {
            guard mode == 0, (0...100).contains(fan) else { return nil }
            values["cadr"] = fan
        }
        values["mode"] = mode
        return values
    }

    nonisolated static func powerValues(from report: [String: Int], enabled: Bool) -> [String: Int]? {
        var values: [String: Int] = [:]
        for field in ["power", "mode", "cadr", "lock", "anion"] {
            guard let value = report[field] else { return nil }
            values[field] = value
        }
        // Android MqttAwReport.parseJsonData uses optInt, so absent waterflood is zero.
        values["waterflood"] = report["waterflood"] ?? 0
        // Community client treats 5 as a fault indicator, not a selectable mode.
        if values["mode"] == 5 { values["mode"] = 1 }
        values["power"] = enabled ? 1 : 0
        return values
    }

    nonisolated static func powerPayload(values: [String: Int], time: Int, key: String) -> Data {
        // Match original Android JSONObject insertion order, including data fields.
        let fields = ["power", "mode", "cadr", "waterflood", "lock", "anion"]
        let data = fields.map { "\"\($0)\":\(values[$0]!)" }.joined(separator: ",")
        let inner = "\"cmdId\":1000,\"name\":\"awControl\",\"time\":\(time),\"from\":4,\"data\":{\(data)}"
        return Data(("{" + inner + ",\"sig\":\"" + signature(inner, key: key) + "\"}").utf8)
    }

    nonisolated static func signature(_ inner: String, key: String) -> String {
        Insecure.MD5.hash(data: Data((inner + "," + key).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func verifyReportSignature(_ payload: Data, key: String) -> Bool {
        // The observed client protocol appends sig last. Unknown formatting is
        // explicitly unverified and cannot unlock controls; never guess a key.
        guard let text = String(data: payload, encoding: .utf8), text.first == "{", text.last == "}",
              let split = text.range(of: ",\"sig\":", options: .backwards),
              let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let received = object["sig"] as? String, received.count == 32,
              text[split.lowerBound...] == ",\"sig\":\"\(received)\"}" else { return false }
        let inner = String(text[text.index(after: text.startIndex)..<split.lowerBound])
        return signature(inner, key: key) == received.lowercased()
    }

    private func saveRecord() {
        // A deliberately redacted diagnostic record. No MAC, device key,
        // hotspot credentials, CONNECT payload or unrelated DNS names.
        var value: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
                                    "running": isRunning, "starting": isStarting, "status": status,
                                    "dnsQueries": dnsQueries, "httpRequests": httpRequests,
                                    "connections": connectedClients, "subscriptions": subscriptions,
                                    "mqttListening": mqtt.isRunning, "mqttStatus": mqtt.status,
                                    "deviceReport": report, "signatureVerified": reportSignatureVerified, "events": events]
        value["localError"] = localError
        value["commandStatus"] = commandStatus
        value["settingsReport"] = settingsReport
        value["hotspotInterfaces"] = Self.hotspotInterfaces()
        value["hotspotInterfaceHistory"] = hotspotInterfaceHistory
        value["applicationState"] = UIApplication.shared.applicationState.rawValue
        if let registeredType { value["registeredType"] = registeredType }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("local-session.json"), options: .atomic)
        }
    }
}
