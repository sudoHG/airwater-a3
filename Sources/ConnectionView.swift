import SwiftUI

struct ConnectionView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = A3ConnectionCoordinator.shared.session
    @StateObject private var coordinator = A3ConnectionCoordinator.shared
    @StateObject private var bluetooth = A3Bluetooth()
    @State private var hotspotName = ""
    @State private var hotspotPassword = ""
    @State private var didAutostart = false
    @State private var fan = 0.0
    @State private var editingFan = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(session.canControl ? "A3 已连接" : "连接你的 A3", systemImage: session.canControl ? "checkmark.circle.fill" : "wifi")
                        .font(.title2.bold()).foregroundStyle(session.canControl ? .green : .primary)
                    Text(session.canControl ? "手机已收到加湿器的真实状态，可以直接控制。" : "点一次连接，自动准备手机热点并接入已配网的 A3。")
                        .foregroundStyle(.secondary)
                }
                if !session.report.isEmpty {
                    Section("加湿器状态") {
                        if let power = session.report["power"] {
                            LabeledContent("电源", value: power == 1 ? "已开机" : "已关机")
                        }
                        if let humidity = session.report["h0"], (0...10000).contains(humidity) {
                            LabeledContent("机身湿度", value: String(format: "%.1f%%", Double(humidity) / 100))
                        }
                        if session.report["gooseOnline"] == 1, let humidity = session.report["h"], (0...10000).contains(humidity) {
                            LabeledContent("外置传感器湿度", value: String(format: "%.1f%%", Double(humidity) / 100))
                        }
                        if let target = session.report["hThreshold"] {
                            LabeledContent("目标湿度", value: "\(target)%")
                        }
                        if session.report["mode"] == 5 {
                            Text("设备提示水量不足，当前处于缺水保护。")
                                .foregroundStyle(.orange)
                        }
                        HStack {
                            Button { session.setPower(true) } label: { Label("开机", systemImage: "power") }
                            Spacer()
                            Button("关机") { session.setPower(false) }
                        }
                        .buttonStyle(.bordered)
                        .disabled(!session.canControl || session.isSendingControl)
                        if !session.commandStatus.isEmpty {
                            Text(session.commandStatus).font(.footnote)
                        }
                    }
                    operationSection
                }
                connectionSection
                Section {
                    DisclosureGroup("连接诊断") {
                        Text("设备消息连接数：\(session.connectedClients)")
                        if session.canRequestStatus {
                            Button("读取当前设备状态") { session.requestStatus() }
                        }
                        if let type = session.registeredType { Text("设备型号代码：\(type)") }
                        Text("已收到设置字段：\(session.settingsReport.count)")
                        ForEach(Array(session.events.enumerated()), id: \.offset) { _, text in
                            Text(text).font(.caption).textSelection(.enabled)
                        }
                        NavigationLink("研发端口检查") { ProbeView() }
                            .disabled(session.isRunning)
                    }
                }
            }
            .navigationTitle("AirWater A3")
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background { session.enteredBackground() }
            if phase == .active { session.becameActive() }
        }
        .onOpenURL { coordinator.handleCallback($0) }
        .onReceive(bluetooth.$status.removeDuplicates()) { status in
            session.recordBluetooth(status: status)
        }
        .onChange(of: session.report["cadr"]) { value in
            if !editingFan, let value, (0...100).contains(value) { fan = Double(value) }
        }
        .onAppear {
            guard !didAutostart else { return }
            didAutostart = true
            if ProcessInfo.processInfo.arguments.contains("--run-passive-ble-scan") {
                bluetooth.startPassiveScanDiagnostic()
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--run-self-check") {
                _ = ProtocolChecks.run()
            }
            if ProcessInfo.processInfo.arguments.contains("--run-connection-checks") {
                Task { await ConnectionChecks.run() }
            }
            if ProcessInfo.processInfo.arguments.contains("--run-local-server") {
                session.start(duration: 600)
            }
        }
    }

    private var operationSection: some View {
        Section("运行设置") {
            Picker("工作模式", selection: Binding(
                get: { session.report["mode"] ?? 1 },
                set: { session.setMode($0) }
            )) {
                if session.report["mode"] == 5 { Text("缺水保护").tag(5) }
                Text("手动").tag(0)
                Text("自动").tag(1)
                Text("睡眠").tag(2)
            }
            .disabled(!session.canAdjustOperation)
            VStack(alignment: .leading) {
                LabeledContent("手动风量", value: "\(Int(fan))%")
                Slider(value: $fan, in: 0...100, step: 1) { editing in
                    editingFan = editing
                    if !editing { session.setFan(Int(fan)) }
                }
                .accessibilityLabel("手动风量")
                .disabled(!session.canAdjustOperation)
            }
            Text(session.report["mode"] == 5 ? "加水并恢复正常后，可调节模式和风量。" : "调节风量会切换到手动模式。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        Section("手机连接") {
            if !session.canControl {
                Button("一键连接 A3") { coordinator.runShortcut() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("one-tap-connect")
                    .disabled(session.isStarting || coordinator.isInvokingShortcut)
                Text("首次使用需添加「连接 A3」快捷指令，并完成下方配网。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let shortcutURL = Bundle.main.url(forResource: "连接 A3", withExtension: "shortcut") {
                    ShareLink("添加「连接 A3」快捷指令", item: shortcutURL)
                }
            }
            if !coordinator.shortcutMessage.isEmpty {
                Text(coordinator.shortcutMessage).font(.footnote)
            }
            Text(coordinator.isInvokingShortcut && session.isRunning ? "请保持此页面打开，等待加湿器接入。" : session.status)
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("connection-status")
            if session.isRunning || session.isStarting || coordinator.isInvokingShortcut {
                Text("控制时保持 App 在前台。本轮最长 10 分钟，结束后关闭热点。热点只连接 A3。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("结束本轮连接", role: .destructive) {
                    bluetooth.disconnect()
                    coordinator.cancelConnection()
                }
            } else {
                DisclosureGroup("手动连接") {
                    Text("关闭个人热点后点下方按钮，等服务就绪，再开启热点并返回。首次使用请在系统设置开启“最大兼容性”。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("准备本地服务") { session.start() }
                }
            }
            NavigationLink("首次配网或更换手机热点") { provisioningView }
        }
    }

    private var provisioningView: some View {
        Form {
            Section {
                Text("只需设置一次。以后热点名称和密码不变，就不必重复配网。")
                if !session.isRunning {
                    Text("请先返回首页开始连接，再开启个人热点。")
                        .foregroundStyle(.orange)
                }
            }
            Section("1 · 选择加湿器") {
                Button("查找附近的 A3") { bluetooth.scan() }
                    .disabled(!session.isRunning)
                Text(bluetooth.status).font(.footnote)
                ForEach(bluetooth.devices) { device in
                    Button(device.name) { bluetooth.connect(to: device) }
                        .disabled(!session.isRunning)
                }
            }
            Section("2 · 连接手机热点") {
                TextField("个人热点名称（iPhone 名称）", text: $hotspotName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("个人热点的 Wi-Fi 密码", text: $hotspotPassword)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Text("凭据只通过蓝牙发送给选中的 A3；发送后清空密码。加湿器会改连此热点。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("让 A3 连接这个热点") {
                    bluetooth.provision(ssid: hotspotName, password: hotspotPassword)
                    hotspotPassword = ""
                }
                .disabled(!session.isRunning || !bluetooth.canProvision || hotspotName.isEmpty || hotspotPassword.isEmpty)
            }
        }
        .navigationTitle("首次配网")
    }
}
