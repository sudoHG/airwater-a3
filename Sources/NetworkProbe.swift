import Darwin
import Foundation

struct InterfaceAddress: Codable {
    let name: String
    let address: String
    var netmask: String? = nil
}

struct PortProbe: Codable, Identifiable {
    var id: String { "\(address):\(port)/\(transport)/\(reuse)" }
    let address: String
    let port: UInt16
    let transport: String
    let reuse: String
    let bound: Bool
    let errorCode: Int32?
    let detail: String
}

struct ProbeReport: Codable {
    let timestamp: String
    let systemVersion: String
    let interfaces: [InterfaceAddress]
    let checks: [PortProbe]
    let limitation: String
}

enum NetworkProbe {
    static func interfaces() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let item = current.pointee
            defer { cursor = item.ifa_next }
            guard let raw = item.ifa_addr, Int32(raw.pointee.sa_family) == AF_INET else {
                continue
            }
            let name = String(cString: item.ifa_name)
            // Retain local Wi-Fi/bridge interfaces, not carrier/VPN addresses.
            guard name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("ap") else {
                continue
            }
            var storage = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(raw, socklen_t(MemoryLayout<sockaddr_in>.size),
                                     &storage, socklen_t(storage.count), nil, 0, NI_NUMERICHOST)
            if status == 0 {
                var mask: String?
                if let rawMask = item.ifa_netmask {
                    var maskStorage = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(rawMask, socklen_t(MemoryLayout<sockaddr_in>.size),
                                   &maskStorage, socklen_t(maskStorage.count), nil, 0, NI_NUMERICHOST) == 0 {
                        mask = String(cString: maskStorage)
                    }
                }
                result.append(InterfaceAddress(name: name, address: String(cString: storage), netmask: mask))
            }
        }
        return result.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }

    static func hotspotContains(_ address: String) -> Bool {
        func ipv4(_ value: String) -> UInt32? {
            let fields = value.split(separator: ".")
            let octets = fields.compactMap { UInt8($0) }
            guard fields.count == 4, octets.count == 4 else { return nil }
            return octets.reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard let peer = ipv4(address) else { return false }
        return interfaces().contains { item in
            guard item.name.hasPrefix("bridge") || item.name.hasPrefix("ap"),
                  let local = ipv4(item.address), let textMask = item.netmask,
                  let mask = ipv4(textMask), peer != local else { return false }
            let network = local & mask
            return (peer & mask) == network && peer != network && peer != (network | ~mask)
        }
    }

    static func bindOnce(address: String, port: UInt16, udp: Bool, reuse: String = "none") -> PortProbe {
        let transport = udp ? "UDP" : "TCP"
        let descriptor = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            let code = errno
            return PortProbe(address: address, port: port, transport: transport, reuse: reuse,
                             bound: false, errorCode: code, detail: String(cString: strerror(code)))
        }
        defer { close(descriptor) }
        // Only configure this app's fresh socket. No system socket is changed.
        for option in [("address", SO_REUSEADDR), ("port", SO_REUSEPORT)] {
            if reuse == option.0 || reuse == "address+port" {
                var enabled: Int32 = 1
                if setsockopt(descriptor, SOL_SOCKET, option.1, &enabled,
                              socklen_t(MemoryLayout<Int32>.size)) != 0 {
                    let code = errno
                    return PortProbe(address: address, port: port, transport: transport, reuse: reuse,
                                     bound: false, errorCode: code,
                                     detail: "setsockopt: " + String(cString: strerror(code)))
                }
            }
        }
        var endpoint = sockaddr_in()
        endpoint.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        endpoint.sin_family = sa_family_t(AF_INET)
        endpoint.sin_port = port.bigEndian
        guard address.withCString({ inet_pton(AF_INET, $0, &endpoint.sin_addr) }) == 1 else {
            return PortProbe(address: address, port: port, transport: transport, reuse: reuse,
                             bound: false, errorCode: nil, detail: "Invalid IPv4 address")
        }
        // Do not change routes, listen, send or receive. Close immediately.
        let status = withUnsafePointer(to: &endpoint) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        let code = status == 0 ? nil : errno
        return PortProbe(address: address, port: port, transport: transport, reuse: reuse,
                         bound: status == 0, errorCode: code,
                         detail: code.map { String(cString: strerror($0)) } ?? "bind succeeded; socket closed immediately")
    }

    static func run(systemVersion: String) -> ProbeReport {
        let local = interfaces()
        let targets = ["0.0.0.0"] + Array(Set(local.map(\.address))).sorted()
        var checks = targets.flatMap { address in
            [(UInt16(53), true), (53, false), (80, false), (1883, false), (8017, true)].map {
                bindOnce(address: address, port: $0.0, udp: $0.1)
            }
        }
        // Bounded follow-up after hotspot activation made DNS port 53 busy.
        // Successful sharing would still require a separate traffic test.
        let dnsTargets = ["0.0.0.0"] + local.filter { $0.name.hasPrefix("bridge") }.map(\.address)
        for address in dnsTargets {
            for reuse in ["address", "port", "address+port"] {
                checks.append(bindOnce(address: address, port: 53, udp: true, reuse: reuse))
            }
        }
        return ProbeReport(timestamp: ISO8601DateFormatter().string(from: Date()),
                           systemVersion: systemVersion, interfaces: local, checks: checks,
                           limitation: "Binding a port does not prove that hotspot client traffic reaches the app. No A3 control was attempted.")
    }

    static func save(_ report: ProbeReport) throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("probe.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }
}
