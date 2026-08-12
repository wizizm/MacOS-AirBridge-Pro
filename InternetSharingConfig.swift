import Foundation

struct NatPrimaryInterface: Equatable {
    var device: String
    var primaryUserReadable: String
    var primaryService: String
}

struct NatShareConfiguration: Equatable {
    var enabled: Bool
    var primary: NatPrimaryInterface
    var sharingDevices: [String]
}

/// Modern Sequoia+ schema uses SharingDevices[], not legacy SharingInterfaces{}.
func buildNatShareConfiguration(
    enabled: Bool,
    primaryDevice: String,
    primaryReadable: String,
    primaryService: String,
    targetDevice: String
) -> NatShareConfiguration {
    NatShareConfiguration(
        enabled: enabled,
        primary: NatPrimaryInterface(
            device: primaryDevice,
            primaryUserReadable: primaryReadable,
            primaryService: primaryService
        ),
        sharingDevices: enabled ? [targetDevice] : []
    )
}

/// OrbStack/VMNet bridges have vmenet* members and 198.19.x / 172.20.x style addresses —
/// they must not be treated as Apple Internet Sharing.
func isLikelyVirtualMachineBridge(interfaceName: String, ifconfigOutput: String) -> Bool {
    guard interfaceName.hasPrefix("bridge") else { return false }
    let block = ifconfigBlock(named: interfaceName, in: ifconfigOutput)
    if block.contains("vmenet") { return true }
    if block.contains("inet 198.19.") { return true }
    return false
}

func ifconfigBlock(named name: String, in output: String) -> String {
    var collecting = false
    var lines: [String] = []
    for line in output.components(separatedBy: "\n") {
        if let first = line.components(separatedBy: .whitespaces).first, first.hasSuffix(":") {
            let iface = String(first.dropLast())
            if collecting { break }
            collecting = (iface == name)
            if collecting { lines.append(line) }
            continue
        }
        if collecting { lines.append(line) }
    }
    return lines.joined(separator: "\n")
}

/// Prefer a non-VM bridge with an IPv4 address; otherwise nil.
func selectInternetSharingBridge(ipAddresses: [String: String], ifconfigOutput: String) -> (name: String, ip: String)? {
    let candidates = ipAddresses.keys.filter { $0.hasPrefix("bridge") }.sorted()
    for name in candidates {
        if isLikelyVirtualMachineBridge(interfaceName: name, ifconfigOutput: ifconfigOutput) {
            continue
        }
        if let ip = ipAddresses[name], !ip.isEmpty {
            return (name, ip)
        }
    }
    return nil
}

/// Internet Sharing is "on" when NAT.Enabled is true and SharingDevices is non-empty.
func isNatInternetSharingEnabled(enabledFlag: Bool, sharingDevices: [String]) -> Bool {
    enabledFlag && !sharingDevices.isEmpty
}

/// Parse `plutil -extract NAT.Enabled raw` output.
func parseNatEnabledExtract(_ raw: String) -> Bool {
    raw.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
}

/// Parse `plutil -extract NAT.SharingDevices json -o -` output.
func parseNatSharingDevicesJSON(_ json: String) -> [String] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8),
          let arr = try? JSONSerialization.jsonObject(with: data) as? [String] else {
        return []
    }
    return arr
}

/// Parse a simplified plutil -p fragment used in unit tests (SharingDevices + sibling Enabled).
func parseNatSharingState(fromPlistText text: String) -> (enabled: Bool, devices: [String]) {
    var devices: [String] = []
    let lines = text.components(separatedBy: .newlines)
    var inSharingDevices = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("SharingDevices") {
            inSharingDevices = true
            continue
        }
        if inSharingDevices {
            if trimmed.hasPrefix("]") || (trimmed.hasPrefix("}") && !trimmed.contains("=>")) {
                inSharingDevices = false
                continue
            }
            if let range = trimmed.range(of: "=>") {
                var value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\","))
                if value.hasPrefix("en") || value.hasPrefix("bridge") || value.hasPrefix("awdl") {
                    devices.append(value)
                }
            }
        }
    }
    // Prefer an Enabled line that is a sibling of SharingDevices (same indent), not nested AirPort.
    var enabled = false
    if let devicesLine = lines.first(where: { $0.contains("SharingDevices") }) {
        let indent = devicesLine.prefix(while: { $0 == " " }).count
        for line in lines {
            let lineIndent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if lineIndent == indent && trimmed.contains("\"Enabled\"") && trimmed.contains("=>") {
                enabled = trimmed.contains("1")
            }
        }
    }
    return (enabled, devices)
}

