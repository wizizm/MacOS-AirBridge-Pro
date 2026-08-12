import Cocoa
import SwiftUI
import CoreWLAN
import Combine

func shell(_ command: String) -> String {
    let task = Process()
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    task.arguments = ["-c", command]
    task.launchPath = "/bin/zsh"
    task.standardInput = nil
    do {
        try task.run()
    } catch {
        return ""
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output
}

struct NetworkInterface: Identifiable, Hashable {
    var id: String { device }
    let device: String
    let type: String
    let macAddress: String
    let ipAddress: String?
    let ssid: String?
    let isActive: Bool
}

struct ConnectedClient: Identifiable, Hashable {
    var id: String { macAddress }
    let hostname: String
    let ipAddress: String
    let macAddress: String
    var isActive: Bool
    var isBlocked: Bool = false
    var isReserved: Bool = false
}

struct PortForwardRule: Identifiable, Hashable {
    let id: String
    let externalPort: String
    let internalIP: String
    let internalPort: String
    let protocolType: String
}

struct SnifferPacket: Identifiable, Hashable {
    let id: String = UUID().uuidString
    let timestamp: String
    let source: String
    let destination: String
    let protocolType: String
    let length: String
    let info: String
}

class AdminManager {
    static func runAsAdmin(_ command: String) -> (String, Bool) {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escapedCommand)\" with administrator privileges"
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        if let output = appleScript?.executeAndReturnError(&errorInfo) {
            return (output.stringValue ?? "", true)
        } else {
            let errorMsg = errorInfo?[NSAppleScript.errorMessage] as? String ?? L10n.text(.authorizationFailed)
            return (errorMsg, false)
        }
    }
}

class NetworkMonitor: ObservableObject {
    @Published var interfaces: [NetworkInterface] = []
    @Published var connectedClients: [ConnectedClient] = []
    @Published var isInternetSharingActive: Bool = false
    @Published var sharingBridgeIP: String? = nil
    /// Non-VM Internet Sharing bridge device (e.g. bridge50); set on refreshQueue for speedometer/sniffer.
    private var sharingBridgeDevice: String? = nil
    @Published var isScanning: Bool = false
    @Published var wlanSSID: String = L10n.text(.wlanNotConnected)
    @Published var wlanBSSID: String = "--:--:--:--:--:--"
    @Published var wlanRSSI: Int = 0
    @Published var wlanNoise: Int = 0
    @Published var wlanTxRate: Double = 0.0
    @Published var wlanChannel: Int = 0
    @Published var wlanPhyMode: String = L10n.text(.wlanPhyUnknown)
    @Published var downloadSpeed: Double = 0.0
    @Published var uploadSpeed: Double = 0.0
    @Published var totalDownloadMB: Double = 0.0
    @Published var totalUploadMB: Double = 0.0
    @Published var snifferPackets: [SnifferPacket] = []
    @Published var isSniffing: Bool = false
    @Published var pingLatency: Double = 0.0
    @Published var pingLoss: Double = 0.0
    @Published var isTestingPing: Bool = false
    @Published var blockedMacs: Set<String> = []
    @Published var reservedIPs: [String: String] = [:]
    @Published var portRules: [PortForwardRule] = []
    @Published var currentDNSMode: String = "System Defaults"
    @Published var isAdBlockerActive: Bool = false
    @Published var currentShaperSpeed: Double = 0.0
    
    private var timer: AnyCancellable?
    private var lastInBytes: Double = 0.0
    private var lastOutBytes: Double = 0.0
    private var lastSpeedCheckTime = Date()
    private var lastSpeedInterface: String = ""
    private let refreshQueue = DispatchQueue(label: "com.antigravity.AirBridge.refresh", qos: .utility)
    private var refreshTick: Int = 0
    
