import Foundation

enum ProtocolChecks {
    @MainActor
    static func run() -> [String: Any] {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        func query(_ name: String, type: UInt8 = 1) -> [UInt8] {
            var bytes: [UInt8] = [0xAB, 0xCD, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]
            for label in name.split(separator: ".") { bytes += [UInt8(label.utf8.count)] + label.utf8 }
            return bytes + [0, 0, type, 0, 1]
        }
        let dns = LocalDNSServer.answer(query("i.airmx.cn"), address: "172.20.10.1")
        check("DNS maps only intended A record", dns?.bytes.suffix(4) == [172, 20, 10, 1] && dns?.hasAddress == true)
        let other = LocalDNSServer.answer(query("unrelated.invalid"), address: "172.20.10.1")
        check("Unrelated DNS names are neither recorded nor redirected", other?.loggedName == nil && other?.hasAddress == false && other?.bytes[3] == 5)
        let waiting = LocalDNSServer.answer(query("awm.airmx.cn"), address: nil)
        check("Absent hotspot returns failure instead of a guessed IP", waiting?.bytes[3] == 2 && waiting?.hasAddress == false)
        let ipv6 = LocalDNSServer.answer(query("i.airmx.cn", type: 28), address: "172.20.10.1")
        check("AAAA does not receive an IPv4 A answer", ipv6?.bytes[3] == 0 && ipv6?.hasAddress == false)
        check("Truncated DNS is rejected", LocalDNSServer.answer(Array(query("i.airmx.cn").dropLast()), address: "172.20.10.1") == nil)
        var compressed = query("i.airmx.cn")
        compressed[12] = 0xC0
        check("Question pointer is not followed", LocalDNSServer.answer(compressed, address: "172.20.10.1") == nil)
        let request = Data("POST /probe HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello".utf8)
        let incomplete = try? HTTPServer.parse(Data(request.dropLast()))
        check("Partial HTTP body waits for more bytes", incomplete == nil)
        let complete = try? HTTPServer.parse(request)
        check("Complete HTTP body is preserved", complete?.body == Data("hello".utf8) && complete?.path == "/probe")
        do {
            _ = try HTTPServer.parse(Data("POST / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx".utf8))
            check("Ambiguous duplicate lengths are rejected", false)
        } catch { check("Ambiguous duplicate lengths are rejected", true) }
        do {
            _ = try HTTPServer.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8))
            check("Unsupported chunked requests are rejected", false)
        } catch { check("Unsupported chunked requests are rejected", true) }
        check("Community ID byte order", A3LocalSession.registrationID(mac: "A1B2C3D4E5F6") == 45729)
        check("Malformed MAC rejected", A3LocalSession.registrationID(mac: "zzzzzzzzzzzz") == nil)
        let command = A3LocalSession.powerPayload(values: ["power": 1, "mode": 0, "cadr": 30, "waterflood": 0, "lock": 0, "anion": 1],
                                                 time: 1_700_000_000, key: "fixture-key")
        let commandText = String(data: command, encoding: .utf8)!
        check("Original field order produces independent MD5 fixture", commandText.hasSuffix(",\"sig\":\"8d559e8ac03a59ae47716c4969a85460\"}"))
        check("Signature is valid only for matching key", A3LocalSession.verifyReportSignature(command, key: "fixture-key") && !A3LocalSession.verifyReportSignature(command, key: "wrong-key"))
        let tampered = Data(commandText.replacingOccurrences(of: "\"power\":1", with: "\"power\":0").utf8)
        check("Payload changes invalidate signature", !A3LocalSession.verifyReportSignature(tampered, key: "fixture-key"))
        let appended = Data((commandText.dropLast() + ",\"data\":{\"power\":0}}").utf8)
        check("Unsigned fields after sig are rejected", !A3LocalSession.verifyReportSignature(appended, key: "fixture-key"))
        let requestStatus = String(data: A3LocalSession.statusRequestPayload(time: 1_700_000_000, key: "fixture-key"), encoding: .utf8)!
        check("Status request matches independent MD5 fixture", requestStatus.hasSuffix(",\"sig\":\"478e91eed936b510d596911e3fa4d0e8\"}"))
        check("Status request leaves water and cleaning configuration absent", !requestStatus.contains("waterType") && !requestStatus.contains("cleanTime") && requestStatus.contains("\"cmdId\":1008"))
        let commandPrefix = "airwater/01/1/0/1/"
        check("Only exact positive device topics can supply an identity", A3LocalSession.deviceID(in: commandPrefix + "12345", prefix: commandPrefix) == 12345
              && ["0", "-1", "123/#", "123/4", "4294967296"].allSatisfy { A3LocalSession.deviceID(in: commandPrefix + $0, prefix: commandPrefix) == nil })
        check("A device subscription wildcard is matched against its own command topic", MQTTBroker.topicMatches(filter: "airwater/01/+/0/1/12345", topic: commandPrefix + "12345")
              && !MQTTBroker.topicMatches(filter: "airwater/01/+/0/1/99999", topic: commandPrefix + "12345"))
        check("Topic diagnostics remove device identifiers", A3LocalSession.redactedTopic(commandPrefix + "12345") == commandPrefix + "<设备>")
        let capturedReport = ["power": 1, "mode": 5, "cadr": 0, "lock": 0, "anion": 0]
        let compatible = A3LocalSession.powerValues(from: capturedReport, enabled: false)
        check("Actual A3 report missing waterflood follows Android optInt default", compatible == ["power": 0, "mode": 1, "cadr": 0, "lock": 0, "anion": 0, "waterflood": 0])
        check("Missing required control state still blocks a command", A3LocalSession.powerValues(from: ["power": 1], enabled: false) == nil)
        let manualReport = ["power": 0, "mode": 1, "cadr": 35, "waterflood": 0, "lock": 1, "anion": 0]
        check("Changing mode preserves power, speed and other control settings", A3LocalSession.operationValues(from: manualReport, mode: 2) == ["power": 0, "mode": 2, "cadr": 35, "waterflood": 0, "lock": 1, "anion": 0])
        check("Changing fan selects manual and preserves other settings", A3LocalSession.operationValues(from: manualReport, mode: 0, fan: 50) == ["power": 0, "mode": 0, "cadr": 50, "waterflood": 0, "lock": 1, "anion": 0])
        check("Protection state and out-of-range operation changes are blocked", A3LocalSession.operationValues(from: capturedReport, mode: 1) == nil
              && A3LocalSession.operationValues(from: manualReport, mode: 5) == nil
              && [-1, 101].allSatisfy { A3LocalSession.operationValues(from: manualReport, mode: 0, fan: $0) == nil })
        for (name, passed) in A3Bluetooth.offlineChecks() { check(name, passed) }
        let value: [String: Any] = ["timestamp": ISO8601DateFormatter().string(from: Date()),
                                    "checks": checks, "failed": checks.filter { !($0["passed"] as? Bool ?? false) }.count,
                                    "scope": "Synthetic parser checks only; no real A3 control"]
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("protocol-checks.json"), options: .atomic)
        }
        return value
    }
}