/// Parse `scutil` Interface dump for DeviceName / UserDefinedName.
func parseScutilInterface(deviceNameFromShow text: String) -> (device: String, readable: String)? {
    var device: String?
    var readable: String?
    for line in text.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("DeviceName") {
            device = trimmed.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
        } else if trimmed.hasPrefix("UserDefinedName") {
            readable = trimmed.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces)
        }
    }
    guard let device else { return nil }
    return (device, readable ?? device)
}

/// Shell snippet: write modern NAT plist, then best-effort reload InternetSharing.
/// SIP blocks `launchctl kickstart` on system/com.apple.NetworkSharing (Operation not permitted)
/// even as root via AppleScript — never require kickstart in the success path.
func internetSharingEnableShell(
    primaryDevice: String,
    primaryReadable: String,
    primaryService: String,
    targetDevice: String
) -> String {
    // Escape for embedding in AppleScript "do shell script"
    let readable = primaryReadable.replacingOccurrences(of: "\"", with: "\\\"")
    return """
    /usr/bin/plutil -replace NAT.Enabled -integer 1 /Library/Preferences/SystemConfiguration/com.apple.nat.plist && \
    /usr/bin/plutil -replace NAT.PrimaryInterface.Device -string \(primaryDevice) /Library/Preferences/SystemConfiguration/com.apple.nat.plist && \
    /usr/bin/plutil -replace NAT.PrimaryInterface.PrimaryUserReadable -string "\(readable)" /Library/Preferences/SystemConfiguration/com.apple.nat.plist && \
    /usr/bin/plutil -replace NAT.PrimaryInterface.Enabled -integer 0 /Library/Preferences/SystemConfiguration/com.apple.nat.plist && \
    /usr/bin/plutil -replace NAT.PrimaryService -string \(primaryService) /Library/Preferences/SystemConfiguration/com.apple.nat.plist && \
    (/usr/bin/plutil -replace NAT.SharingDevices -json '["\(targetDevice)"]' /Library/Preferences/SystemConfiguration/com.apple.nat.plist \
      || /usr/bin/plutil -insert NAT.SharingDevices -json '["\(targetDevice)"]' /Library/Preferences/SystemConfiguration/com.apple.nat.plist) && \
    (/usr/bin/killall InternetSharing || true)
    """
}

func internetSharingDisableShell() -> String {
    """
    /usr/bin/plutil -replace NAT.Enabled -integer 0 /Library/Preferences/SystemConfiguration/com.apple.nat.plist && \
    (/usr/bin/plutil -replace NAT.SharingDevices -json '[]' /Library/Preferences/SystemConfiguration/com.apple.nat.plist \
      || true) && \
    (/usr/bin/killall InternetSharing || true)
    """
}

/// Open System Settings → Sharing (works on Ventura/Sonoma/Sequoia).
func internetSharingSettingsURL() -> String {
    "x-apple.systempreferences:com.apple.Sharing-Settings.extension"
}

/// CWSecurity enterprise/802.1X family (WPA/WPA2/WPA3 Enterprise + generic Enterprise).
/// Personal modes (0–6, 11, 13–15) are false.
func isEnterprise8021XSecurity(rawValue: Int) -> Bool {
    switch rawValue {
    case 7, 8, 9, 10, 12: return true
    default: return false
    }
}

let airbridgeShareGatewayIP = "192.168.2.1"
let airbridgeShareSubnetCIDR = "192.168.2.0/24"
let airbridgeShareMarkerPath = "/var/run/airbridge-share.json"
let airbridgeSharePfAnchorPath = "/etc/pf.anchors/airbridge_share"
let airbridgeBootpdLaunchDaemonLabel = "com.airbridge.bootpd"
let airbridgeBootpdLaunchDaemonPath = "/Library/LaunchDaemons/com.airbridge.bootpd.plist"

struct ShareTargetCandidate: Equatable {
    var device: String
    var type: String
    var isActive: Bool
}

