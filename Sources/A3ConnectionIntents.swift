import AppIntents
import SwiftUI

/// The UI and both shortcut actions use the same main-app session.
@MainActor
final class A3ConnectionCoordinator: ObservableObject {
    static let shared = A3ConnectionCoordinator()
    let session = A3LocalSession()
    @Published private(set) var shortcutMessage = ""
    @Published private(set) var isInvokingShortcut = false
    private var preparedConnectionID: UUID?
    private var activeRunID: UUID?
    private var shortcutAttempt: UUID?
    private var callbackWatchdog: Task<Void, Never>?
    private var connectionWaitTask: Task<Void, Never>?

    private init() {}

    func cancelConnection() {
        connectionWaitTask?.cancel()
        connectionWaitTask = nil
        callbackWatchdog?.cancel()
        callbackWatchdog = nil
        shortcutAttempt = nil
        activeRunID = nil
        preparedConnectionID = nil
        isInvokingShortcut = false
        shortcutMessage = "连接已结束。"
        session.stop()
    }

    func prepare() async throws -> String {
        try Task.checkCancellation()
        connectionWaitTask?.cancel()
        connectionWaitTask = nil
        let runID = UUID()
        // Once an Intent takes ownership, only its run token may finish/stop it.
        // An older x-callback URL cannot identify a newer direct Shortcuts run.
        shortcutAttempt = nil
        activeRunID = runID
        preparedConnectionID = nil
        isInvokingShortcut = true
        shortcutMessage = "正在准备连接…"
        callbackWatchdog?.cancel()
        callbackWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) }
            catch { return }
            guard let self, self.activeRunID == runID, self.isInvokingShortcut else { return }
            self.cancelConnection()
            self.shortcutMessage = "连接流程未完成，请重新点击连接。"
        }
        // Each shortcut invocation owns a generation, including a resumed old flow.
        session.stop(reason: "正在重新准备连接")
        do {
            let ticket = try await session.prepareConnection()
            guard activeRunID == runID else { throw CancellationError() }
            preparedConnectionID = ticket
            shortcutMessage = "服务已就绪，快捷指令正在开启热点…"
            return runID.uuidString
        } catch {
            if activeRunID == runID {
                preparedConnectionID = nil
                isInvokingShortcut = false
                shortcutMessage = error.localizedDescription
            }
            throw error
        }
    }

    /// The last Shortcut action hands off to the foreground app. Its process-wide
    /// task survives Shortcuts ending; only a verified A3 report marks success.
    func beginFinishing(connectionToken: String) throws {
        guard let runID = UUID(uuidString: connectionToken), runID == activeRunID,
              preparedConnectionID != nil else { throw ConnectionError.notPrepared }
        guard connectionWaitTask == nil else { return }
        connectionWaitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.finish(connectionToken: connectionToken, timeout: 90) }
            catch { /* finish has already published the current run's failure. */ }
        }
    }

    func finish(connectionToken: String, timeout: TimeInterval = 45) async throws {
        guard let runID = UUID(uuidString: connectionToken), runID == activeRunID,
              let connectionID = preparedConnectionID else {
            throw ConnectionError.notPrepared
        }
        defer {
            if activeRunID == runID {
                isInvokingShortcut = false
                callbackWatchdog?.cancel()
                callbackWatchdog = nil
                connectionWaitTask = nil
            }
        }
        shortcutMessage = "正在等待 A3 连接…"
        do {
            try await session.waitForDevice(connectionID: connectionID, timeout: timeout)
            guard activeRunID == runID else { throw CancellationError() }
            shortcutMessage = "A3 已连接"
        } catch {
            if activeRunID == runID {
                preparedConnectionID = nil
                shortcutMessage = error is CancellationError ? "连接已取消，请重新连接。" : error.localizedDescription
            }
            throw error
        }
    }

    func runShortcut() {
        runShortcut { url, completion in
            UIApplication.shared.open(url, completionHandler: completion)
        }
    }

    func runShortcut(open: (URL, @escaping @MainActor @Sendable (Bool) -> Void) -> Void) {
        guard !isInvokingShortcut else { return }
        isInvokingShortcut = true
        let attempt = UUID()
        shortcutAttempt = attempt
        callbackWatchdog?.cancel()
        callbackWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 120_000_000_000) }
            catch { return }
            guard let self, self.shortcutAttempt == attempt, self.isInvokingShortcut else { return }
            self.cancelConnection()
            self.shortcutMessage = "连接流程未完成，请重新点击连接。"
        }
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "x-callback-url"
        components.path = "/run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: "连接 A3")]
        for outcome in ["success", "cancel", "error"] {
            let callback = "a3local://shortcut/\(outcome)?attempt=\(attempt.uuidString)"
            components.queryItems?.append(URLQueryItem(name: "x-\(outcome)", value: callback))
        }
        guard let url = components.url else {
            isInvokingShortcut = false
            return
        }
        shortcutMessage = "正在打开「连接 A3」快捷指令…"
        open(url) { [weak self] opened in
            Task { @MainActor in
                guard let self, self.shortcutAttempt == attempt, !opened else { return }
                self.shortcutAttempt = nil
                self.isInvokingShortcut = false
                self.callbackWatchdog?.cancel()
                self.shortcutMessage = "无法打开快捷指令，请先添加「连接 A3」。"
            }
        }
    }

    func handleCallback(_ url: URL) {
        guard url.scheme == "a3local", url.host == "shortcut",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "attempt" })?.value,
              let attempt = UUID(uuidString: value), attempt == shortcutAttempt else { return }
        shortcutAttempt = nil
        isInvokingShortcut = false
        callbackWatchdog?.cancel()
        callbackWatchdog = nil
        switch url.path {
        case "/success":
            // A system callback alone is not evidence that the A3 is connected.
            shortcutMessage = session.canControl ? "A3 已连接" : "流程已返回，尚未确认 A3 连接。请重新连接。"
        case "/cancel", "/error":
            activeRunID = nil
            preparedConnectionID = nil
            session.stop(reason: "连接流程已中止，本地服务已关闭")
            shortcutMessage = url.path == "/cancel" ? "已取消连接。" : "快捷指令未完成，请确认已添加「连接 A3」后重试。"
        default: break
        }
    }

    enum ConnectionError: LocalizedError {
        case notPrepared
        var errorDescription: String? {
            "连接准备已失效，请重新运行完整的「连接 A3」快捷指令。"
        }
    }
}

struct PrepareA3ConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "准备 A3 连接"
    static let description = IntentDescription("在快捷指令关闭个人热点后运行。等待本地服务就绪，再执行开启个人热点的下一步。")
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let token = try await A3ConnectionCoordinator.shared.prepare()
        return .result(value: token)
    }
}

struct FinishA3ConnectionIntent: AppIntent {
    static let title: LocalizedStringResource = "打开 A3 控制页"
    static let description = IntentDescription("在快捷指令开启个人热点后运行。由 App 前台等待 A3 回报经过验证的状态；不会启动加湿。")
    static let openAppWhenRun = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "连接编号", inputConnectionBehavior: .connectToPreviousIntentResult)
    var connectionToken: String

    @MainActor
    func perform() async throws -> some IntentResult {
        try A3ConnectionCoordinator.shared.beginFinishing(connectionToken: connectionToken)
        return .result()
    }
}

struct A3AppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrepareA3ConnectionIntent(),
                    phrases: ["准备 \(.applicationName) 连接"],
                    shortTitle: "准备 A3 连接", systemImageName: "wifi")
    }
}
