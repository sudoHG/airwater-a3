# AirWater A3

**An experimental iPhone local controller for A3 owners affected by service shutdowns and for developers.** It contains source code only; there is no directly installable App Store, TestFlight, IPA, or Release build. Open-sourcing the project does not imply App Store approval.

[简体中文](README.md) · [Build and sign](docs/BUILD.md) · [Protocol](docs/PROTOCOL.md) · [Security](SECURITY.md)

## What the app does

- **Power control:** Turn the A3 on or off and confirm its reported state. Tested on one A3 on 2026-09-27, including reconnecting after an app relaunch.
- **Device status:** View power, onboard humidity, an online external sensor's humidity, target humidity, and low-water protection. Target humidity is read-only.
- **Bluetooth setup:** Find nearby A3 devices and send the phone's hotspot name and password to the selected unit, including when changing hotspots. The provisioning flow is implemented; compatibility across devices and firmware remains unverified.
- **Shortcut-assisted reconnect:** After provisioning and adding the Shortcut, tap the connection button to prepare the hotspot connection and return to the control page. A manual connection path is also available. Reconnection succeeded twice on one iPhone 17 Pro Max running iOS 27.0 on 2026-09-29.
- **Mode and fan speed:** Controls for manual, automatic, and sleep modes, plus 0–100% manual fan speed, disabled during low-water protection. **Normal operation has not been verified.**
- **Connection diagnostics:** View connection events and client count, and request the current device state to help troubleshoot connectivity.

These are limited tests on specific hardware, not a compatibility guarantee or full feature acceptance. Other A3 firmware, iPhone models, and OS versions remain unverified. Each control session lasts about 10 minutes and requires the app to remain in the foreground. This is not an always-on background service.

## Device screenshot

<a href="docs/images/a3-connected.png"><img src="docs/images/a3-connected.png" alt="AirWater A3 on an iPhone: connected with power off, humidity readings and low-water protection displayed, mode and fan controls disabled" width="360"></a>

Captured on an iPhone on 2026-09-29; click for full resolution. The A3 was connected, powered off, and reporting low-water protection, so mode and fan controls are disabled. This shows actual state readback, not verified humidification or fan adjustment. Only file metadata was removed; the UI image is unchanged. The app interface is currently in Chinese.

## How it works

The app binds UDP port 53 before Personal Hotspot starts, resolving `i.airmx.cn` and `awm.airmx.cn` to the phone's hotspot address. The A3 then connects to local HTTP port 80 and MQTT port 1883. First-time setup also uses Bluetooth to provision the A3 with the hotspot credentials. Enable **Maximize Compatibility** manually on the iPhone.

No NAS, Home Assistant, or device disassembly is required. An optional Shortcut helps reconnect in this order: turn off the hotspot, prepare the A3 connection, turn on the hotspot, then open the A3 control page, passing the output from “Prepare A3 connection” to the final action. You can also create these four actions manually. See the [build and installation guide](docs/BUILD.md) for generating a signed Shortcut. The Mac is only needed for building and USB installation; keep it on its existing network rather than joining the phone's hotspot.

## Build from source

Building requires Xcode 27 because the source uses iOS 27 SDK APIs. The project deployment target is iOS 16, but older systems have not been tested. Opening the project does not provide a ready-to-install signed app; see the [build and installation guide](docs/BUILD.md) for signing and installation steps.

```sh
git clone https://github.com/sudoHG/airwater-a3.git
cd airwater-a3
make generate
open AirwaterProbe.xcodeproj
```

## Limits and safety

- The local DNS server currently rejects other domains. Do not connect other devices to the same Personal Hotspot. The bundled broker serves only the local control link; it is not a public or multi-tenant service.
- Exiting the app disconnects the control session; it does not turn off the A3. Check the device as described by the manufacturer before leaving it unattended.
- Do not bypass device protections. Follow the manufacturer's instructions for cleaning and water levels.
- Do not submit Wi-Fi passwords, device keys, full Flash images, packet captures, or personal logs. See [SECURITY.md](SECURITY.md) for security-reporting guidance.

See the [protocol documentation](docs/PROTOCOL.md) for protocol and implementation details. Contributions may include publicly shareable, non-sensitive stock firmware application partitions or leads about server configuration and OTA paths. Read the security guidance before opening an Issue or PR; do not include credentials or personally identifying information.

## Community references

These independent community projects are provided for reference only. This project is not affiliated with their authors or the device manufacturer, and does not include original-vendor APKs or firmware:

- [dext0r/airmx](https://github.com/dext0r/airmx)
- [oladoga/AIRMX-Setup](https://github.com/oladoga/AIRMX-Setup)
- [denniszmq/airmx-a3-local-firmware](https://github.com/denniszmq/airmx-a3-local-firmware)

This repository is released under the MIT License. Licensing and rights for third-party projects and materials remain governed by their respective repositories.
