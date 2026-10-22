import Combine
import CoreBluetooth
import Foundation
import UIKit

@MainActor
final class A3Bluetooth: NSObject, ObservableObject {
    enum State: Equatable {
        case idle, scanning, connecting, discovering, subscribing
        case handshaking, ready, provisioning, queryingDeviceID, provisioned, failed
    }

    struct Device: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        fileprivate let peripheral: CBPeripheral
        static func == (lhs: Device, rhs: Device) -> Bool { lhs.id == rhs.id }
    }

    private enum PassiveRSSIBand: String, CaseIterable {
        case strong = "strong_-60_to_0_dBm"
        case medium = "medium_-61_to_-79_dBm"
        case weak = "weak_-80_or_lower_dBm"
        case unavailable = "unavailable"
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var status = "未连接"
    @Published private(set) var devices: [Device] = []
    @Published private(set) var lastDeviceID: String?

    var canProvision: Bool {
        state == .ready && peripheral?.state == .connected
            && writeCharacteristic != nil && notifyCharacteristic?.isNotifying == true
    }

    nonisolated static func offlineChecks() -> [(String, Bool)] {
        let handshakePayload: [UInt8] = [8] + [UInt8](repeating: 0, count: 8)
            + [5] + Array("1.0.0".utf8)
        let expectedHandshake: [UInt8] = [0x01, 0x11, 0x00, 0x0b, 0x08]
            + [UInt8](repeating: 0, count: 8) + [0x05] + Array("1.0.0".utf8)
        var checks: [(String, Bool)] = []

        var handshakeSequence: UInt8 = 0
        let handshakeFrames = try? A3Wire.packetize(command: 11, payload: handshakePayload,
                                                      sequence: &handshakeSequence)
        checks.append(("cmd11 与原 App UID 0 握手帧一致",
                       handshakeFrames == [expectedHandshake] && handshakeSequence == 2))

        var requestSequence: UInt8 = 0
        let firstRequest = try? A3Wire.packetize(command: 11, payload: handshakePayload,
                                                  sequence: &requestSequence)
        let nextRequest = try? A3Wire.packetize(command: 22, payload: [],
                                                 sequence: &requestSequence)
        checks.append(("cmd11 后空 cmd22 使用序号 3",
                       firstRequest?.first?.first == 1
                           && nextRequest == [[0x03, 0x11, 0x00, 0x16]]
                           && requestSequence == 3))

        var multiSequence: UInt8 = 0
        _ = try? A3Wire.packetize(command: 11, payload: handshakePayload,
                                  sequence: &multiSequence)
        let multiCommand = try? A3Wire.packetize(command: 21,
                                                  payload: [UInt8](repeating: 0x41, count: 17),
                                                  sequence: &multiSequence)
        let afterMulti = try? A3Wire.packetize(command: 22, payload: [],
                                               sequence: &multiSequence)
        checks.append(("多片 cmd21 末包后下一请求序号正确",
                       multiCommand?.map(\.first) == [3, 4]
                           && afterMulti == [[0x06, 0x11, 0x00, 0x16]]
                           && multiSequence == 6))

        var wrappedSequence: UInt8 = 0xfe
        let beforeWrap = try? A3Wire.packetize(command: 11, payload: [],
                                                sequence: &wrappedSequence)
        let afterWrap = try? A3Wire.packetize(command: 22, payload: [],
                                               sequence: &wrappedSequence)
        checks.append(("请求序号按 8 bit 回绕",
                       beforeWrap?.first?.first == 0xff && wrappedSequence == 0
                           && afterWrap == [[0x00, 0x11, 0x00, 0x16]]))

        let invalidHeaders = A3Wire.parse([0x01, 0x01, 0x00, 0x0b]) == nil
            && A3Wire.parse([0x01, 0x21, 0x00, 0x0b]) == nil
        var invalidSequence: UInt8 = 7
        let oversized = try? A3Wire.packetize(command: 21,
                                               payload: [UInt8](repeating: 0, count: 241),
                                               sequence: &invalidSequence)
        checks.append(("拒绝非法分片头和超过 15 片的请求",
                       invalidHeaders && oversized == nil && invalidSequence == 7))

        checks.append(("被动扫描只把 A3 名称及分隔后缀识别为候选",
                       isPassiveA3CandidateName("AirWater A3")
                           && isPassiveA3CandidateName("AirWater A3_7F2A")
                           && !isPassiveA3CandidateName("AirWater A3S")
                           && !isPassiveA3CandidateName("AirWater H6")))
        checks.append(("被动扫描 RSSI 只映射到非标识区间",
                       passiveRSSIBand(for: -50) == PassiveRSSIBand.strong.rawValue
                           && passiveRSSIBand(for: -70) == PassiveRSSIBand.medium.rawValue
                           && passiveRSSIBand(for: -85) == PassiveRSSIBand.weak.rawValue
                           && passiveRSSIBand(for: 127) == PassiveRSSIBand.unavailable.rawValue))
        return checks
    }

    nonisolated private static func isPassiveA3CandidateName(_ name: String?) -> Bool {
        guard let name else { return false }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = "AirWater A3"
        if normalized.localizedCaseInsensitiveCompare(base) == .orderedSame { return true }
        return [" ", "-", "_"].contains { delimiter in
            normalized.lowercased().hasPrefix((base + delimiter).lowercased())
        }
    }

    nonisolated private static func passiveRSSIBand(for rssi: Int) -> String {
        if rssi == 127 { return PassiveRSSIBand.unavailable.rawValue }
        if rssi <= -80 { return PassiveRSSIBand.weak.rawValue }
        if rssi <= -61 { return PassiveRSSIBand.medium.rawValue }
        return PassiveRSSIBand.strong.rawValue
    }

    private let serviceUUID = CBUUID(string: "22210000-554a-4546-5542-46534450464d")
    private let writeUUID = CBUUID(string: "22210001-554a-4546-5542-46534450464d")
    private let notifyUUID = CBUUID(string: "22210002-554a-4546-5542-46534450464d")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?
    private var scanRequested = false
    private var sequence: UInt8 = 0
    private var expectedCommand: UInt16?
    private var writing = false
    private var earlyResponse: A3Wire.Message?
    private var assembly: Assembly?
    private var writeQueue: [[UInt8]] = []
    private var activeWrite: [UInt8]?
    private var provisionAccepted = false
    private var timeout: DispatchWorkItem?
    private var generation = 0
    private var passiveScanRequested = false
    private var passiveScanTask: Task<Void, Never>?
    private var passiveScanStartedAt: Date?
    private var passiveScanStopReason: String?
    private var passiveSeenIdentifiers = Set<UUID>()
    private var passiveA3Identifiers = Set<UUID>()
    private var passiveRSSIBands: [PassiveRSSIBand: Int] = [:]
    private var passiveConnectedPeripheralCount: Int?

    override init() {
        super.init()
    }

    func scan() {
        guard passiveScanTask == nil else {
            status = "被动蓝牙诊断正在运行"
            return
        }
        guard peripheral == nil else {
            status = "请先断开当前设备，再开始扫描"
            return
        }
        devices.removeAll()
        scanRequested = true
        guard let central else {
            self.central = CBCentralManager(delegate: self, queue: .main)
            status = "正在检查蓝牙状态…"
            return
        }
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff:
            scanRequested = false
            state = .failed
            status = "请先开启蓝牙"
        case .unauthorized:
            scanRequested = false
            state = .failed
            status = "请在系统设置中允许 App 使用蓝牙"
        case .unsupported:
            scanRequested = false
            state = .failed
            status = "此设备不支持蓝牙 LE"
        case .resetting, .unknown:
            status = "正在检查蓝牙状态…"
        @unknown default:
            status = "无法读取蓝牙状态"
        }
    }

    /// Runs a bounded scan-only diagnostic; it makes no GATT connections or application commands.
    func startPassiveScanDiagnostic() {
        guard passiveScanTask == nil else { return }

        passiveScanRequested = true
        passiveScanStartedAt = nil
        passiveScanStopReason = nil
        passiveSeenIdentifiers.removeAll(keepingCapacity: false)
        passiveA3Identifiers.removeAll(keepingCapacity: false)
        passiveRSSIBands.removeAll(keepingCapacity: false)
        passiveConnectedPeripheralCount = nil

        let previousIdleTimerState = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }

        passiveScanTask = Task { @MainActor [weak self] in
            guard let self else {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
                return
            }
            await self.performPassiveScan(previousIdleTimerState: previousIdleTimerState)
        }
    }

    private func performPassiveScan(previousIdleTimerState: Bool) async {
        var endReason = "radio_unavailable"
        defer {
            let startedAt = passiveScanStartedAt
            let duration = startedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
            let scanStarted = startedAt != nil
            if startedAt != nil, let central, central.state == .poweredOn, central.isScanning {
                central.stopScan()
            }
            savePassiveScanReport(scanStarted: scanStarted, duration: duration,
                                  endReason: endReason)
            passiveScanRequested = false
            passiveScanTask = nil
            passiveScanStartedAt = nil
            passiveScanStopReason = nil
            passiveSeenIdentifiers.removeAll(keepingCapacity: false)
            passiveA3Identifiers.removeAll(keepingCapacity: false)
            passiveRSSIBands.removeAll(keepingCapacity: false)
            passiveConnectedPeripheralCount = nil
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerState
        }

        guard peripheral == nil, !scanRequested, let central else {
            endReason = "bluetooth_busy"
            return
        }

        let radioWaitDeadline = Date().addingTimeInterval(25)
        while central.state == .unknown || central.state == .resetting {
            if Task.isCancelled {
                endReason = passiveScanStopReason ?? "cancelled"
                return
            }
            guard Date() < radioWaitDeadline else {
                endReason = "radio_state_timeout"
                return
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                endReason = passiveScanStopReason ?? "cancelled"
                return
            }
        }

        guard central.state == .poweredOn else {
            endReason = Self.radioStateName(central.state)
            return
        }

        passiveConnectedPeripheralCount = central
            .retrieveConnectedPeripherals(withServices: [serviceUUID]).count
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        guard central.isScanning else {
            endReason = "scan_not_started"
            return
        }
        passiveScanStartedAt = Date()

        do {
            try await Task.sleep(nanoseconds: 25_000_000_000)
            endReason = "duration_elapsed"
        } catch {
            endReason = passiveScanStopReason ?? "cancelled"
        }
    }

    private func savePassiveScanReport(scanStarted: Bool, duration: TimeInterval,
                                       endReason: String) {
        guard let documents = FileManager.default.urls(for: .documentDirectory,
                                                       in: .userDomainMask).first else {
            status = "被动蓝牙扫描报告无法保存"
            return
        }
        let rssiBands = Dictionary(uniqueKeysWithValues: PassiveRSSIBand.allCases.map {
            ($0.rawValue, passiveRSSIBands[$0, default: 0])
        })
        let report: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "radioState": central.map { Self.radioStateName($0.state) } ?? "unknown",
            "scanState": scanStarted ? "started_and_stopped" : "not_started",
            "scanDurationSeconds": duration,
            "totalUniqueAdvertisementCount": passiveSeenIdentifiers.count,
            "a3CandidateCount": passiveA3Identifiers.count,
            "connectedA3ServicePeripheralCount": passiveConnectedPeripheralCount.map { $0 as Any } ?? NSNull(),
            "rssiBands": rssiBands,
            "endReason": endReason
        ]
        guard JSONSerialization.isValidJSONObject(report),
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) else {
            status = "被动蓝牙扫描报告无法保存"
            return
        }
        do {
            try data.write(to: documents.appendingPathComponent("passive-ble-scan.json"),
                           options: .atomic)
            status = "被动蓝牙扫描完成，匿名报告已保存"
        } catch {
            status = "被动蓝牙扫描报告无法保存"
        }
    }

    private static func radioStateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    func stopScan() {
        scanRequested = false
        if let central, central.state == .poweredOn, central.isScanning { central.stopScan() }
        if state == .scanning {
            state = .idle
            status = "扫描已停止"
        }
    }

    func connect(to device: Device) {
        guard passiveScanTask == nil else {
            status = "被动蓝牙诊断正在运行"
            return
        }
        guard let central, central.state == .poweredOn else {
            status = "请开启蓝牙并允许 App 使用蓝牙"
            return
        }
        guard peripheral == nil, devices.contains(where: { $0.id == device.id }) else {
            status = "请断开当前连接或重新扫描设备"
            return
        }
        stopScan()
        resetRequestState()
        lastDeviceID = nil
        peripheral = device.peripheral
        peripheral?.delegate = self
        state = .connecting
        status = "正在连接 AirWater A3…"
        generation &+= 1
        armTimeout(20, .connection)
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        scanRequested = false
        if let central, central.state == .poweredOn, central.isScanning { central.stopScan() }
        resetTransport(cancelConnection: true)
        state = .idle
        status = "已断开连接"
    }

    /// 仅由用户显式调用。调用方也应立即清空自己的输入框。
    func provision(ssid: String, password: String) {
        guard canProvision else {
            status = "请先连接设备并完成 BLE 握手"
            return
        }
        var ssidBytes = Array(ssid.utf8)
        var passwordBytes = Array(password.utf8)
        defer {
            erase(&ssidBytes)
            erase(&passwordBytes)
        }
        guard (1...32).contains(ssidBytes.count) else {
            status = "SSID 必须为 1–32 个 UTF-8 字节"
            return
        }
        guard (8...63).contains(passwordBytes.count) else {
            status = "热点密码必须为 8–63 个 UTF-8 字节"
            return
        }
        let length = ssidBytes.count + passwordBytes.count + 2
        guard length <= 15 * A3Wire.payloadBytesPerFragment else {
            status = "输入超过当前 A3 BLE 协议可发送长度"
            return
        }
        var payload: [UInt8] = [UInt8(ssidBytes.count)]
        payload.append(contentsOf: ssidBytes)
        payload.append(UInt8(passwordBytes.count))
        payload.append(contentsOf: passwordBytes)
        state = .provisioning
        status = "正在发送 Wi-Fi 配置…"
        sendRequest(command: 21, payload: &payload)
    }

    private func beginScan() {
        guard scanRequested, let central, central.state == .poweredOn else { return }
        state = .scanning
        status = "正在扫描 AirWater A3…"
        // The original app filters by advertised name; the service UUID may not be advertised.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func startHandshake() {
        state = .handshaking
        status = "正在检查 BLE 握手…"
        // DEX m/c.s(): cmd 11, UID 0, version 1.0.0. Reply 00 is only a response,
        // not proof of account binding.
        var payload: [UInt8] = [8] + [UInt8](repeating: 0, count: 8) + [5]
        payload.append(contentsOf: Array("1.0.0".utf8))
        sendRequest(command: 11, payload: &payload)
    }

    private func queryDeviceID() {
        state = .queryingDeviceID
        status = "设备已接受配置，正在查询设备 ID…"
        var payload: [UInt8] = []
        sendRequest(command: 22, payload: &payload)
    }

    private func sendRequest(command: UInt16, payload: inout [UInt8]) {
        defer { erase(&payload) }
        guard let peripheral, peripheral.state == .connected,
              let writeCharacteristic, expectedCommand == nil, !writing else {
            fail("蓝牙连接或协议状态不可用")
            return
        }
        do {
            writeQueue = try A3Wire.packetize(command: command, payload: payload,
                                              sequence: &sequence)
        } catch {
            fail("无法生成有效的 A3 BLE 数据包")
            return
        }
        expectedCommand = command
        earlyResponse = nil
        writing = true
        sendNextPacket(peripheral, writeCharacteristic)
    }

    private func sendNextPacket(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic) {
        guard !writeQueue.isEmpty else {
            writing = false
            if let earlyResponse, earlyResponse.command == expectedCommand {
                self.earlyResponse = nil
                handleResponse(earlyResponse)
            } else if let expectedCommand {
                armTimeout(45, .response(expectedCommand))
            }
            return
        }
        activeWrite = writeQueue.removeFirst()
        guard let activeWrite else {
            fail("蓝牙发送队列异常")
            return
        }
        peripheral.writeValue(Data(activeWrite), for: characteristic, type: .withResponse)
        armTimeout(12, .write)
    }

    private func handleNotification(_ data: Data) {
        guard let fragment = A3Wire.parse(Array(data)),
              [UInt16(11), 21, 22].contains(fragment.command) else { return }
        guard !fragment.encrypted else {
            if fragment.command == expectedCommand { fail("收到未覆盖的加密 BLE 响应") }
            return
        }
        guard let message = accept(fragment),
              message.command == expectedCommand else { return }
        if writing { earlyResponse = message }
        else { handleResponse(message) }
    }

    private func accept(_ fragment: A3Wire.Fragment) -> A3Wire.Message? {
        if fragment.part == 1 {
            assembly = nil
            if fragment.count == 1 {
                return .init(command: fragment.command, payload: fragment.payload)
            }
            assembly = Assembly(command: fragment.command, count: fragment.count,
                                nextPart: 2, responseFlag: fragment.responseFlag,
                                payload: fragment.payload)
            return nil
        }
        guard var current = assembly, current.command == fragment.command,
              current.count == fragment.count, current.nextPart == fragment.part,
              current.responseFlag == fragment.responseFlag else {
            assembly = nil
            return nil
        }
        current.payload.append(contentsOf: fragment.payload)
        current.nextPart += 1
        if fragment.part == fragment.count {
            assembly = nil
            return .init(command: fragment.command, payload: current.payload)
        }
        assembly = current
        return nil
    }

    private func handleResponse(_ message: A3Wire.Message) {
        guard message.command == expectedCommand else { return }
        cancelTimeout()
        expectedCommand = nil
        earlyResponse = nil
        switch message.command {
        case 11:
            guard validHandshakeReply(message.payload) else {
                fail("BLE 握手响应格式不符合已验证的 A3 格式")
                return
            }
            state = .ready
            status = message.payload == [0]
                ? "已收到 UID 0 握手响应（不代表账号绑定成功）"
                : "BLE 握手已响应，可以手动发送 Wi-Fi 配置"
        case 21:
            guard let result = message.payload.first else {
                fail("配网响应缺少状态字节")
                return
            }
            guard result == 1 else {
                fail("设备未接受 Wi-Fi 配置")
                return
            }
            provisionAccepted = true
            queryDeviceID()
        case 22:
            guard message.payload.count >= 5 else {
                finishProvisionedWithoutID("设备已接受配置，但设备 ID 响应不完整")
                return
            }
            let p = message.payload
            let id = UInt32(p[1]) << 24 | UInt32(p[2]) << 16 | UInt32(p[3]) << 8 | UInt32(p[4])
            lastDeviceID = String(id)
            provisionAccepted = true
            state = .provisioned
            status = "设备已接受配置，设备 ID 已返回"
            clearPendingWrites()
        default:
            break
        }
    }

    private func validHandshakeReply(_ payload: [UInt8]) -> Bool {
        if payload == [0] { return true }
        guard payload.count >= 8, payload[0] == 6 else { return false }
        let versionLength = Int(payload[7])
        guard versionLength > 0, payload.count >= 8 + versionLength else { return false }
        return payload[8..<(8 + versionLength)].allSatisfy { (0x20...0x7e).contains($0) }
    }

    private func finishProvisionedWithoutID(_ message: String) {
        resetTransport(cancelConnection: true)
        state = .provisioned
        status = message
    }

    private func fail(_ message: String) {
        let wasAccepted = provisionAccepted
        resetTransport(cancelConnection: true)
        state = wasAccepted ? .provisioned : .failed
        status = wasAccepted ? "设备已接受配置；\(message)" : message
    }

    private func armTimeout(_ seconds: TimeInterval, _ reason: TimeoutReason) {
        cancelTimeout()
        let generation = self.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.handleTimeout(reason)
        }
        timeout = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func handleTimeout(_ reason: TimeoutReason) {
        timeout = nil
        switch reason {
        case .connection: fail("连接设备超时")
        case .services: fail("发现 A3 服务超时")
        case .characteristics: fail("发现 A3 特征超时")
        case .subscription: fail("订阅设备通知超时")
        case .write: fail("蓝牙写入超时")
        case .response(let command):
            if command == 22, provisionAccepted {
                finishProvisionedWithoutID("设备已接受配置，但设备 ID 查询超时")
            } else {
                fail(command == 11 ? "BLE 握手响应超时" : "设备配网响应超时")
            }
        }
    }

    private func cancelTimeout() {
        timeout?.cancel()
        timeout = nil
    }

    private func resetRequestState() {
        sequence = 0
        expectedCommand = nil
        writing = false
        earlyResponse = nil
        assembly = nil
        provisionAccepted = false
        clearPendingWrites()
    }

    private func resetTransport(cancelConnection: Bool) {
        generation &+= 1
        cancelTimeout()
        scanRequested = false
        if let central, central.state == .poweredOn, central.isScanning { central.stopScan() }
        let current = peripheral
        current?.delegate = nil
        if cancelConnection, let current, let central { central.cancelPeripheralConnection(current) }
        peripheral = nil
        writeCharacteristic = nil
        notifyCharacteristic = nil
        resetRequestState()
    }

    private func clearPendingWrites() {
        if activeWrite != nil { erase(&activeWrite!) }
        for index in writeQueue.indices { erase(&writeQueue[index]) }
        writeQueue.removeAll(keepingCapacity: false)
        activeWrite = nil
        writing = false
    }

    private func erase(_ bytes: inout [UInt8]) {
        for index in bytes.indices { bytes[index] = 0 }
        bytes.removeAll(keepingCapacity: false)
    }

    private func connectionTimeout(_ reason: TimeoutReason) {
        armTimeout(15, reason)
    }

    private enum TimeoutReason {
        case connection, services, characteristics, subscription, write
        case response(UInt16)
    }

    private struct Assembly {
        let command: UInt16
        let count: UInt8
        var nextPart: UInt8
        let responseFlag: Bool
        var payload: [UInt8]
    }
}