    init() {
        schedulePeriodicRefresh(full: true)
        timer = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.schedulePeriodicRefresh(full: false)
            }
    }
    
    /// Heavy shell work stays off the main thread so the SwiftUI window stays responsive.
    func schedulePeriodicRefresh(full: Bool) {
        refreshTick += 1
        let runFull = full || refreshTick % 3 == 1
        // Snapshot main-thread state before leaving main (avoid data races on Sets / @Published).
        let sharingActive = isInternetSharingActive
        let blockedSnapshot = blockedMacs
        let reservedSnapshot = reservedIPs
        refreshQueue.async { [weak self] in
            guard let self else { return }
            if runFull {
                self.refreshData(blocked: blockedSnapshot, reserved: reservedSnapshot)
            }
            self.refreshSpeedometer(sharingActive: sharingActive)
            // CoreWiFi SSID/BSSID are sync XPC — never call from the main thread.
            if runFull {
                self.refreshWLANTelemetry()
            }
        }
    }
    
    /// Enqueue a full refresh from any thread without blocking the main run loop.
    private func enqueueRefreshData() {
        let blockedSnapshot: Set<String>
        let reservedSnapshot: [String: String]
        if Thread.isMainThread {
            blockedSnapshot = blockedMacs
            reservedSnapshot = reservedIPs
        } else {
            // Capture on main without deadlocking refreshQueue (never call this while holding main→refreshQueue wait).
            (blockedSnapshot, reservedSnapshot) = DispatchQueue.main.sync {
                (self.blockedMacs, self.reservedIPs)
            }
        }
        refreshQueue.async { [weak self] in
            self?.refreshData(blocked: blockedSnapshot, reserved: reservedSnapshot)
        }
    }
    
    func forceScan() {
        isScanning = true
        let blockedSnapshot = blockedMacs
        let reservedSnapshot = reservedIPs
        refreshQueue.async {
            self.refreshData(blocked: blockedSnapshot, reserved: reservedSnapshot)
            self.refreshWLANTelemetry()
            DispatchQueue.main.async {
                self.isScanning = false
            }
        }
    }
    
    /// - Note: Must run on `refreshQueue`. Pass snapshots of main-actor collections to avoid races.
    func refreshData(blocked: Set<String>? = nil, reserved: [String: String]? = nil) {
        let blockedMacsLocal = blocked ?? blockedMacs
        let reservedIPsLocal = reserved ?? reservedIPs
        let hardwarePorts = parseHardwarePorts()
        let ifconfigRaw = shell("ifconfig")
        let addresses = parseIfconfigOutput(ifconfigRaw)
        let ipAddresses = addresses.ips
        let wifiDevices = hardwarePorts.compactMap { device, type -> String? in
            let lowered = type.lowercased()
            return (lowered.contains("wi-fi") || lowered.contains("airport")) ? device : nil
        }
        let activeSSIDs = fetchSSIDs(interfaces: wifiDevices)
        var detectedInterfaces: [NetworkInterface] = []
        var listed = Set<String>()
        for (device, type) in hardwarePorts {
            listed.insert(device)
            let mac = addresses.macs[device] ?? L10n.text(.macUnknown)
            let ip = ipAddresses[device]
            let ssid = activeSSIDs[device]
            let isActive = ip != nil && !ip!.isEmpty
            detectedInterfaces.append(NetworkInterface(
                device: device,
                type: type,
                macAddress: mac,
                ipAddress: ip,
                ssid: ssid,
                isActive: isActive
            ))
        }
        // iPhone USB often appears as a dynamic en* (e.g. en8) not listed by networksetup.
        for device in addresses.macs.keys.sorted() where device.hasPrefix("en") && !listed.contains(device) {
            let block = ifconfigBlock(named: device, in: ifconfigRaw)
            guard block.contains("status: active") else { continue }
            detectedInterfaces.append(NetworkInterface(
                device: device,
                type: "USB/Link",
                macAddress: addresses.macs[device] ?? L10n.text(.macUnknown),
                ipAddress: ipAddresses[device],
                ssid: nil,
                isActive: ipAddresses[device] != nil
            ))
        }
        let selectedBridge = selectInternetSharingBridge(ipAddresses: ipAddresses, ifconfigOutput: ifconfigRaw)
        var bridgeIP = selectedBridge?.ip
        self.sharingBridgeDevice = selectedBridge?.name
        let natEnabledRaw = shell("plutil -extract NAT.Enabled raw /Library/Preferences/SystemConfiguration/com.apple.nat.plist 2>/dev/null")
        let natDevicesRaw = shell("plutil -extract NAT.SharingDevices json -o - /Library/Preferences/SystemConfiguration/com.apple.nat.plist 2>/dev/null")
        let natOn = isNatInternetSharingEnabled(
            enabledFlag: parseNatEnabledExtract(natEnabledRaw),
            sharingDevices: parseNatSharingDevicesJSON(natDevicesRaw)
        )
        let markerRaw = (try? String(contentsOfFile: airbridgeShareMarkerPath, encoding: .utf8)) ?? ""
        let marker = parseAirbridgeShareMarker(markerRaw)
        let bypassTarget = marker?.target
        let bypassTargetBlock = bypassTarget.map { ifconfigBlock(named: $0, in: ifconfigRaw) } ?? ""
        let bypassOn = isBypassInternetSharingActive(
            markerExists: marker != nil,
            targetHasShareIP: interfaceHasShareGatewayIP(ifconfigBlock: bypassTargetBlock)
        )
        if bypassOn, let target = bypassTarget {
            self.sharingBridgeDevice = target
            bridgeIP = airbridgeShareGatewayIP
        }
        let sharingOn = natOn || bypassOn
        let leases = parseDHCPLeases()
        let activeARPMapping = parseARPCache()
        var clients: [ConnectedClient] = []
        for lease in leases {
            let isCurrent = activeARPMapping[lease.macAddress] != nil || activeARPMapping[lease.ipAddress] != nil
            var client = lease
            client.isActive = isCurrent
            client.isBlocked = blockedMacsLocal.contains(client.macAddress.lowercased())
            client.isReserved = reservedIPsLocal[client.macAddress.lowercased()] != nil
            clients.append(client)
        }
        var uniqueClients = [String: ConnectedClient]()
        for client in clients {
            uniqueClients[client.macAddress.lowercased()] = client
        }
        let sortedClients = Array(uniqueClients.values).sorted(by: { $0.ipAddress < $1.ipAddress })
        let sortedInterfaces = detectedInterfaces.sorted(by: { $0.device < $1.device })
        DispatchQueue.main.async {
            if self.interfaces != sortedInterfaces { self.interfaces = sortedInterfaces }
            if self.connectedClients != sortedClients { self.connectedClients = sortedClients }
            if self.isInternetSharingActive != sharingOn { self.isInternetSharingActive = sharingOn }
            if self.sharingBridgeIP != bridgeIP { self.sharingBridgeIP = bridgeIP }
        }
    }
    
    func refreshWLANTelemetry() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        let ssid = interface.ssid() ?? L10n.text(.wlanNotAssociated)
        let bssid = interface.bssid() ?? "--:--:--:--:--:--"
        let rssi = interface.rssiValue()
        let noise = interface.noiseMeasurement()
        let txRate = interface.transmitRate()
        let channel = interface.wlanChannel()?.channelNumber ?? 0
        let phyModeVal = phyModeLabel(rawValue: Int(interface.activePHYMode().rawValue))
        DispatchQueue.main.async {
            // Publish only on change — avoids rebuilding the entire SwiftUI tree every tick.
            if self.wlanSSID != ssid { self.wlanSSID = ssid }
            if self.wlanBSSID != bssid { self.wlanBSSID = bssid }
            if self.wlanRSSI != rssi { self.wlanRSSI = rssi }
            if self.wlanNoise != noise { self.wlanNoise = noise }
            if self.wlanTxRate != txRate { self.wlanTxRate = txRate }
            if self.wlanChannel != channel { self.wlanChannel = channel }
            if self.wlanPhyMode != phyModeVal { self.wlanPhyMode = phyModeVal }
        }
    }
    
    func refreshSpeedometer(sharingActive: Bool? = nil) {
        // Prefer caller snapshot; never read @Published Bool from refreshQueue without it.
        let active = sharingActive ?? false
        // Prefer real sharing bridge device; never fall back to a VM bridge100.
        let targetInterface = active ? (sharingBridgeDevice ?? "en0") : "en0"
        if speedometerBaselineNeedsReset(previousInterface: lastSpeedInterface.isEmpty ? nil : lastSpeedInterface,
                                         currentInterface: targetInterface) {
            lastInBytes = 0
            lastOutBytes = 0
        }
        lastSpeedInterface = targetInterface
        // ponytail: getifaddrs is ~0.05ms; netstat/Process was the old multi-ms path.
        guard let (currentIn, currentOut) = interfaceByteCounters(named: targetInterface) else { return }
        let now = Date()
        let interval = now.timeIntervalSince(lastSpeedCheckTime)
        if lastInBytes > 0 && interval > 0 {
            let dlSpeed = ((currentIn - lastInBytes) / interval) / 1024.0
            let ulSpeed = ((currentOut - lastOutBytes) / interval) / 1024.0
            let dl = max(0.0, dlSpeed)
            let ul = max(0.0, ulSpeed)
            let dlMB = currentIn / (1024.0 * 1024.0)
            let ulMB = currentOut / (1024.0 * 1024.0)
            DispatchQueue.main.async {
                if abs(self.downloadSpeed - dl) > 0.05 { self.downloadSpeed = dl }
                if abs(self.uploadSpeed - ul) > 0.05 { self.uploadSpeed = ul }
                if abs(self.totalDownloadMB - dlMB) > 0.01 { self.totalDownloadMB = dlMB }
                if abs(self.totalUploadMB - ulMB) > 0.01 { self.totalUploadMB = ulMB }
            }
        }
        lastInBytes = currentIn
        lastOutBytes = currentOut
        lastSpeedCheckTime = now
    }
    
    func toggleIntegratedHotspot(enable: Bool, primary: String, target: String, completion: @escaping (String, Bool) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let cmd: String
            var usedBypass = false
            if enable {
                let securityRaw: Int = {
                    if let iface = CWWiFiClient.shared().interface(withName: primary) {
                        return Int(iface.security().rawValue)
                    }
                    if let iface = CWWiFiClient.shared().interface(), iface.interfaceName == primary {
                        return Int(iface.security().rawValue)
                    }
                    return -1
                }()
                if isEnterprise8021XSecurity(rawValue: securityRaw) {
                    guard isSafeBsdInterfaceName(primary), isSafeBsdInterfaceName(target) else {
                        DispatchQueue.main.async {
                            completion(L10n.format(.hotspotToggleError, "invalid interface name"), false)
                        }
                        return
                    }
                    usedBypass = true
                    cmd = internetSharingBypassEnableShell(primaryDevice: primary, targetDevice: target)
                } else {
                    guard let service = self.lookupNetworkService(forDevice: primary) else {
                        DispatchQueue.main.async {
                            completion(L10n.format(.hotspotMissingPrimaryService, primary), false)
                        }
                        return
                    }
                    let ports = self.parseHardwarePorts()
                    let readable = ports[primary] ?? service.readable
                    cmd = internetSharingEnableShell(
                        primaryDevice: primary,
                        primaryReadable: readable,
                        primaryService: service.serviceID,
                        targetDevice: target
                    )
                }
            } else {
                let markerRaw = (try? String(contentsOfFile: airbridgeShareMarkerPath, encoding: .utf8)) ?? ""
                if let marker = parseAirbridgeShareMarker(markerRaw) {
                    usedBypass = true
                    cmd = internetSharingBypassDisableShell(targetDevice: marker.target)
                } else if !target.isEmpty {
                    // Prefer explicit target when stopping a just-enabled bypass whose marker vanished.
                    let ifconfigRaw = shell("ifconfig")
                    let block = ifconfigBlock(named: target, in: ifconfigRaw)
                    if interfaceHasShareGatewayIP(ifconfigBlock: block) {
                        usedBypass = true
                        cmd = internetSharingBypassDisableShell(targetDevice: target)
                    } else {
                        cmd = internetSharingDisableShell()
                    }
                } else {
                    cmd = internetSharingDisableShell()
                }
            }
            let (msg, success) = AdminManager.runAsAdmin(cmd)
            // Never open System Settings Sharing for 802.1X bypass — that UI only shows the 802.1X error.
            if enable && success && !usedBypass {
                _ = shell("open '\(internetSharingSettingsURL())'")
            }
            self.enqueueRefreshData()
            DispatchQueue.main.async {
                if success {
                    var notice: String
                    if enable {
                        notice = usedBypass
                            ? L10n.text(.hotspotBypass8021XSuccess)
                            : L10n.text(.hotspotConfiguredOpenSettings)
                        if usedBypass {
                            notice += L10n.text(.hotspotBypass8021XPolicyNote)
                        }
                    } else {
                        notice = L10n.text(.hotspotToggleSuccess)
                    }
                    let ifconfigRaw = shell("ifconfig")
                    let addresses = parseIfconfigOutput(ifconfigRaw)
                    let hasVmBridge = addresses.ips.keys.contains { name in
                        isLikelyVirtualMachineBridge(interfaceName: name, ifconfigOutput: ifconfigRaw)
                    }
                    if hasVmBridge && enable {
                        notice += L10n.text(.hotspotVmConflictWarning)
                    }
                    completion(notice, true)
                } else {
                    completion(L10n.format(.hotspotToggleError, msg), false)
                }
            }
        }
    }

    /// Resolve SystemConfiguration service UUID + readable name for a BSD device (e.g. en0).
    private func lookupNetworkService(forDevice device: String) -> (serviceID: String, readable: String)? {
        let listOut = shell("echo list | scutil")
        var seen = Set<String>()
        var serviceIDs: [String] = []
        for line in listOut.components(separatedBy: .newlines) {
            guard let range = line.range(of: "Setup:/Network/Service/") else { continue }
            let rest = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            guard let uuid = rest.split(separator: "/").first.map(String.init), !uuid.isEmpty else { continue }
            if seen.insert(uuid).inserted {
                serviceIDs.append(uuid)
            }
        }
        for uuid in serviceIDs {
            let show = shell("echo 'show Setup:/Network/Service/\(uuid)/Interface' | scutil")
            guard let parsed = parseScutilInterface(deviceNameFromShow: show), parsed.device == device else {
                continue
            }
            return (uuid, parsed.readable)
        }
        return nil
    }
    
    func blockClient(client: ConnectedClient, completion: @escaping (String, Bool) -> Void) {
        let mac = client.macAddress.lowercased()
        let ip = client.ipAddress
        DispatchQueue.global(qos: .userInitiated).async {
            let blockInRule = "block drop in quick from \(ip) to any"
            let blockOutRule = "block drop out quick from any to \(ip)"
            let loadBlockRules = "echo \"\(blockInRule)\n\(blockOutRule)\" | pfctl -a airbridge_block -f -"
            let enablePF = "pfctl -e"
            let (msg, success) = AdminManager.runAsAdmin("\(loadBlockRules) && \(enablePF)")
            if success {
                DispatchQueue.main.async {
                    self.blockedMacs.insert(mac)
                    self.enqueueRefreshData()
                }
            }
            DispatchQueue.main.async {
                completion(success ? L10n.format(.clientBlockedSuccess, client.hostname) : L10n.format(.firewallError, msg), success)
            }
        }
    }
    
    func unblockClient(client: ConnectedClient, completion: @escaping (String, Bool) -> Void) {
        let mac = client.macAddress.lowercased()
        DispatchQueue.global(qos: .userInitiated).async {
            let clearRules = "pfctl -a airbridge_block -F rules"
            let (msg, success) = AdminManager.runAsAdmin(clearRules)
            if success {
                DispatchQueue.main.async {
                    self.blockedMacs.remove(mac)
                    self.reapplyAllBlocks()
                }
            }
            DispatchQueue.main.async {
                completion(success ? L10n.text(.deviceUnblockedSuccess) : L10n.format(.firewallError, msg), success)
            }
        }
    }
    
    private func reapplyAllBlocks() {
        if blockedMacs.isEmpty { return }
        var rules = ""
        for client in connectedClients {
            if blockedMacs.contains(client.macAddress.lowercased()) {
                rules += "block drop in quick from \(client.ipAddress) to any\n"
                rules += "block drop out quick from any to \(client.ipAddress)\n"
            }
        }
        if !rules.isEmpty {
            _ = AdminManager.runAsAdmin("echo \"\(rules)\" | pfctl -a airbridge_block -f - && pfctl -e")
        }
        self.enqueueRefreshData()
    }
    
    func applyDNSOverride(mode: String, completion: @escaping (String, Bool) -> Void) {
        let dnsServers: [String]
        switch mode {
        case "Cloudflare": dnsServers = ["1.1.1.1", "1.0.0.1"]
        case "Google": dnsServers = ["8.8.8.8", "8.8.4.4"]
        case "AdGuard (AdBlock)": dnsServers = ["94.140.14.14", "94.140.15.15"]
        default:
            DispatchQueue.global(qos: .userInitiated).async {
                let removeCmd = "defaults delete /etc/bootpd dhcp_domain_name_server"
                _ = AdminManager.runAsAdmin(removeCmd)
                DispatchQueue.main.async {
                    self.currentDNSMode = "System Defaults"
                    completion(L10n.text(.dnsRevertedSuccess), true)
                }
            }
            return
        }
        let serverString = dnsServers.map { "\"\($0)\"" }.joined(separator: " ")
        DispatchQueue.global(qos: .userInitiated).async {
            let writeCmd = "defaults write /etc/bootpd dhcp_domain_name_server -array \(serverString)"
            let (msg, success) = AdminManager.runAsAdmin(writeCmd)
            DispatchQueue.main.async {
                if success {
                    self.currentDNSMode = mode
                    completion(L10n.format(.dnsConfiguredSuccess, mode, dnsServers.joined(separator: ", ")), true)
                } else {
                    completion(L10n.format(.dnsOverrideError, msg), false)
                }
            }
        }
    }
    
    func addPortForwardRule(external: String, clientIP: String, internalPort: String, protocolType: String, completion: @escaping (String, Bool) -> Void) {
        let proto = protocolType.lowercased()
        let ruleId = UUID().uuidString
        DispatchQueue.global(qos: .userInitiated).async {
            let redirectRule = "rdr pass on bridge100 proto \(proto) from any to any port \(external) -> \(clientIP) port \(internalPort)"
            let cmd = "echo \"\(redirectRule)\" | pfctl -a airbridge_rdr -f - && pfctl -e"
            let (msg, success) = AdminManager.runAsAdmin(cmd)
            DispatchQueue.main.async {
                if success {
                    let newRule = PortForwardRule(
                        id: ruleId,
                        externalPort: external,
                        internalIP: clientIP,
                        internalPort: internalPort,
                        protocolType: protocolType
                    )
                    self.portRules.append(newRule)
                    completion(L10n.format(.redirectRuleSuccess, external, clientIP, internalPort), true)
                } else {
                    completion(L10n.format(.redirectApplyError, msg), false)
                }
            }
        }
    }
    
    func deletePortForwardRule(rule: PortForwardRule) {
        portRules.removeAll(where: { $0.id == rule.id })
        DispatchQueue.global(qos: .userInitiated).async {
            if self.portRules.isEmpty {
                _ = AdminManager.runAsAdmin("pfctl -a airbridge_rdr -F all")
            } else {
                var redirectRules = ""
                for r in self.portRules {
                    redirectRules += "rdr pass on bridge100 proto \(r.protocolType.lowercased()) from any to any port \(r.externalPort) -> \(r.internalIP) port \(r.internalPort)\n"
                }
                _ = AdminManager.runAsAdmin("echo \"\(redirectRules)\" | pfctl -a airbridge_rdr -f - && pfctl -e")
            }
        }
    }
    
    func runTrafficSniffer() {
        guard !isSniffing else { return }
        isSniffing = true
        snifferPackets.removeAll()
        let bridge: String
        if isInternetSharingActive {
            if let ip = sharingBridgeIP,
               let name = interfaces.first(where: { $0.ipAddress == ip })?.device {
                bridge = name
            } else {
                bridge = "en0"
            }
        } else {
            bridge = "en0"
        }
        DispatchQueue.global(qos: .userInteractive).async {
            let snifferCmd = "tcpdump -c 15 -t -n -i \(bridge) ip"
            let (output, success) = AdminManager.runAsAdmin(snifferCmd)
            var parsedPackets: [SnifferPacket] = []
            if success {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty { continue }
                    let parts = trimmed.components(separatedBy: " ")
                    if parts.count >= 5 {
                        let proto = parts.contains("tcp") ? "TCP" : (parts.contains("udp") ? "UDP" : "IP")
                        let src = parts[1]
                        let dest = parts[3].replacingOccurrences(of: ":", with: "")
                        let info = parts.suffix(from: min(parts.count, 4)).joined(separator: " ")
                        let formatter = DateFormatter()
                        formatter.dateFormat = "HH:mm:ss"
                        parsedPackets.append(SnifferPacket(
                            timestamp: formatter.string(from: Date()),
                            source: src,
                            destination: dest,
                            protocolType: proto,
                            length: "N/A",
                            info: info
                        ))
                    }
                }
            }
            DispatchQueue.main.async {
                self.snifferPackets = parsedPackets
                self.isSniffing = false
            }
        }
    }
    
    func applySpeedLimiter(speedMbps: Double, completion: @escaping (String, Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            if speedMbps == 0 {
                let clearShaper = "dnctl flush && pfctl -a airbridge_shaper -F all"
                _ = AdminManager.runAsAdmin(clearShaper)
                DispatchQueue.main.async {
                    self.currentShaperSpeed = 0.0
                    completion(L10n.text(.shaperDisabledSuccess), true)
                }
                return
            }
            let configurePipe = "dnctl pipe 1 config bw \(Int(speedMbps))Mbit/s"
            let pfRule = "dummynet out proto {tcp, udp} from any to any pipe 1"
            let loadPFShaper = "echo \"\(pfRule)\" | pfctl -a airbridge_shaper -f -"
            let enablePF = "pfctl -e"
            let command = "\(configurePipe) && \(loadPFShaper) && \(enablePF)"
            let (msg, success) = AdminManager.runAsAdmin(command)
            DispatchQueue.main.async {
                if success {
                    self.currentShaperSpeed = speedMbps
                    completion(L10n.format(.shaperLimitedSuccess, Int(speedMbps)), true)
                } else {
                    completion(L10n.format(.dummynetError, msg), false)
                }
            }
        }
    }
    
    func runQualityDiagnostics() {
        guard !isTestingPing else { return }
        isTestingPing = true
        let targetHost = "1.1.1.1"
        DispatchQueue.global(qos: .userInitiated).async {
            let output = shell("ping -c 4 \(targetHost)")
            var avgLatency = 0.0
            var packetLoss = 0.0
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                if line.contains("packet loss") {
                    let parts = line.components(separatedBy: ",")
                    for part in parts {
                        if part.contains("packet loss") {
                            let lossStr = part.replacingOccurrences(of: "% packet loss", with: "").trimmingCharacters(in: .whitespaces)
                            packetLoss = Double(lossStr) ?? 0.0
                        }
                    }
                } else if line.hasPrefix("round-trip") || line.hasPrefix("rtt") {
                    let parts = line.components(separatedBy: "/")
                    if parts.count >= 5 {
                        avgLatency = Double(parts[4]) ?? 0.0
                    }
                }
            }
            DispatchQueue.main.async {
                self.pingLatency = avgLatency
                self.pingLoss = packetLoss
                self.isTestingPing = false
            }
        }
    }
    
    func addIPReservation(mac: String, ip: String, completion: @escaping (String, Bool) -> Void) {
        let cleanMac = formatMACAddress(mac)
        let cleanIp = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        DispatchQueue.global(qos: .userInitiated).async {
            let reserveCmd = "defaults write /etc/bootpd dhcp_static_maps -array-add '{ hw_address = \"1,\(cleanMac)\"; ip_address = \"\(cleanIp)\"; }'"
            let (msg, success) = AdminManager.runAsAdmin(reserveCmd)
            DispatchQueue.main.async {
                if success {
                    self.reservedIPs[cleanMac.lowercased()] = cleanIp
                    self.enqueueRefreshData()
                    completion(L10n.format(.staticLeaseSuccess, cleanMac, cleanIp), true)
                } else {
                    completion(L10n.format(.dhcpConfigError, msg), false)
                }
            }
        }
    }
    
    private func parseHardwarePorts() -> [String: String] {
        var ports: [String: String] = [:]
        let output = shell("networksetup -listallhardwareports")
        let blocks = output.components(separatedBy: "Hardware Port:")
        for block in blocks {
            let lines = block.components(separatedBy: .newlines)
            var portName = ""
            var deviceName = ""
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if portName.isEmpty {
                    portName = trimmed
                } else if trimmed.hasPrefix("Device:") {
                    deviceName = trimmed.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                }
            }
            if !portName.isEmpty && !deviceName.isEmpty {
                ports[deviceName] = portName
            }
        }
        return ports
    }
    
    private func fetchSSIDs(interfaces: [String]) -> [String: String] {
        var ssids: [String: String] = [:]
        for dev in interfaces {
            if let interface = CWWiFiClient.shared().interface(withName: dev) {
                if let ssid = interface.ssid() {
                    ssids[dev] = ssid
                    continue
                }
            }
            let ipconfigSummary = shell("/usr/sbin/ipconfig getsummary \(dev)")
            for line in ipconfigSummary.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.contains("SSID :") {
                    let parts = trimmed.components(separatedBy: "SSID :")
                    if parts.count > 1 {
                        let parsedSSID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                        if !parsedSSID.isEmpty {
                            ssids[dev] = parsedSSID
                        }
                    }
                }
            }
        }
        return ssids
    }
    
    private func parseDHCPLeases() -> [ConnectedClient] {
        var clients: [ConnectedClient] = []
        do {
            let fileURL = URL(fileURLWithPath: "/private/var/db/dhcpd_leases")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let blocks = content.components(separatedBy: "}")
            for block in blocks {
                if !block.contains("{") { continue }
                var name = L10n.text(.unknownDevice)
                var ip = ""
                var mac = ""
                let lines = block.components(separatedBy: .newlines)
                for line in lines {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("name=") {
                        name = trimmed.replacingOccurrences(of: "name=", with: "").trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("ip_address=") {
                        ip = trimmed.replacingOccurrences(of: "ip_address=", with: "").trimmingCharacters(in: .whitespaces)
                    } else if trimmed.hasPrefix("hw_address=") {
                        let hw = trimmed.replacingOccurrences(of: "hw_address=", with: "").trimmingCharacters(in: .whitespaces)
                        let parts = hw.components(separatedBy: ",")
                        if parts.count > 1 {
                            mac = parts[1]
                        } else {
                            mac = hw
                        }
                    }
                }
                if !ip.isEmpty && !mac.isEmpty {
                    let formattedMac = formatMACAddress(mac)
                    clients.append(ConnectedClient(
                        hostname: name,
                        ipAddress: ip,
                        macAddress: formattedMac,
                        isActive: true
                    ))
                }
            }
        } catch {}
        return clients
    }
    
    private func parseARPCache() -> [String: Bool] {
        var activeHosts: [String: Bool] = [:]
        let output = shell("arp -an")
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let parts = trimmed.components(separatedBy: .whitespaces)
            if parts.count > 3 {
                var ip = parts[1]
                ip = ip.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
                let mac = formatMACAddress(parts[3])
                activeHosts[ip] = true
                activeHosts[mac] = true
            }
        }
        return activeHosts
    }
    
    private func formatMACAddress(_ mac: String) -> String {
        let clean = mac.replacingOccurrences(of: ":", with: "").lowercased()
        var result = ""
        var count = 0
        for char in clean {
            if count > 0 && count % 2 == 0 {
                result += ":"
            }
            result += String(char)
            count += 1
        }
        return result
    }
}

