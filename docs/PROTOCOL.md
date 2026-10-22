# Protocol notes

This document describes the current implementation, not a complete manufacturer specification. No device identifiers, real keys, captures, original app packages or firmware images are included.

## Transport

1. BLE provisions the chosen A3 with the iPhone's Personal Hotspot SSID/password.
2. The app binds UDP 53 before the hotspot starts. DNS requests for `i.airmx.cn` and `awm.airmx.cn` receive the phone's current hotspot IPv4 address.
3. A local HTTP server listens on TCP 80. `/gettime` returns time; `/aw?path=aw/GET/genId` processes registration and returns an `awId`.
4. A small MQTT 3.1/3.1.1 broker listens on TCP 1883. Reports and controls use the device's topics and the legacy message signature.

The broker deliberately omits full MQTT authentication, persistence, retained messages and QoS 2. It is not a drop-in broker for untrusted clients. DNS refuses unrelated names rather than forwarding them. See [SECURITY.md](../SECURITY.md).

## BLE

| Item | Value |
| --- | --- |
| Service | `22210000-554A-4546-5542-46534450464D` |
| Write | `22210001-554A-4546-5542-46534450464D` |
| Notify | `22210002-554A-4546-5542-46534450464D` |
| Known commands, decimal | 11 handshake/bind; 21 Wi-Fi provisioning; 22 device ID |

These are protocol constants, not private device identifiers. Command 11 is a state-changing handshake, not a read-only capability query. A shared BLE service UUID with other Qingping products does not prove compatibility with their packet framing or commands.

## Application messages

`A3LocalSession.swift` contains parsing, signature checking and command serialization. `ProtocolChecks.swift` contains synthetic fixtures, including an independently calculated expected MD5, framing checks and safeguards against incomplete state. The MD5 signature preserves compatibility with the original protocol and must not be described as modern transport encryption or sufficient proof of ownership.

The current registration ID helper follows the community byte-order convention. This is a single-device prototype; do not use that derived ID as a globally collision-free identity for a shared cloud.

## What remains unknown

- A supported stock-firmware method to permanently change HTTP/MQTT endpoints.
- A verified original OTA trigger, download/validation procedure and safe first wireless installation of alternative firmware.
- Direct BLE runtime control, beyond the known provisioning flow.
- Cross-device reliability of the pre-bound DNS socket, other clients' DNS behavior and recovery after the app exits.

The existing phone hotspot implementation does not permanently rewrite the endpoints stored in the A3. A community firmware's own OTA endpoint does not demonstrate an OTA entry point in stock firmware.

## Sources and attribution

- [dext0r/airmx](https://github.com/dext0r/airmx): Home Assistant integration and local HTTP/MQTT server behavior; useful protocol reference.
- [oladoga/AIRMX-Setup](https://github.com/oladoga/AIRMX-Setup): community setup/provisioning reference.
- [denniszmq/airmx-a3-local-firmware](https://github.com/denniszmq/airmx-a3-local-firmware): separate replacement firmware and wired-installation research; not bundled here.
- [Apple Shortcuts x-callback-url](https://support.apple.com/guide/shortcuts/apdcd7f20a6f/ios): documented app-to-Shortcuts handoff.
- [Apple DTS on Personal Hotspot](https://developer.apple.com/forums/thread/702058): hotspot is a user feature without a supported developer configuration API; the working prototype is not a compatibility or App Review guarantee.

MIT covers the original files distributed in this repository. It does not relicense upstream projects, proprietary apps, firmware, logos or trademarks. No upstream source tree, APK or firmware binary is redistributed. Contributions that copy third-party code must preserve its notices and establish license compatibility.
