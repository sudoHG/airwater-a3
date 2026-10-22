import SwiftUI
import AppIntents

@main
struct ProbeApp: App {
    init() { A3AppShortcuts.updateAppShortcutParameters() }

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--run-probe")
                || ProcessInfo.processInfo.arguments.contains("--run-dns-probe") {
                ProbeView()
            } else {
                ConnectionView()
            }
        }
    }
}

struct ProbeView: View {
    @State private var report: ProbeReport?
    @State private var savedURL: URL?
    @State private var errorMessage: String?
    @State private var dnsRunning = false
    @State private var dnsReport: DNSProbeReport?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("检查 iPhone 能否提供 A3 所需的本地网络服务。每个端口检查后立即释放。")
                    Text("此页只检查网络端口。日常控制请返回 A3 首页。")
                        .foregroundStyle(.secondary)
                    Button("检查本机端口", action: run)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("run-probe")
                        .disabled(dnsRunning)
                }
                Section("提前启动 DNS 实验") {
                    Text("在热点尚未启用时开始，再连接测试客户端。最多监听 45 秒，仅响应 a3-probe.invalid，完成后自动关闭。其他查询不保存、不转发。")
                        .font(.footnote)
                    Button(dnsRunning ? "正在等待测试请求…" : "启动 45 秒实验", action: runDNS)
                        .disabled(dnsRunning)
                    if let dnsReport {
                        Text("\(dnsReport.phase)，收到测试请求 \(dnsReport.matchingQueryCount) 次，发送 \(dnsReport.responseBytes) 字节")
                            .font(.footnote)
                    }
                }
                if let report {
                    Section("本地网络接口") {
                        if report.interfaces.isEmpty {
                            Text("未检测到 Wi-Fi 或热点的 IPv4 地址。")
                        }
                        ForEach(report.interfaces, id: \.name) { item in
                            LabeledContent(item.name, value: item.address)
                        }
                    }
                    Section("端口结果") {
                        ForEach(report.checks) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(check.address):\(check.port) / \(check.transport)")
                                    .font(.system(.body, design: .monospaced))
                                if check.reuse != "none" {
                                    Text("复用探测：\(check.reuse)").font(.caption)
                                }
                                Text(check.bound ? "可绑定，已立即释放" : "绑定失败：\(check.detail)（\(check.errorCode ?? -1)）")
                                    .foregroundStyle(check.bound ? .green : .secondary)
                                    .font(.footnote)
                            }
                        }
                    }
                    Section {
                        Text("可绑定不等于能够接收热点客户端的 DNS 请求；后者需要另行验证。")
                            .foregroundStyle(.secondary)
                        if let savedURL {
                            ShareLink("导出诊断记录", item: savedURL)
                        }
                        if let errorMessage {
                            Text(errorMessage).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("A3 连接诊断")
        }
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("--run-dns-probe") { runDNS() }
            else if ProcessInfo.processInfo.arguments.contains("--run-probe") { run() }
        }
    }

    private func run() {
        errorMessage = nil
        savedURL = nil
        let result = NetworkProbe.run(systemVersion: UIDevice.current.systemVersion)
        report = result
        do { savedURL = try NetworkProbe.save(result) }
        catch { errorMessage = "保存失败：\(error.localizedDescription)" }
    }

    private func runDNS() {
        guard !dnsRunning else { return }
        dnsRunning = true
        dnsReport = nil
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            let result = await Task.detached { DNSProbe.run() }.value
            dnsReport = result
            dnsRunning = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}