extension Color {
    static let amberGlow = Color(nsColor: NSColor(red: 0.95, green: 0.6, blue: 0.1, alpha: 1.0))
}

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .sidebar
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct ContentView: View {
    @StateObject var monitor = NetworkMonitor()
    @State var selectedTab: Int = 0
    @State var showNotice: Bool = false
    @State var noticeMessage: String = ""
    @State var noticeSuccess: Bool = true
    @State var extPort: String = ""
    @State var intPort: String = ""
    @State var clientIP: String = ""
    @State var selectedProto: String = "TCP"
    @State var reserveMac: String = ""
    @State var reserveIp: String = ""
    @State var sourceInt: String = "en0"
    @State var targetInt: String = "en1"
    
    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                VStack(spacing: 6) {
                    Image(systemName: "wifi.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .cyan.opacity(0.3), radius: 5)
                    Text(L10n.text(.appName))
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                }
                .padding(.top, 20)
                .padding(.bottom, 10)
                
                NavigationButton(icon: "chart.bar", title: L10n.text(.navDashboard), isSelected: selectedTab == 0) { selectedTab = 0 }
                NavigationButton(icon: "laptopcomputer.and.iphone", title: L10n.text(.navDevicesAndBlock), isSelected: selectedTab == 1) { selectedTab = 1 }
                NavigationButton(icon: "wifi.radar", title: L10n.text(.navWlanTelemetry), isSelected: selectedTab == 2) { selectedTab = 2 }
                NavigationButton(icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", title: L10n.text(.navPortForwarding), isSelected: selectedTab == 3) { selectedTab = 3 }
                NavigationButton(icon: "lock.shield", title: L10n.text(.navDnsAndAdBlock), isSelected: selectedTab == 4) { selectedTab = 4 }
                NavigationButton(icon: "terminal", title: L10n.text(.navPacketSniffer), isSelected: selectedTab == 5) { selectedTab = 5 }
                NavigationButton(icon: "gauge.with.needle", title: L10n.text(.navBandwidthShaper), isSelected: selectedTab == 6) { selectedTab = 6 }
                NavigationButton(icon: "waveform.path.ecg", title: L10n.text(.navBridgeQuality), isSelected: selectedTab == 7) { selectedTab = 7 }
                NavigationButton(icon: "questionmark.circle", title: L10n.text(.navSetupGuide), isSelected: selectedTab == 8) { selectedTab = 8 }
                NavigationButton(icon: "person.crop.square", title: L10n.text(.navDeveloperInfo), isSelected: selectedTab == 9) { selectedTab = 9 }
                
                Spacer()
                
                HStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue).font(.caption)
                            Text(L10n.format(.formatSpeedKBps, monitor.downloadSpeed))
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.bold)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill").foregroundColor(.purple).font(.caption)
                            Text(L10n.format(.formatSpeedKBps, monitor.uploadSpeed))
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.bold)
                        }
                    }
                    Button(action: { monitor.forceScan() }) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.05))
                .cornerRadius(6)
                .padding(.bottom, 20)
            }
            .frame(width: 230)
            .background(Color.black.opacity(0.12))
            
            Divider()
            
            VStack(spacing: 0) {
                if showNotice {
                    HStack(spacing: 10) {
                        Image(systemName: noticeSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(noticeSuccess ? .green : .red)
                        Text(noticeMessage)
                            .font(.caption)
                            .fontWeight(.medium)
                        Spacer()
                        Button(action: { showNotice = false }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background((noticeSuccess ? Color.green : Color.red).opacity(0.08))
                    .transition(.move(edge: .top))
                    .animation(.easeInOut, value: showNotice)
                }
                
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selectedTitle())
                            .font(.system(.title2, design: .rounded))
                            .fontWeight(.bold)
                        Text(selectedSubtitle())
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    
                    HStack(spacing: 6) {
                        Circle()
                            .fill(monitor.isInternetSharingActive ? Color.green : Color.amberGlow)
                            .frame(width: 8, height: 8)
                            .shadow(color: (monitor.isInternetSharingActive ? Color.green : Color.amberGlow).opacity(0.5), radius: 3)
                        Text(monitor.isInternetSharingActive ? L10n.text(.repeaterActive) : L10n.text(.repeaterInactive))
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(20)
                }
                .padding(.horizontal, 25)
                .padding(.top, 20)
                .padding(.bottom, 12)
                
                Divider()
                    .padding(.horizontal, 25)
                
                ScrollView {
                    VStack(spacing: 20) {
                        switch selectedTab {
                        case 0: dashboardView()
                        case 1: devicesView()
                        case 2: telemetryView()
                        case 3: forwardingView()
                        case 4: dnsView()
                        case 5: snifferView()
                        case 6: shaperView()
                        case 7: qualityView()
                        case 8: setupGuideView()
                        default: developerInfoView()
                        }
                    }
                    .padding(25)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, idealWidth: 900, maxWidth: .infinity, minHeight: 560, idealHeight: 640, maxHeight: .infinity)
        .background(VisualEffectView())
        .onChange(of: monitor.interfaces) { _, faces in
            applyDefaultInterfaceSelections(faces)
        }
    }

    /// When pickers still hold placeholder en0/en1 (or empty), auto-select Wi-Fi source and iPhone USB target.
    private func applyDefaultInterfaceSelections(_ faces: [NetworkInterface]) {
        guard !faces.isEmpty else { return }
        if sourceInt.isEmpty || sourceInt == "en0" {
            if let wifi = faces.first(where: {
                let t = $0.type.lowercased()
                return t.contains("wi-fi") || t.contains("airport")
            }) {
                sourceInt = wifi.device
            }
        }
        if targetInt.isEmpty || targetInt == "en1" {
            let candidates = faces.map {
                ShareTargetCandidate(device: $0.device, type: $0.type, isActive: $0.isActive)
            }
            if let device = selectDefaultShareTargetDevice(candidates) {
                targetInt = device
            }
        }
    }
    
    private func dashboardView() -> some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(.hotspotControllerTitle))
                    .font(.headline)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text(.sourceInterfaceLabel))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Picker("", selection: $sourceInt) {
                            ForEach(monitor.interfaces) { face in
                                Text("\(face.device) (\(face.type))").tag(face.device)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text(.hotspotOutgoingLabel))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Picker("", selection: $targetInt) {
                            ForEach(monitor.interfaces) { face in
                                Text("\(face.device) (\(face.type))").tag(face.device)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    Spacer()
                    if monitor.isInternetSharingActive {
                        Button(action: {
                            monitor.toggleIntegratedHotspot(enable: false, primary: sourceInt, target: targetInt) { msg, success in
                                displayNotification(message: msg, success: success)
                            }
                        }) {
                            HStack {
                                Image(systemName: "stop.circle.fill")
                                Text(L10n.text(.stopHotspot))
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Color.red)
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button(action: {
                            monitor.toggleIntegratedHotspot(enable: true, primary: sourceInt, target: targetInt) { msg, success in
                                displayNotification(message: msg, success: success)
                            }
                        }) {
                            HStack {
                                Image(systemName: "play.circle.fill")
                                Text(L10n.text(.startHotspot))
                            }
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                .background(Color.primary.opacity(0.04))
                .cornerRadius(10)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text(.connectionFlowTitle))
                    .font(.headline)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    TopologyNode(
                        title: monitor.wlanSSID,
                        subtitle: L10n.text(.topologySourceSsid),
                        icon: "globe",
                        color: .blue
                    )
                    FlowConnector(isActive: true)
                    TopologyNode(
                        title: L10n.text(.topologyMacBridge),
                        subtitle: monitor.sharingBridgeIP ?? L10n.text(.topologyNoBridgeIp),
                        icon: "laptopcomputer",
                        color: monitor.isInternetSharingActive ? .purple : .secondary
                    )
                    FlowConnector(isActive: monitor.isInternetSharingActive)
                    TopologyNode(
                        title: L10n.format(.formatTopologyDeviceCount, monitor.connectedClients.count),
                        subtitle: L10n.text(.topologySharedHotspot),
                        icon: "wifi",
                        color: monitor.isInternetSharingActive && monitor.connectedClients.count > 0 ? .green : .secondary
                    )
                }
                .padding()
                .background(Color.primary.opacity(0.04))
                .cornerRadius(12)
            }
            
            HStack(spacing: 15) {
                StatCard(
                    title: L10n.text(.statDownloadSpeed),
                    value: L10n.format(.formatSpeedKBps, monitor.downloadSpeed),
                    icon: "arrow.down.circle.fill",
                    color: .blue
                )
                StatCard(
                    title: L10n.text(.statUploadSpeed),
                    value: L10n.format(.formatSpeedKBps, monitor.uploadSpeed),
                    icon: "arrow.up.circle.fill",
                    color: .purple
                )
                StatCard(
                    title: L10n.text(.statCumulativeData),
                    value: L10n.format(.formatDataMB, monitor.totalDownloadMB + monitor.totalUploadMB),
                    icon: "externaldrive.fill",
                    color: .green
                )
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text(.detectedHardwareInterfaces))
                    .font(.headline)
                ForEach(monitor.interfaces) { face in
                    InterfaceCard(face: face) {
                        copyToClipboard(face.ipAddress ?? "", type: L10n.text(.clipboardItemIpAddress))
                    }
                }
            }
        }
    }
    
    private func devicesView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L10n.text(.dhcpReservationTitle))
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField(L10n.text(.placeholderMacAddress), text: $reserveMac)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.text(.placeholderDesiredIp), text: $reserveIp)
                        .textFieldStyle(.roundedBorder)
                    Button(action: {
                        guard !reserveMac.isEmpty && !reserveIp.isEmpty else { return }
                        monitor.addIPReservation(mac: reserveMac, ip: reserveIp) { msg, success in
                            displayNotification(message: msg, success: success)
                            if success {
                                reserveMac = ""
                                reserveIp = ""
                            }
                        }
                    }) {
                        Text(L10n.text(.reserveLease))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.primary.opacity(0.04))
                .cornerRadius(10)
            }
            
            Text(L10n.text(.connectedClientsTable))
                .font(.headline)
            if monitor.connectedClients.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(L10n.text(.noClientsOnBridge))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
            } else {
                VStack(spacing: 10) {
                    ForEach(monitor.connectedClients) { client in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.primary.opacity(0.08)).frame(width: 32, height: 32)
                                Image(systemName: client.isBlocked ? "lock.slash.fill" : "personalhotspot").foregroundColor(client.isBlocked ? .red : .primary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.hostname)
                                    .fontWeight(.bold)
                                HStack(spacing: 6) {
                                    Text(client.ipAddress).font(.system(.caption, design: .monospaced))
                                    Text(client.macAddress.uppercased()).font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if client.isReserved {
                                Text(L10n.text(.dhcpReservedBadge))
                                    .font(.system(.caption2, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundColor(.blue)
                                    .cornerRadius(4)
                            }
                            if client.isBlocked {
                                Button(action: {
                                    monitor.unblockClient(client: client) { msg, success in
                                        displayNotification(message: msg, success: success)
                                    }
                                }) {
                                    Text(L10n.text(.unblockDevice))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.green.opacity(0.08))
                                        .foregroundColor(.green)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button(action: {
                                    monitor.blockClient(client: client) { msg, success in
                                        displayNotification(message: msg, success: success)
                                    }
                                }) {
                                    Text(L10n.text(.blockClient))
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.red.opacity(0.08))
                                        .foregroundColor(.red)
                                        .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding()
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }
    
    private func telemetryView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text(.wifiDiagnosticsTitle))
                .font(.headline)
            HStack(spacing: 15) {
                VStack(spacing: 10) {
                    Text(L10n.text(.rssiSignal))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 10)
                            .frame(width: 100, height: 100)
                        Circle()
                            .trim(from: 0.0, to: CGFloat(min(max(Double(monitor.wlanRSSI + 100) / 70.0, 0.0), 1.0)))
                            .stroke(monitor.wlanRSSI > -60 ? Color.green : (monitor.wlanRSSI > -80 ? Color.orange : Color.red), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 100, height: 100)
                            .rotationEffect(.degrees(-90))
                        Text(L10n.format(.formatRssiDbm, monitor.wlanRSSI))
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.bold)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
                
                VStack(spacing: 10) {
                    Text(L10n.text(.noiseLevel))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 10)
                            .frame(width: 100, height: 100)
                        Circle()
                            .trim(from: 0.0, to: CGFloat(min(max(Double(monitor.wlanNoise + 120) / 80.0, 0.0), 1.0)))
                            .stroke(Color.red, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 100, height: 100)
                            .rotationEffect(.degrees(-90))
                        Text(L10n.format(.formatRssiDbm, monitor.wlanNoise))
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.bold)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
                
                VStack(spacing: 10) {
                    Text(L10n.text(.linkTxRate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 10)
                            .frame(width: 100, height: 100)
                        Circle()
                            .trim(from: 0.0, to: CGFloat(min(monitor.wlanTxRate / 1300.0, 1.0)))
                            .stroke(Color.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .frame(width: 100, height: 100)
                            .rotationEffect(.degrees(-90))
                        Text(L10n.format(.formatTxRateMbps, monitor.wlanTxRate))
                            .font(.system(.caption, design: .rounded))
                            .fontWeight(.bold)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
            }
            
            VStack(spacing: 1) {
                TelemetryRow(title: L10n.text(.telemetryActiveSsid), value: monitor.wlanSSID)
                TelemetryRow(title: L10n.text(.telemetryBssid), value: monitor.wlanBSSID)
                TelemetryRow(title: L10n.text(.telemetryRadioChannel), value: "\(monitor.wlanChannel)")
                TelemetryRow(title: L10n.text(.telemetryPhyStandard), value: monitor.wlanPhyMode)
                TelemetryRow(title: L10n.text(.telemetrySnr), value: L10n.format(.formatSnrDb, monitor.wlanRSSI - monitor.wlanNoise))
            }
            .cornerRadius(10)
        }
    }
    
    private func forwardingView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(.portForwardFormTitle))
                    .font(.headline)
                HStack(spacing: 12) {
                    TextField(L10n.text(.placeholderExtPort), text: $extPort)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.text(.placeholderClientIp), text: $clientIP)
                        .textFieldStyle(.roundedBorder)
                    TextField(L10n.text(.placeholderIntPort), text: $intPort)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $selectedProto) {
                        Text("TCP").tag("TCP")
                        Text("UDP").tag("UDP")
                    }
                    .labelsHidden()
                    .frame(width: 80)
                    Button(action: {
                        guard !extPort.isEmpty && !clientIP.isEmpty && !intPort.isEmpty else { return }
                        monitor.addPortForwardRule(external: extPort, clientIP: clientIP, internalPort: intPort, protocolType: selectedProto) { msg, success in
                            displayNotification(message: msg, success: success)
                            if success {
                                extPort = ""
                                clientIP = ""
                                intPort = ""
                            }
                        }
                    }) {
                        Text(L10n.text(.addRule))
                            .fontWeight(.semibold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                .padding()
                .background(Color.primary.opacity(0.04))
                .cornerRadius(10)
            }
            
            Text(L10n.text(.activeRedirectAnchors))
                .font(.headline)
            if monitor.portRules.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "shuffle.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(L10n.text(.noPortForwardingRules))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
            } else {
                VStack(spacing: 8) {
                    ForEach(monitor.portRules) { rule in
                        HStack {
                            Text(rule.protocolType)
                                .font(.system(.caption, design: .rounded))
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.12))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                            Text(L10n.format(.formatExternalPort, rule.externalPort))
                                .fontWeight(.semibold)
                            Image(systemName: "arrow.right").foregroundColor(.secondary)
                            Text("\(rule.internalIP) : \(rule.internalPort)")
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Button(action: {
                                monitor.deletePortForwardRule(rule: rule)
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding()
                        .background(Color.primary.opacity(0.04))
                        .cornerRadius(8)
                    }
                }
            }
        }
    }
    
    private func dnsView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text(.dnsSectionTitle))
                .font(.headline)
            Text(L10n.text(.dnsSectionDescription))
                .foregroundColor(.secondary)
            VStack(spacing: 12) {
                DNSTemplateCard(title: L10n.text(.dnsCardSystemDefaultsTitle), desc: L10n.text(.dnsCardSystemDefaultsDesc), isSelected: monitor.currentDNSMode == "System Defaults") {
                    monitor.applyDNSOverride(mode: "Defaults") { msg, success in displayNotification(message: msg, success: success) }
                }
                DNSTemplateCard(title: L10n.text(.dnsCardCloudflareTitle), desc: L10n.text(.dnsCardCloudflareDesc), isSelected: monitor.currentDNSMode == "Cloudflare") {
                    monitor.applyDNSOverride(mode: "Cloudflare") { msg, success in displayNotification(message: msg, success: success) }
                }
                DNSTemplateCard(title: L10n.text(.dnsCardGoogleTitle), desc: L10n.text(.dnsCardGoogleDesc), isSelected: monitor.currentDNSMode == "Google") {
                    monitor.applyDNSOverride(mode: "Google") { msg, success in displayNotification(message: msg, success: success) }
                }
                DNSTemplateCard(title: L10n.text(.dnsCardAdGuardTitle), desc: L10n.text(.dnsCardAdGuardDesc), isSelected: monitor.currentDNSMode == "AdGuard (AdBlock)") {
                    monitor.applyDNSOverride(mode: "AdGuard (AdBlock)") { msg, success in displayNotification(message: msg, success: success) }
                }
            }
        }
    }
    
    private func snifferView() -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(L10n.text(.snifferTitle))
                    .font(.headline)
                Spacer()
                Button(action: {
                    monitor.runTrafficSniffer()
                }) {
                    HStack {
                        if monitor.isSniffing {
                            ProgressView().scaleEffect(0.6).frame(width: 15, height: 15)
                            Text(L10n.text(.snifferCapturing))
                        } else {
                            Image(systemName: "eye")
                            Text(L10n.text(.snifferCapturePackets))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(monitor.isSniffing ? Color.secondary : Color.blue)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isSniffing)
            }
            Text(L10n.text(.snifferDescription))
                .font(.caption)
                .foregroundColor(.secondary)
            VStack {
                if monitor.snifferPackets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text(L10n.text(.snifferConsoleEmpty))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 250)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(monitor.snifferPackets) { pkt in
                                HStack(spacing: 8) {
                                    Text("[\(pkt.timestamp)]")
                                        .foregroundColor(.green)
                                    Text(pkt.protocolType)
                                        .foregroundColor(.purple)
                                        .fontWeight(.bold)
                                        .frame(width: 40, alignment: .leading)
                                    Text(pkt.source)
                                        .foregroundColor(.cyan)
                                    Text(">")
                                        .foregroundColor(.secondary)
                                    Text(pkt.destination)
                                        .foregroundColor(.orange)
                                    Text(pkt.info)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 280)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 1)
            )
        }
    }
    
    private func shaperView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text(.shaperTitle))
                .font(.headline)
            Text(L10n.text(.shaperDescription))
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text(L10n.text(.capSpeedRateLabel))
                        .fontWeight(.semibold)
                    Spacer()
                    Text(monitor.currentShaperSpeed == 0 ? L10n.text(.shaperUnlimited) : L10n.format(.formatShaperSpeedMbps, Int(monitor.currentShaperSpeed)))
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
                HStack(spacing: 12) {
                    SpeedOptionButton(title: L10n.text(.shaperOptionUnlimitedDisable), speed: 0.0, current: monitor.currentShaperSpeed) {
                        monitor.applySpeedLimiter(speedMbps: 0.0) { msg, success in displayNotification(message: msg, success: success) }
                    }
                    SpeedOptionButton(title: L10n.text(.shaperOption2MbpsSlow), speed: 2.0, current: monitor.currentShaperSpeed) {
                        monitor.applySpeedLimiter(speedMbps: 2.0) { msg, success in displayNotification(message: msg, success: success) }
                    }
                    SpeedOptionButton(title: L10n.text(.shaperOption5MbpsStandard), speed: 5.0, current: monitor.currentShaperSpeed) {
                        monitor.applySpeedLimiter(speedMbps: 5.0) { msg, success in displayNotification(message: msg, success: success) }
                    }
                    SpeedOptionButton(title: L10n.text(.shaperOption10MbpsFast), speed: 10.0, current: monitor.currentShaperSpeed) {
                        monitor.applySpeedLimiter(speedMbps: 10.0) { msg, success in displayNotification(message: msg, success: success) }
                    }
                }
            }
            .padding()
            .background(Color.primary.opacity(0.04))
            .cornerRadius(10)
        }
    }
    
    private func qualityView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(L10n.text(.qualityTitle))
                    .font(.headline)
                Spacer()
                Button(action: {
                    monitor.runQualityDiagnostics()
                }) {
                    HStack {
                        if monitor.isTestingPing {
                            ProgressView().scaleEffect(0.6).frame(width: 15, height: 15)
                            Text(L10n.text(.qualityPinging))
                        } else {
                            Image(systemName: "waveform.path.ecg")
                            Text(L10n.text(.qualityRunDiagnostic))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(monitor.isTestingPing ? Color.secondary : Color.purple)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(monitor.isTestingPing)
            }
            Text(L10n.text(.qualityDescription))
                .foregroundColor(.secondary)
            HStack(spacing: 15) {
                VStack(spacing: 8) {
                    Text(L10n.text(.qualityLatencyRtt))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L10n.format(.formatLatencyMs, monitor.pingLatency))
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(monitor.pingLatency == 0 ? .secondary : (monitor.pingLatency < 50 ? .green : (monitor.pingLatency < 120 ? .orange : .red)))
                    Text(monitor.pingLatency == 0 ? L10n.text(.qualityDiagnosticIdle) : (monitor.pingLatency < 50 ? L10n.text(.qualityExcellentIdeal) : L10n.text(.qualityHighDelay)))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
                
                VStack(spacing: 8) {
                    Text(L10n.text(.qualityPacketLossRate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(L10n.format(.formatPacketLossPercent, monitor.pingLoss))
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(monitor.pingLoss == 0 ? .green : .red)
                    Text(monitor.pingLoss == 0 ? L10n.text(.qualityPerfect) : L10n.text(.qualityDroppedPackets))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
            }
        }
    }
    
    private func setupGuideView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text(.setupSectionTitle))
                .font(.headline)
            SetupMethodCard(
                number: "1",
                title: L10n.text(.setupMethod1Title),
                difficulty: L10n.text(.setupMethod1Difficulty),
                desc: L10n.text(.setupMethod1Desc),
                steps: [
                    L10n.text(.setupMethod1Step1),
                    L10n.text(.setupMethod1Step2),
                    L10n.text(.setupMethod1Step3),
                    L10n.text(.setupMethod1Step4)
                ]
            )
            SetupMethodCard(
                number: "2",
                title: L10n.text(.setupMethod2Title),
                difficulty: L10n.text(.setupMethod2Difficulty),
                desc: L10n.text(.setupMethod2Desc),
                steps: [
                    L10n.text(.setupMethod2Step1),
                    L10n.text(.setupMethod2Step2),
                    L10n.text(.setupMethod2Step3)
                ]
            )
        }
    }
    
    private func developerInfoView() -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 15) {
                AsyncImage(url: URL(string: "https://github.com/tiwut.png")!) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                    default:
                        Circle()
                            .fill(LinearGradient(colors: [.cyan, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Text("T")
                                    .font(.system(size: 40, design: .rounded))
                                    .fontWeight(.black)
                                    .foregroundColor(.white)
                            )
                    }
                }
                .shadow(color: .purple.opacity(0.4), radius: 8)
                
                VStack(spacing: 4) {
                    Text("Tiwut")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                    Text(L10n.text(.developerRole))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text(L10n.text(.developerBio))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .lineLimit(nil)
                
                HStack(spacing: 20) {
                    Link(destination: URL(string: "http://tiwut.org")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "safari")
                            Text("tiwut.org")
                                .fontWeight(.bold)
                        }
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.1))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    
                    Link(destination: URL(string: "https://github.com/tiwut")!) {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal")
                            Text("github.com/tiwut")
                                .fontWeight(.bold)
                        }
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.purple.opacity(0.1))
                        .foregroundColor(.purple)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.03))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        LinearGradient(
                            colors: [.cyan.opacity(0.2), .purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
            )
            
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(.developerDiagnosticsTitle))
                    .font(.headline)
                VStack(spacing: 1) {
                    TelemetryRow(title: L10n.text(.developerActiveDeveloper), value: "Tiwut")
                    TelemetryRow(title: L10n.text(.developerHostname), value: ProcessInfo.processInfo.hostName)
                    TelemetryRow(title: L10n.text(.developerMacosVersion), value: ProcessInfo.processInfo.operatingSystemVersionString)
                    TelemetryRow(title: L10n.text(.developerSwiftVersion), value: L10n.text(.developerSwiftVersionValue))
                }
                .cornerRadius(10)
            }
        }
    }
    
    private func selectedTitle() -> String {
        switch selectedTab {
        case 0: return L10n.text(.headerTitleDashboard)
        case 1: return L10n.text(.headerTitleClientManagement)
        case 2: return L10n.text(.headerTitleWlanTelemetry)
        case 3: return L10n.text(.headerTitlePortForwarding)
        case 4: return L10n.text(.headerTitleDns)
        case 5: return L10n.text(.headerTitleSniffer)
        case 6: return L10n.text(.headerTitleShaper)
        case 7: return L10n.text(.headerTitleQuality)
        case 8: return L10n.text(.headerTitleSetupGuide)
        default: return L10n.text(.headerTitleAboutDeveloper)
        }
    }
    
    private func selectedSubtitle() -> String {
        switch selectedTab {
        case 0: return L10n.text(.headerSubtitleDashboard)
        case 1: return L10n.text(.headerSubtitleClientManagement)
        case 2: return L10n.text(.headerSubtitleWlanTelemetry)
        case 3: return L10n.text(.headerSubtitlePortForwarding)
        case 4: return L10n.text(.headerSubtitleDns)
        case 5: return L10n.text(.headerSubtitleSniffer)
        case 6: return L10n.text(.headerSubtitleShaper)
        case 7: return L10n.text(.headerSubtitleQuality)
        case 8: return L10n.text(.headerSubtitleSetupGuide)
        default: return L10n.text(.headerSubtitleDeveloper)
        }
    }
    
    private func displayNotification(message: String, success: Bool) {
        noticeMessage = message
        noticeSuccess = success
        showNotice = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            showNotice = false
        }
    }
    
    private func copyToClipboard(_ text: String, type: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        displayNotification(message: L10n.format(.copiedToClipboard, type, text), success: true)
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .monospaced))
                .fontWeight(.bold)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }
}