extension A3Bluetooth: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if passiveScanRequested, passiveScanStartedAt != nil, central.state != .poweredOn {
            passiveScanStopReason = Self.radioStateName(central.state)
            passiveScanTask?.cancel()
        }
        switch central.state {
        case .poweredOn:
            if scanRequested { beginScan() }
            else if state == .idle { status = "蓝牙已就绪" }
        case .poweredOff:
            if peripheral != nil { fail("蓝牙已关闭，连接已清理") }
            else if scanRequested {
                scanRequested = false
                state = .failed
                status = "请先开启蓝牙"
            }
        case .unauthorized:
            if peripheral != nil { fail("App 未获蓝牙使用权限") }
            else if scanRequested {
                scanRequested = false
                state = .failed
                status = "请在系统设置中允许 App 使用蓝牙"
            }
        case .unsupported:
            scanRequested = false
            state = .failed
            status = "此设备不支持蓝牙 LE"
        case .resetting, .unknown:
            break
        @unknown default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if passiveScanRequested, passiveScanStartedAt != nil {
            let isNewPeripheral = passiveSeenIdentifiers.insert(peripheral.identifier).inserted
            let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
            let hasA3Service = advertisedServices?.contains(serviceUUID) == true
            if hasA3Service || Self.isPassiveA3CandidateName(advertised)
                || Self.isPassiveA3CandidateName(peripheral.name) {
                passiveA3Identifiers.insert(peripheral.identifier)
            }
            if isNewPeripheral {
                let band = Self.passiveRSSIBand(for: RSSI.intValue)
                if let bucket = PassiveRSSIBand(rawValue: band) {
                    passiveRSSIBands[bucket, default: 0] += 1
                }
            }
            return
        }
        guard scanRequested else { return }
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name ?? ""
        guard name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare("AirWater A3") == .orderedSame else { return }
        let device = Device(id: peripheral.identifier, name: "AirWater A3",
                            rssi: RSSI.intValue, peripheral: peripheral)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device) }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        cancelTimeout()
        state = .discovering
        status = "正在读取 AirWater A3 服务…"
        peripheral.delegate = self
        connectionTimeout(.services)
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        fail("连接 AirWater A3 失败")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        let accepted = provisionAccepted
        resetTransport(cancelConnection: false)
        state = accepted ? .provisioned : .failed
        status = accepted ? "设备已接受配置，蓝牙已断开" : "蓝牙连接已中断"
    }
}

