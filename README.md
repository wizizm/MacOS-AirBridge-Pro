# Tiwut AirBridge Pro

AirBridge Pro is a native, high-performance, ultra-lightweight macOS desktop application written in **Swift** and **SwiftUI**. It acts as a comprehensive network control dashboard, visualizer, and Wi-Fi repeater bridge manager—**running entirely client-side without any background servers, Node.js nodes, or web wrappers**.

The application operates in real-time, defaulting to a gorgeous **`860x640` glassmorphic window** that is fully **resizable** to accommodate larger displays and resolve clipping. It packages automatically with a custom App Icon and a dedicated Developer profile section for **Tiwut**.

UI language follows the system preferred language: any `zh*` locale uses Simplified Chinese; otherwise English (`L10n.swift` / `AppLanguage.resolve`).

---

## Features

AirBridge Pro wraps low-level macOS system diagnostics and packet daemons (`pfctl`, `dnctl`, `tcpdump`, `defaults`) inside a secure administrative privilege manager:

1. **One-Click Integrated Hotspot Toggler:** Dynamically writes to `/Library/Preferences/SystemConfiguration/com.apple.nat.plist` to bridge incoming internet (e.g. `en0`) to a secondary AP adapter (e.g. `en1`), loading the sharing daemon with a single secure prompt.
2. **WLAN Telemetry & Channel Analyzer:** Displays active RSSI signal (dBm), Noise (dBm), SNR, live Link Tx Rate (Mbps), radio channel, and PHY mode (e.g. Wi-Fi 6) utilizing the native `CoreWLAN` framework.
3. **Active Client Firewall Blocker:** Instantly blocks or kicks devices from the bridge network by inserting drop rules into the macOS Packet Filter (`pfctl`) anchor list.
4. **Data Speedometer & Bandwidth Meter:** Computes real-time download and upload speeds (KB/s) and tracks cumulative traffic (MB) via `getifaddrs` byte counters.
5. **Fast DNS Server Redirects:** Toggles shared clients DNS configuration between defaults, Cloudflare Fast DNS, Google Public DNS, or AdGuard (AdBlocker) DNS by updating `bootpd.plist` dynamically.
6. **Port Forwarding Redirection Manager:** Maps external ports on your Mac directly to internal client IP addresses using custom `pfctl` NAT redirects.
7. **Local Packet Sniffer Terminal Console:** A live-buffered console snoop that captures active IP packet communication on the bridge interface via `tcpdump`.
8. **Bandwidth Shaper & Traffic Limiter:** Capping client bandwidth (Unlimited, 2, 5, or 10 Mbps) using macOS `dnctl` (dummynet) pipelines.
9. **Latency Quality Diagnostics:** Active round-trip time (RTT) ping latency and packet drop check tools.
10. **DHCP Static IP Reservations:** Permanently registers client MAC addresses to desired private IPs inside `/etc/bootpd.plist`.

---

## Project Anatomy

* **`main.swift`:** AppKit shell, CLI parsers, AppleScript escalation, and SwiftUI dashboard.
* **`L10n.swift`:** Bilingual UI strings (English / Simplified Chinese) keyed via `L10n.text` / `L10n.format`.
* **`PhyModeLabel.swift`:** CoreWLAN PHY mode → label mapping via rawValue (works without SDK `.mode11be`).
* **`IfconfigParser.swift`:** Pure parsers for `ifconfig` plus `getifaddrs` byte counters (unit-tested).
* **`build.sh`:** Portable build (script-relative paths), icon packaging, `Info.plist`, and `swiftc` for host `arm64`/`x86_64` at macOS **15.0**.
* **`tests/test_compat.sh`:** Compatibility + performance guards (off-main refresh, no shell in Developer view).
* **`AirBridge.app`:** The resulting standalone application bundle.

---

## Build and Run Instructions

### 1. Compile the App
Rebuild on the Mac that will run the app (the checked-in binary may target a newer macOS than yours). Navigate to the folder and run:
```bash
./build.sh
./tests/test_compat.sh   # optional: path/SDK/PHY-mode compatibility checks
```
Requires Xcode Command Line Tools / macOS SDK. The build targets the host architecture at macOS 15.0.

### 2. Launch the App
Open **this folder’s** `AirBridge.app` (not an older copy under Downloads/DMG — macOS App Translocation can keep launching the stale bundle):
```bash
open "$(pwd)/AirBridge.app"
```

If Finder says the app is damaged (usually after download/copy), rebuild with `./build.sh`, or clear quarantine:
```bash
xattr -cr AirBridge.app
codesign --force --deep --sign - AirBridge.app
```

---

## Security Notice
Since modifying system interfaces, routing tables, and launching sniffer engines (like `tcpdump` and `pfctl`) require high-level OS privileges on macOS, you will see a standard system credential dialog asking to approve the actions when starting a hotspot, blocking devices, or limiting bandwidth. **No administrative credentials are ever saved or transmitted.**