struct TelemetryRow: View {
    let title: String
    let value: String
    
    var body: some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .font(.system(.body, design: .monospaced))
        }
        .padding()
        .background(Color.primary.opacity(0.04))
    }
}

struct DNSTemplateCard: View {
    let title: String
    let desc: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.blue.opacity(0.12) : Color.primary.opacity(0.05))
                        .frame(width: 36, height: 36)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "lock.shield").foregroundColor(isSelected ? .blue : .secondary)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fontWeight(.bold)
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding()
            .background(Color.primary.opacity(0.04))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SpeedOptionButton: View {
    let title: String
    let speed: Double
    let current: Double
    let action: () -> Void
    
    var isSelected: Bool {
        return current == speed
    }
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .fontWeight(.bold)
                .font(.caption)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(isSelected ? Color.blue : Color.primary.opacity(0.06))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

struct NavigationButton: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 20)
                
                Text(title)
                    .font(.system(.subheadline, design: .rounded))
                    .fontWeight(.semibold)
                
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .background(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            .foregroundColor(isSelected ? .primary : .secondary)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }
}

struct TopologyNode: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.1))
                    .frame(width: 44, height: 44)
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundColor(color)
            }
            Text(title)
                .font(.system(.subheadline, design: .rounded))
                .fontWeight(.bold)
                .lineLimit(1)
            Text(subtitle)
                .font(.system(.caption2, design: .rounded))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.08))
        .cornerRadius(10)
    }
}