extension A3Bluetooth: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier else { return }
        cancelTimeout()
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            fail("未发现预期的 AirWater A3 服务")
            return
        }
        state = .discovering
        status = "正在读取 A3 通信特征…"
        connectionTimeout(.characteristics)
        peripheral.discoverCharacteristics([writeUUID, notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, service.uuid == serviceUUID else { return }
        cancelTimeout()
        guard error == nil, let characteristics = service.characteristics,
              let write = characteristics.first(where: { $0.uuid == writeUUID }),
              let notify = characteristics.first(where: { $0.uuid == notifyUUID }),
              write.properties.contains(.write),
              notify.properties.contains(.notify) || notify.properties.contains(.indicate) else {
            fail("A3 写入或通知特征不符合预期")
            return
        }
        writeCharacteristic = write
        notifyCharacteristic = notify
        state = .subscribing
        status = "正在订阅设备通知…"
        connectionTimeout(.subscription)
        peripheral.setNotifyValue(true, for: notify)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, characteristic.uuid == notifyUUID else { return }
        cancelTimeout()
        guard error == nil, characteristic.isNotifying else {
            fail("无法订阅 A3 设备通知")
            return
        }
        startHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, characteristic.uuid == writeUUID,
              activeWrite != nil else { return }
        cancelTimeout()
        guard error == nil else {
            fail("蓝牙写入失败")
            return
        }
        if activeWrite != nil { erase(&activeWrite!) }
        activeWrite = nil
        if !writeQueue.isEmpty, let writeCharacteristic {
            sendNextPacket(peripheral, writeCharacteristic)
        } else {
            writing = false
            if let earlyResponse, earlyResponse.command == expectedCommand {
                self.earlyResponse = nil
                handleResponse(earlyResponse)
            } else if let expectedCommand {
                armTimeout(45, .response(expectedCommand))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard self.peripheral?.identifier == peripheral.identifier, characteristic.uuid == notifyUUID,
              error == nil, let data = characteristic.value else { return }
        handleNotification(data)
    }
}

private enum A3Wire {
    static let payloadBytesPerFragment = 16
    private static let headerBytes = 4
    private static let maximumFrameBytes = headerBytes + payloadBytesPerFragment

    struct Fragment {
        let part: UInt8
        let count: UInt8
        let encrypted: Bool
        let responseFlag: Bool
        let command: UInt16
        let payload: [UInt8]
    }
    struct Message {
        let command: UInt16
        let payload: [UInt8]
    }

    static func packetize(command: UInt16, payload: [UInt8],
                          sequence: inout UInt8) throws -> [[UInt8]] {
        let total = max(1, (payload.count + payloadBytesPerFragment - 1) / payloadBytesPerFragment)
        guard total <= 15, command <= 0x3fff else { throw WireError.invalid }
        let count = UInt8(total)
        var packets: [[UInt8]] = []
        packets.reserveCapacity(total)
        for index in 0..<total {
            sequence &+= 1
            let part = UInt8(index + 1)
            let lower = index * payloadBytesPerFragment
            let upper = min(lower + payloadBytesPerFragment, payload.count)
            let flags = command // A3 m/d.g() returns false: requests are unencrypted.
            var packet: [UInt8] = [sequence, (part << 4) | count,
                                   UInt8((flags >> 8) & 0xff), UInt8(flags & 0xff)]
            if lower < upper { packet.append(contentsOf: payload[lower..<upper]) }
            guard packet.count <= maximumFrameBytes else { throw WireError.invalid }
            packets.append(packet)
        }
        // The original constructor advances once. Payload encoding also
        // advances after the final fragment; its empty-payload branch does not.
        if !payload.isEmpty { sequence &+= 1 }
        return packets
    }

    static func parse(_ raw: [UInt8]) -> Fragment? {
        guard (headerBytes...maximumFrameBytes).contains(raw.count) else { return nil }
        let part = raw[1] >> 4, count = raw[1] & 0x0f
        guard part > 0, count > 0, part <= count else { return nil }
        let flags = UInt16(raw[2]) << 8 | UInt16(raw[3])
        return Fragment(part: part, count: count, encrypted: flags & 0x8000 != 0,
                        responseFlag: flags & 0x4000 != 0, command: flags & 0x3fff,
                        payload: Array(raw.dropFirst(headerBytes)))
    }

    private enum WireError: Error { case invalid }
}
