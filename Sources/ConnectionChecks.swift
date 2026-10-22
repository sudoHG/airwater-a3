import Foundation

/// Opt-in lifecycle checks. Run with the phone hotspot off; no power/fan commands.
enum ConnectionChecks {
    @MainActor
    static func run() async {
        let session = A3LocalSession()
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) {
            checks.append(["name": name, "passed": passed])
        }
        do {
            check("Idle session cannot be mistaken for connected", !session.isRunning && !session.canControl)
            async let first = session.prepareConnection()
            async let second = session.prepareConnection()
            let (one, two) = try await (first, second)
            check("Concurrent prepare calls share one listener generation", one == two && session.isRunning && !session.isStarting)
            check("Local readiness does not mean the A3 is connected", !session.canControl)

            let waiting = Task { try await session.waitForDevice(connectionID: one) }
            await Task.yield()
            waiting.cancel()
            do {
                try await waiting.value
                check("Cancelled wait throws", false)
            } catch { check("Cancelled wait throws", true) }
            check("Cancelled connection releases services", !session.isRunning && !session.isStarting)

            let replacement = try await session.prepareConnection()
            check("Immediate restart gets a new generation", replacement != one && session.isRunning)
            do {
                try await session.waitForDevice(connectionID: one, timeout: 0.1)
                check("Old ticket is rejected", false)
            } catch { check("Old ticket is rejected", true) }
            check("An old wait cannot stop new listeners", session.isRunning)
            do {
                try await session.waitForDevice(connectionID: replacement, timeout: 0.15)
                check("Missing device times out", false)
            } catch { check("Missing device times out", true) }
            check("Timeout clears listeners and device state", !session.isRunning && !session.canControl && session.report.isEmpty)

            let preparation = Task { try await session.prepareConnection() }
            preparation.cancel()
            do {
                _ = try await preparation.value
                check("Cancelled prepare throws", false)
            } catch { check("Cancelled prepare throws", true) }
            check("Cancelled prepare leaves no startup running", !session.isRunning && !session.isStarting)
        } catch {
            check("Lifecycle checks completed: \(error.localizedDescription)", false)
        }
        session.stop(reason: "连接生命周期检查结束，服务已关闭")
        let coordinator = A3ConnectionCoordinator.shared
        do {
            let oldToken = try await coordinator.prepare()
            let oldFinish = Task { try await coordinator.finish(connectionToken: oldToken) }
            await Task.yield()
            coordinator.cancelConnection()
            let newToken = try await coordinator.prepare()
            check("Shortcut runs receive distinct tokens", oldToken != newToken)
            do {
                try await oldFinish.value
                check("Cancelled old finish cannot succeed", false)
            } catch { check("Cancelled old finish cannot succeed", true) }
            check("Old finish cannot clear the new run or its button guard",
                  coordinator.session.isRunning && coordinator.isInvokingShortcut)
            do {
                try await coordinator.finish(connectionToken: oldToken)
                check("Resumed shortcut rejects an old token", false)
            } catch { check("Resumed shortcut rejects an old token", true) }
            check("Stale shortcut rejection preserves new services", coordinator.session.isRunning)

            coordinator.cancelConnection()
            var callbackURL: URL?
            coordinator.runShortcut { url, completion in
                let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "x-error" })?.value
                callbackURL = value.flatMap(URL.init(string:))
                completion(true)
            }
            check("App launch provides an error callback", callbackURL != nil)
            let interruptedToken = try await coordinator.prepare()
            _ = try await coordinator.prepare() // A second run from Shortcuts, without cancel.
            do {
                try await coordinator.finish(connectionToken: interruptedToken)
                check("An interrupted App-launched run rejects its old token", false)
            } catch { check("An interrupted App-launched run rejects its old token", true) }
            if let callbackURL { coordinator.handleCallback(callbackURL) }
            check("A delayed old error callback cannot stop a newer run",
                  coordinator.session.isRunning && coordinator.isInvokingShortcut)

            coordinator.cancelConnection()
            let foregroundToken = try await coordinator.prepare()
            let shortcutAction = Task { @MainActor in
                try coordinator.beginFinishing(connectionToken: foregroundToken)
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await Task.yield()
            shortcutAction.cancel()
            _ = try? await shortcutAction.value
            await Task.yield()
            check("Ending the Shortcut action preserves the foreground connection wait",
                  coordinator.session.isRunning && coordinator.isInvokingShortcut
                    && coordinator.shortcutMessage.hasPrefix("正在等待 A3 连接"))
            try coordinator.beginFinishing(connectionToken: foregroundToken)
            await Task.yield()
            check("Repeated foreground handoff keeps the same services alive",
                  coordinator.session.isRunning && coordinator.isInvokingShortcut)
            coordinator.cancelConnection()
            check("User cancellation stops the foreground connection wait",
                  !coordinator.session.isRunning && !coordinator.isInvokingShortcut)
        } catch {
            check("Shortcut ownership checks completed: \(error.localizedDescription)", false)
        }
        coordinator.cancelConnection()
        let record: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "scope": "Listener lifecycle only; no power or fan commands. Hotspot must be off.",
            "checks": checks,
            "failed": checks.filter { !($0["passed"] as? Bool ?? false) }.count
        ]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("connection-checks.json"), options: .atomic)
        }
    }
}