struct FlowConnector: View {
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                Circle()
                    .fill(isActive ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(width: 25)
    }
}

struct InterfaceCard: View {
    let face: NetworkInterface
    let copyAction: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(face.isActive ? Color.blue.opacity(0.1) : Color.primary.opacity(0.05))
                    .frame(width: 36, height: 36)
                Image(systemName: interfaceIcon(for: face.type))
                    .font(.system(size: 16))
                    .foregroundColor(face.isActive ? .blue : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(face.type)
                        .fontWeight(.bold)
                    Text(face.device)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08))
                        .cornerRadius(4)
                }
                if let ssid = face.ssid {
                    Text(L10n.format(.formatSsidLabel, ssid)).font(.caption).foregroundColor(.blue)
                } else {
                    Text(face.macAddress.uppercased()).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if face.isActive {
                Button(action: copyAction) {
                    HStack(spacing: 4) {
                        Text(face.ipAddress ?? L10n.text(.interfaceNoIp)).font(.system(.caption, design: .monospaced))
                        Image(systemName: "doc.on.doc").font(.system(size: 9))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.blue.opacity(0.08))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            } else {
                Text(L10n.text(.interfaceInactive))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.05))
                    .cornerRadius(6)
            }
        }
        .padding()
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }
    
    private func interfaceIcon(for type: String) -> String {
        let t = type.lowercased()
        if t.contains("wi-fi") || t.contains("airport") { return "wifi" }
        if t.contains("ethernet") { return "cable.connector" }
        if t.contains("thunderbolt") { return "bolt.fill" }
        return "network"
    }
}

struct SetupMethodCard: View {
    let number: String
    let title: String
    let difficulty: String
    let desc: String
    let steps: [String]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.blue.opacity(0.1)).frame(width: 24, height: 24)
                    Text(number).fontWeight(.bold).foregroundColor(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.bold)
                    Text(difficulty).font(.caption2).foregroundColor(.secondary)
                }
            }
            Text(desc)
                .font(.caption)
                .foregroundColor(.primary.opacity(0.8))
                .lineLimit(nil)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { idx in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .frame(width: 12, alignment: .trailing)
                        Text(steps[idx])
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.primary.opacity(0.04))
        .cornerRadius(10)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let contentView = ContentView()
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.center()
        window.title = L10n.text(.appName)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