/// Prefer active USB/Link, then active iPhone USB, then any iPhone USB (never inactive over active link).
func selectDefaultShareTargetDevice(_ faces: [ShareTargetCandidate]) -> String? {
    if let d = faces.first(where: { $0.type == "USB/Link" && $0.isActive })?.device { return d }
    if let d = faces.first(where: { $0.type.lowercased().contains("iphone") && $0.isActive })?.device { return d }
    if let d = faces.first(where: { $0.type == "USB/Link" })?.device { return d }
    if let d = faces.first(where: { $0.type.lowercased().contains("iphone") })?.device { return d }
    return nil
}

func airbridgeBootpdLaunchDaemonPlist(targetDevice: String) -> String {
    // -d keeps bootpd in foreground; without it the process exits 0 and launchd thrash-restarts.
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(airbridgeBootpdLaunchDaemonLabel)</string>
      <key>ProgramArguments</key>
      <array>
        <string>/usr/libexec/bootpd</string>
        <string>-D</string>
        <string>-d</string>
        <string>-i</string>
        <string>\(targetDevice)</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>StandardOutPath</key>
      <string>/var/log/airbridge-bootpd.log</string>
      <key>StandardErrorPath</key>
      <string>/var/log/airbridge-bootpd.log</string>
    </dict>
    </plist>
    """
}

func isBypassInternetSharingActive(markerExists: Bool, targetHasShareIP: Bool) -> Bool {
    markerExists && targetHasShareIP
}

func parseAirbridgeShareMarker(_ json: String) -> (primary: String, target: String)? {
    guard let data = json.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let primary = obj["primary"] as? String,
          let target = obj["target"] as? String,
          !primary.isEmpty, !target.isEmpty else {
        return nil
    }
    return (primary, target)
}

func interfaceHasShareGatewayIP(ifconfigBlock: String) -> Bool {
    ifconfigBlock.contains("inet \(airbridgeShareGatewayIP) ")
        || ifconfigBlock.contains("inet \(airbridgeShareGatewayIP)\n")
}

/// Remove a previously appended AirBridge block that breaks pf rule order
/// (nat-anchor after filter anchors → `pfctl -f /etc/pf.conf` fails).
func stripAirbridgeShareFromPfConf(_ conf: String) -> String {
    let lines = conf.components(separatedBy: "\n")
    var result: [String] = []
    var skipping = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# AirBridge Pro") {
            skipping = true
            continue
        }
        if skipping {
            if trimmed.contains("airbridge_share") || trimmed.isEmpty {
                if trimmed.hasPrefix("load anchor") { skipping = false }
                continue
            }
            skipping = false
        }
        if trimmed.contains("airbridge_share") { continue }
        result.append(line)
    }
    // Trim trailing blank lines introduced by removal.
    while result.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
        result.removeLast()
    }
    return result.joined(separator: "\n") + "\n"
}

/// Reject shell metacharacters before interpolating into admin scripts.
func isSafeBsdInterfaceName(_ name: String) -> Bool {
    let pattern = #"^[A-Za-z][A-Za-z0-9]*$"#
    return name.range(of: pattern, options: .regularExpression) != nil
}

/// NAT-only rules loaded into the already-active `com.apple.internet-sharing` nat-anchor.
func airbridgeSharePfAnchorRules(primaryDevice: String, targetDevice: String) -> String {
    _ = targetDevice // target is L2; NAT egress is primary
    return "nat on \(primaryDevice) inet from \(airbridgeShareSubnetCIDR) to any -> (\(primaryDevice))\n"
}

let airbridgeSystemNatAnchor = "com.apple.internet-sharing"

/// Manual NAT + bootpd path when Apple Internet Sharing refuses 802.1X sources.
/// Callers must pass `isSafeBsdInterfaceName`-validated device names.
func internetSharingBypassEnableShell(primaryDevice: String, targetDevice: String) -> String {
    precondition(isSafeBsdInterfaceName(primaryDevice) && isSafeBsdInterfaceName(targetDevice),
                 "unsafe BSD interface name")
    let markerJSON = "{\"primary\":\"\(primaryDevice)\",\"target\":\"\(targetDevice)\"}"
    let subnetsJSON = "[{\"allocate\":true,\"net_address\":\"192.168.2.0\",\"net_mask\":\"255.255.255.0\",\"net_range\":[\"192.168.2.2\",\"192.168.2.200\"],\"dhcp_router\":[\"\(airbridgeShareGatewayIP)\"],\"dhcp_domain_name_server\":[\"8.8.8.8\",\"1.1.1.1\"]}]"
    let anchorBody = airbridgeSharePfAnchorRules(primaryDevice: primaryDevice, targetDevice: targetDevice)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    // Heredoc terminators must be at column 0; join keeps shell structure valid.
    let lines: [String] = [
        "/usr/bin/plutil -replace NAT.Enabled -integer 0 /Library/Preferences/SystemConfiguration/com.apple.nat.plist && \\",
        "(/usr/bin/plutil -replace NAT.SharingDevices -json '[]' /Library/Preferences/SystemConfiguration/com.apple.nat.plist || true) && \\",
        "(/usr/bin/killall InternetSharing || true) && \\",
        "/usr/sbin/sysctl -w net.inet.ip.forwarding=1 && \\",
        "/sbin/ifconfig \(targetDevice) inet \(airbridgeShareGatewayIP) netmask 255.255.255.0 up && \\",
        "/bin/mkdir -p /etc/pf.anchors && \\",
        "(/bin/cat > \(airbridgeSharePfAnchorPath) <<'AIRBRIDGE_PF_EOF'",
        anchorBody,
        "AIRBRIDGE_PF_EOF",
        ") && \\",
        // Strip any previously appended AirBridge Pro block that broke pf rule order.
        "/usr/bin/grep -v 'airbridge_share' /etc/pf.conf | /usr/bin/grep -v 'AirBridge Pro' > /tmp/pf.conf.airbridge && /bin/mv /tmp/pf.conf.airbridge /etc/pf.conf && \\",
        // Load NAT into the system nat-anchor that is already present in the running ruleset.
        "/sbin/pfctl -a \(airbridgeSystemNatAnchor) -f \(airbridgeSharePfAnchorPath) 2>/dev/null || true; \\",
        "(/sbin/pfctl -e 2>/dev/null || true); \\",
        "/usr/bin/plutil -replace dhcp_enabled -json '[\"\(targetDevice)\"]' /etc/bootpd.plist && \\",
        "(/usr/bin/plutil -replace Subnets -json '\(subnetsJSON)' /etc/bootpd.plist \\",
        "  || /usr/bin/plutil -insert Subnets -json '\(subnetsJSON)' /etc/bootpd.plist) && \\",
        "(/bin/launchctl bootout system/\(airbridgeBootpdLaunchDaemonLabel) 2>/dev/null || true); \\",
        "(/usr/bin/killall bootpd 2>/dev/null || true); \\",
        "(/bin/cat > \(airbridgeBootpdLaunchDaemonPath) <<'AIRBRIDGE_BOOTPD_EOF'",
        airbridgeBootpdLaunchDaemonPlist(targetDevice: targetDevice).trimmingCharacters(in: .whitespacesAndNewlines),
        "AIRBRIDGE_BOOTPD_EOF",
        ") && \\",
        "/bin/launchctl bootstrap system \(airbridgeBootpdLaunchDaemonPath) && \\",
        "/bin/echo '\(markerJSON)' > \(airbridgeShareMarkerPath)"
    ]
    return lines.joined(separator: "\n")
}

func internetSharingBypassDisableShell(targetDevice: String) -> String {
    precondition(isSafeBsdInterfaceName(targetDevice), "unsafe BSD interface name")
    return """
    /bin/rm -f \(airbridgeShareMarkerPath) && \
    (/usr/bin/plutil -replace dhcp_enabled -bool false /etc/bootpd.plist || true) && \
    (/usr/bin/plutil -replace Subnets -json '[]' /etc/bootpd.plist || true) && \
    (/bin/launchctl bootout system/\(airbridgeBootpdLaunchDaemonLabel) 2>/dev/null || true) && \
    (/bin/rm -f \(airbridgeBootpdLaunchDaemonPath) || true) && \
    (/usr/bin/killall bootpd 2>/dev/null || true) && \
    /bin/cp /dev/null \(airbridgeSharePfAnchorPath) && \
    (/sbin/pfctl -a \(airbridgeSystemNatAnchor) -F nat || true) && \
    (/usr/bin/grep -v 'airbridge_share' /etc/pf.conf | /usr/bin/grep -v 'AirBridge Pro' > /tmp/pf.conf.airbridge && /bin/mv /tmp/pf.conf.airbridge /etc/pf.conf || true) && \
    (/sbin/ifconfig \(targetDevice) inet \(airbridgeShareGatewayIP) delete || true) && \
    /usr/sbin/sysctl -w net.inet.ip.forwarding=0
    """
}
