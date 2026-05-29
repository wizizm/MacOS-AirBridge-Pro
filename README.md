# Tiwut AirBridge Pro

AirBridge Pro is a native, high-performance, ultra-lightweight macOS desktop application written in **Swift** and **SwiftUI**. It acts as a comprehensive network control dashboard, visualizer, and Wi-Fi repeater bridge manager—**running entirely client-side without any background servers, Node.js nodes, or web wrappers**.

The application operates in real-time, defaulting to a gorgeous **`860x640` glassmorphic window** that is fully **resizable** to accommodate larger displays and resolve clipping. It packages automatically with a custom App Icon and a dedicated Developer profile section for **Tiwut**.

---

## Features

AirBridge Pro wraps low-level macOS system diagnostics and packet daemons (`pfctl`, `dnctl`, `tcpdump`, `netstat`, `defaults`) inside a secure administrative privilege manager:

1. **One-Click Integrated Hotspot Toggler:** Dynamically writes to `/Library/Preferences/SystemConfiguration/com.apple.nat.plist` to bridge incoming internet (e.g. `en0`) to a secondary AP adapter (e.g. `en1`), loading the sharing daemon with a single secure prompt.
2. **WLAN Telemetry & Channel Analyzer:** Displays active RSSI signal (dBm), Noise (dBm), SNR, live Link Tx Rate (Mbps), radio channel, and PHY mode (e.g. Wi-Fi 6) utilizing the native `CoreWLAN` framework.
3. **Active Client Firewall Blocker:** Instantly blocks or kicks devices from the bridge network by inserting drop rules into the macOS Packet Filter (`pfctl`) anchor list.
4. **Data Speedometer & Bandwidth Meter:** Computes real-time download and upload speeds (KB/s) and tracks cumulative traffic (MB) using `netstat -ib` metrics.
5. **Fast DNS Server Redirects:** Toggles shared clients DNS configuration between defaults, Cloudflare Fast DNS, Google Public DNS, or AdGuard (AdBlocker) DNS by updating `bootpd.plist` dynamically.
6. **Port Forwarding Redirection Manager:** Maps external ports on your Mac directly to internal client IP addresses using custom `pfctl` NAT redirects.
7. **Local Packet Sniffer Terminal Console:** A live-buffered console snoop that captures active IP packet communication on the bridge interface via `tcpdump`.
8. **Bandwidth Shaper & Traffic Limiter:** Capping client bandwidth (Unlimited, 2, 5, or 10 Mbps) using macOS `dnctl` (dummynet) pipelines.
9. **Latency Quality Diagnostics:** Active round-trip time (RTT) ping latency and packet drop check tools.
10. **DHCP Static IP Reservations:** Permanently registers client MAC addresses to desired private IPs inside `/etc/bootpd.plist`.

---

## Project Anatomy

* **`main.swift`:** The standalone Swift codebase containing the AppKit shell window parameters, the low-level CLI parsers, the AppleScript escalation routines, and the SwiftUI GUI dashboard. Contains **zero code comments** for a pristine, minimalist file layout.
* **`build.sh`:** A comments-free compilation script that downloads the custom developer icon, resizes it into macOS bundle specifications via `sips`, compiles it into an `AppIcon.icns` file, packages the metadata `Info.plist`, and compiles `main.swift` natively using the Apple Swift Compiler (`swiftc`).
* **`AirBridge.app`:** The resulting standalone application bundle. Size is only **1.1 Megabytes**, starting instantaneously and consuming under 15MB of RAM.

---

## Build and Run Instructions

### 1. Compile the App
To rebuild the app bundle dynamically in the future, navigate to the folder and run:
```bash
./build.sh
```

### 2. Launch the App
Open the app bundle in Finder or run the following shell command to launch the resizable native desktop window:
```bash
open AirBridge.app
```

---

## Security Notice
Since modifying system interfaces, routing tables, and launching sniffer engines (like `tcpdump` and `pfctl`) require high-level OS privileges on macOS, you will see a standard system credential dialog asking to approve the actions when starting a hotspot, blocking devices, or limiting bandwidth. **No administrative credentials are ever saved or transmitted.**
