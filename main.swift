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
            let errorMsg = errorInfo?[NSAppleScript.errorMessage] as? String ?? "Authorization Failed"
            return (errorMsg, false)
        }
    }
}

class NetworkMonitor: ObservableObject {
    @Published var interfaces: [NetworkInterface] = []
    @Published var connectedClients: [ConnectedClient] = []
    @Published var isInternetSharingActive: Bool = false
    @Published var sharingBridgeIP: String? = nil
    @Published var isScanning: Bool = false
    @Published var wlanSSID: String = "Not Connected"
    @Published var wlanBSSID: String = "--:--:--:--:--:--"
    @Published var wlanRSSI: Int = 0
    @Published var wlanNoise: Int = 0
    @Published var wlanTxRate: Double = 0.0
    @Published var wlanChannel: Int = 0
    @Published var wlanPhyMode: String = "Unknown"
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
    
    init() {
        refreshData()
        timer = Timer.publish(every: 3.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshData()
                self?.refreshSpeedometer()
                self?.refreshWLANTelemetry()
            }
    }
    
    func forceScan() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.refreshData()
            self.refreshWLANTelemetry()
            DispatchQueue.main.async {
                self.isScanning = false
            }
        }
    }
    
    func refreshData() {
        let hardwarePorts = parseHardwarePorts()
        let ipAddresses = parseIPAddresses()
        let activeSSIDs = fetchSSIDs(interfaces: hardwarePorts.keys.map { String($0) })
        var detectedInterfaces: [NetworkInterface] = []
        for (device, type) in hardwarePorts {
            let mac = fetchMACAddress(device: device)
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
        let bridgeIP = ipAddresses["bridge100"] ?? ipAddresses["bridge0"]
        let hasActiveBridge = bridgeIP != nil
        let leases = parseDHCPLeases()
        let activeARPMapping = parseARPCache()
        var clients: [ConnectedClient] = []
        for lease in leases {
            let isCurrent = activeARPMapping[lease.macAddress] != nil || activeARPMapping[lease.ipAddress] != nil
            var client = lease
            client.isActive = isCurrent
            client.isBlocked = blockedMacs.contains(client.macAddress.lowercased())
            client.isReserved = reservedIPs[client.macAddress.lowercased()] != nil
            clients.append(client)
        }
        var uniqueClients = [String: ConnectedClient]()
        for client in clients {
            uniqueClients[client.macAddress.lowercased()] = client
        }
        let sortedClients = Array(uniqueClients.values).sorted(by: { $0.ipAddress < $1.ipAddress })
        DispatchQueue.main.async {
            self.interfaces = detectedInterfaces.sorted(by: { $0.device < $1.device })
            self.connectedClients = sortedClients
            self.isInternetSharingActive = hasActiveBridge
            self.sharingBridgeIP = bridgeIP
        }
    }
    
    func refreshWLANTelemetry() {
        guard let interface = CWWiFiClient.shared().interface() else { return }
        let ssid = interface.ssid() ?? "Not Associated"
        let bssid = interface.bssid() ?? "--:--:--:--:--:--"
        let rssi = interface.rssiValue()
        let noise = interface.noiseMeasurement()
        let txRate = interface.transmitRate()
        let channel = interface.wlanChannel()?.channelNumber ?? 0
        let phyModeVal: String
        switch interface.activePHYMode() {
        case .mode11a: phyModeVal = "802.11a"
        case .mode11b: phyModeVal = "802.11b"
        case .mode11g: phyModeVal = "802.11g"
        case .mode11n: phyModeVal = "802.11n"
        case .mode11ac: phyModeVal = "802.11ac"
        case .mode11ax: phyModeVal = "802.11ax (Wi-Fi 6)"
        case .mode11be: phyModeVal = "802.11be (Wi-Fi 7)"
        default: phyModeVal = "802.11 Mixed"
        }
        DispatchQueue.main.async {
            self.wlanSSID = ssid
            self.wlanBSSID = bssid
            self.wlanRSSI = rssi
            self.wlanNoise = noise
            self.wlanTxRate = txRate
            self.wlanChannel = channel
            self.wlanPhyMode = phyModeVal
        }
    }
    
    func refreshSpeedometer() {
        let targetInterface = isInternetSharingActive ? "bridge100" : "en0"
        let output = shell("netstat -ib -I \(targetInterface)")
        var currentIn: Double = 0.0
        var currentOut: Double = 0.0
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            if line.contains("<Link#") {
                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 10 {
                    currentIn = Double(parts[6]) ?? 0.0
                    currentOut = Double(parts[9]) ?? 0.0
                    break
                }
            }
        }
        let now = Date()
        let interval = now.timeIntervalSince(lastSpeedCheckTime)
        if lastInBytes > 0 && interval > 0 {
            let dlSpeed = ((currentIn - lastInBytes) / interval) / 1024.0
            let ulSpeed = ((currentOut - lastOutBytes) / interval) / 1024.0
            DispatchQueue.main.async {
                self.downloadSpeed = max(0.0, dlSpeed)
                self.uploadSpeed = max(0.0, ulSpeed)
                self.totalDownloadMB = currentIn / (1024.0 * 1024.0)
                self.totalUploadMB = currentOut / (1024.0 * 1024.0)
            }
        }
        lastInBytes = currentIn
        lastOutBytes = currentOut
        lastSpeedCheckTime = now
    }
    
    func toggleIntegratedHotspot(enable: Bool, primary: String, target: String, completion: @escaping (String, Bool) -> Void) {
        DispatchQueue.global(qos: .userInteractive).async {
            let cmd: String
            if enable {
                let configPrimary = "defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict PrimaryInterface '{ Device = \(primary); Enabled = 1; HardwarePort = \"Wi-Fi\"; }'"
                let configSharing = "defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add SharingInterfaces '{ \(target) = { Device = \(target); Enabled = 1; HardwarePort = \"Wi-Fi\"; }; }'"
                let configEnable = "defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add Enabled -int 1"
                let loadDaemon = "launchctl load -w /System/Library/LaunchDaemons/com.apple.InternetSharing.plist"
                cmd = "\(configPrimary) && \(configSharing) && \(configEnable) && \(loadDaemon)"
            } else {
                let disableFlag = "defaults write /Library/Preferences/SystemConfiguration/com.apple.nat NAT -dict-add Enabled -int 0"
                let unloadDaemon = "launchctl unload -w /System/Library/LaunchDaemons/com.apple.InternetSharing.plist"
                cmd = "\(disableFlag) && \(unloadDaemon)"
            }
            let (msg, success) = AdminManager.runAsAdmin(cmd)
            self.refreshData()
            DispatchQueue.main.async {
                completion(success ? "Hotspot toggled successfully." : "Error toggling hotspot: \(msg)", success)
            }
        }
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
                    self.refreshData()
                }
            }
            DispatchQueue.main.async {
                completion(success ? "Client \(client.hostname) has been blocked on firewall." : "Firewall Error: \(msg)", success)
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
                completion(success ? "Firewall rules flushed. Device is unblocked." : "Firewall Error: \(msg)", success)
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
        self.refreshData()
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
                    completion("DNS settings reverted to System Defaults.", true)
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
                    completion("Successfully configured shared bridge DNS to \(mode) (\(dnsServers.joined(separator: ", "))).", true)
                } else {
                    completion("Error overriding DNS: \(msg)", false)
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
                    completion("Redirect rule successfully loaded in Packet Filter (Port \(external) ➡️ \(clientIP):\(internalPort)).", true)
                } else {
                    completion("Error applying Redirect: \(msg)", false)
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
        let bridge = isInternetSharingActive ? "bridge100" : "en0"
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
                    completion("Bandwidth shaper successfully disabled. Unlimited speed.", true)
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
                    completion("Successfully limited hotspot clients download bandwidth to \(Int(speedMbps)) Mbps.", true)
                } else {
                    completion("Dummynet Error: \(msg)", false)
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
                    self.refreshData()
                    completion("Static lease configured inside /etc/bootpd.plist (MAC \(cleanMac) ➡️ IP \(cleanIp)).", true)
                } else {
                    completion("DHCP Config Error: \(msg)", false)
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
    
    private func parseIPAddresses() -> [String: String] {
        var ips: [String: String] = [:]
        let output = shell("ifconfig")
        let sections = output.components(separatedBy: "\n")
        var currentInterface = ""
        for line in sections {
            if line.isEmpty { continue }
            if let firstWord = line.components(separatedBy: .whitespaces).first, firstWord.contains(":") {
                currentInterface = firstWord.replacingOccurrences(of: ":", with: "")
            }
            if currentInterface.isEmpty { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("inet ") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count > 1 {
                    ips[currentInterface] = parts[1]
                }
            }
        }
        return ips
    }
    
    private func fetchMACAddress(device: String) -> String {
        let output = shell("ifconfig \(device)")
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("ether ") {
                return trimmed.replacingOccurrences(of: "ether ", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return "Unknown"
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
                var name = "Unknown Device"
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
                    Text("AirBridge Pro")
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                }
                .padding(.top, 20)
                .padding(.bottom, 10)
                
                NavigationButton(icon: "chart.bar", title: "Dashboard", isSelected: selectedTab == 0) { selectedTab = 0 }
                NavigationButton(icon: "laptopcomputer.and.iphone", title: "Devices & Block", isSelected: selectedTab == 1) { selectedTab = 1 }
                NavigationButton(icon: "wifi.radar", title: "WLAN Telemetry", isSelected: selectedTab == 2) { selectedTab = 2 }
                NavigationButton(icon: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left", title: "Port Forwarding", isSelected: selectedTab == 3) { selectedTab = 3 }
                NavigationButton(icon: "lock.shield", title: "DNS & AdBlock", isSelected: selectedTab == 4) { selectedTab = 4 }
                NavigationButton(icon: "terminal", title: "Packet Sniffer", isSelected: selectedTab == 5) { selectedTab = 5 }
                NavigationButton(icon: "gauge.with.needle", title: "Bandwidth Shaper", isSelected: selectedTab == 6) { selectedTab = 6 }
                NavigationButton(icon: "waveform.path.ecg", title: "Bridge Quality", isSelected: selectedTab == 7) { selectedTab = 7 }
                NavigationButton(icon: "questionmark.circle", title: "Setup Guide", isSelected: selectedTab == 8) { selectedTab = 8 }
                NavigationButton(icon: "person.crop.square", title: "Developer Info", isSelected: selectedTab == 9) { selectedTab = 9 }
                
                Spacer()
                
                HStack(spacing: 15) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill").foregroundColor(.blue).font(.caption)
                            Text(String(format: "%.1f KB/s", monitor.downloadSpeed))
                                .font(.system(.caption2, design: .monospaced))
                                .fontWeight(.bold)
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.circle.fill").foregroundColor(.purple).font(.caption)
                            Text(String(format: "%.1f KB/s", monitor.uploadSpeed))
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
                        Text(monitor.isInternetSharingActive ? "Repeater Active" : "Repeater Inactive")
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
    }
    
    private func dashboardView() -> some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Integrated Hotspot Controller")
                    .font(.headline)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source Interface (Wi-Fi/Client)")
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
                        Text("Hotspot Outgoing (AP)")
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
                            monitor.toggleIntegratedHotspot(enable: false, primary: "", target: "") { msg, success in
                                displayNotification(message: msg, success: success)
                            }
                        }) {
                            HStack {
                                Image(systemName: "stop.circle.fill")
                                Text("Stop Hotspot")
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
                                Text("Start Hotspot")
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
                Text("Real-time Connection Flow")
                    .font(.headline)
                    .foregroundColor(.secondary)
                HStack(spacing: 12) {
                    TopologyNode(
                        title: monitor.wlanSSID,
                        subtitle: "Source SSID",
                        icon: "globe",
                        color: .blue
                    )
                    FlowConnector(isActive: true)
                    TopologyNode(
                        title: "Mac Bridge",
                        subtitle: monitor.sharingBridgeIP ?? "No Bridge IP",
                        icon: "laptopcomputer",
                        color: monitor.isInternetSharingActive ? .purple : .secondary
                    )
                    FlowConnector(isActive: monitor.isInternetSharingActive)
                    TopologyNode(
                        title: "\(monitor.connectedClients.count) Devices",
                        subtitle: "Shared Hotspot",
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
                    title: "Download Speed",
                    value: String(format: "%.1f KB/s", monitor.downloadSpeed),
                    icon: "arrow.down.circle.fill",
                    color: .blue
                )
                StatCard(
                    title: "Upload Speed",
                    value: String(format: "%.1f KB/s", monitor.uploadSpeed),
                    icon: "arrow.up.circle.fill",
                    color: .purple
                )
                StatCard(
                    title: "Cumulative Data",
                    value: String(format: "%.1f MB", monitor.totalDownloadMB + monitor.totalUploadMB),
                    icon: "externaldrive.fill",
                    color: .green
                )
            }
            
            VStack(alignment: .leading, spacing: 10) {
                Text("Detected Hardware interfaces")
                    .font(.headline)
                ForEach(monitor.interfaces) { face in
                    InterfaceCard(face: face) {
                        copyToClipboard(face.ipAddress ?? "", type: "IP Address")
                    }
                }
            }
        }
    }
    
    private func devicesView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add Dynamic DHCP IP Reservation")
                    .font(.headline)
                HStack(spacing: 10) {
                    TextField("MAC Address (e.g. 3c:13:d6:23:10:f5)", text: $reserveMac)
                        .textFieldStyle(.roundedBorder)
                    TextField("Desired IP Address (e.g. 192.168.2.80)", text: $reserveIp)
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
                        Text("Reserve Lease")
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
            
            Text("Connected Clients Table")
                .font(.headline)
            if monitor.connectedClients.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No clients found on DHCP bridge network.")
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
                                Text("DHCP Reserved")
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
                                    Text("Unblock Device")
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
                                    Text("Block Client")
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
            Text("Detailed Wi-Fi Signal Diagnostics")
                .font(.headline)
            HStack(spacing: 15) {
                VStack(spacing: 10) {
                    Text("RSSI (Signal)")
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
                        Text("\(monitor.wlanRSSI) dBm")
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.bold)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
                
                VStack(spacing: 10) {
                    Text("Noise Level")
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
                        Text("\(monitor.wlanNoise) dBm")
                            .font(.system(.body, design: .rounded))
                            .fontWeight(.bold)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(12)
                
                VStack(spacing: 10) {
                    Text("Link Tx Rate")
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
                        Text(String(format: "%.0f Mbps", monitor.wlanTxRate))
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
                TelemetryRow(title: "Active SSID", value: monitor.wlanSSID)
                TelemetryRow(title: "BSSID (Access Point)", value: monitor.wlanBSSID)
                TelemetryRow(title: "Radio Channel", value: "\(monitor.wlanChannel)")
                TelemetryRow(title: "PHY Standard Mode", value: monitor.wlanPhyMode)
                TelemetryRow(title: "Signal-to-Noise Ratio (SNR)", value: "\(monitor.wlanRSSI - monitor.wlanNoise) dB")
            }
            .cornerRadius(10)
        }
    }
    
    private func forwardingView() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Load Redirect Rule into Packet Filter (PF)")
                    .font(.headline)
                HStack(spacing: 12) {
                    TextField("Ext Port (e.g. 8080)", text: $extPort)
                        .textFieldStyle(.roundedBorder)
                    TextField("Client IP (e.g. 192.168.2.5)", text: $clientIP)
                        .textFieldStyle(.roundedBorder)
                    TextField("Int Port (e.g. 80)", text: $intPort)
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
                        Text("Add Rule")
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
            
            Text("Active Redirect Anchors")
                .font(.headline)
            if monitor.portRules.isEmpty {
                VStack(spacing: 15) {
                    Image(systemName: "shuffle.circle")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No active port forwarding redirects loaded.")
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
                            Text("External Port: \(rule.externalPort)")
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
            Text("Fast DNS Server Redirection")
                .font(.headline)
            Text("Force all shared clients to resolve domain names through specific servers. Toggling DNS values updates bootpd.plist on the fly.")
                .foregroundColor(.secondary)
            VStack(spacing: 12) {
                DNSTemplateCard(title: "System Defaults", desc: "Use the primary DNS server configured on your Mac's active interface.", isSelected: monitor.currentDNSMode == "System Defaults") {
                    monitor.applyDNSOverride(mode: "Defaults") { msg, success in displayNotification(message: msg, success: success) }
                }
                DNSTemplateCard(title: "Cloudflare Fast DNS", desc: "Configures 1.1.1.1 & 1.0.0.1 for high-speed browsing and extreme privacy.", isSelected: monitor.currentDNSMode == "Cloudflare") {
                    monitor.applyDNSOverride(mode: "Cloudflare") { msg, success in displayNotification(message: msg, success: success) }
                }
                DNSTemplateCard(title: "Google Public DNS", desc: "Configures 8.8.8.8 & 8.8.4.4 for ultra-reliable global routing.", isSelected: monitor.currentDNSMode == "Google") {
                    monitor.applyDNSOverride(mode: "Google") { msg, success in displayNotification(message: msg, success: success) }
                }
                DNSTemplateCard(title: "AdGuard Ad-Blocker DNS", desc: "Configures 94.140.14.14 & 94.140.15.15 to automatically drop ad domains and telemetry tracking.", isSelected: monitor.currentDNSMode == "AdGuard (AdBlock)") {
                    monitor.applyDNSOverride(mode: "AdGuard (AdBlock)") { msg, success in displayNotification(message: msg, success: success) }
                }
            }
        }
    }
    
    private func snifferView() -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Live Packet Flow Terminal Capture (tcpdump)")
                    .font(.headline)
                Spacer()
                Button(action: {
                    monitor.runTrafficSniffer()
                }) {
                    HStack {
                        if monitor.isSniffing {
                            ProgressView().scaleEffect(0.6).frame(width: 15, height: 15)
                            Text("Sniffing Live IP Packets...")
                        } else {
                            Image(systemName: "eye")
                            Text("Capture Packets")
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
            Text("Extracts active communication sockets from the active bridge interfaces. Safe, isolated sniffer automatically ends after 15 packet readings.")
                .font(.caption)
                .foregroundColor(.secondary)
            VStack {
                if monitor.snifferPackets.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("Terminal Console is empty. Press Capture Packets above.")
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
            Text("Bandwidth Throttler (Traffic Capper)")
                .font(.headline)
            Text("Throttle the download and upload bandwidth on all shared AP networks to prevent clients from consuming all your system's network capacity.")
                .foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Text("Cap Speed Rate:")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(monitor.currentShaperSpeed == 0 ? "Unlimited" : "\(Int(monitor.currentShaperSpeed)) Mbps")
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.bold)
                        .foregroundColor(.blue)
                }
                HStack(spacing: 12) {
                    SpeedOptionButton(title: "Unlimited (Disable)", speed: 0.0, current: monitor.currentShaperSpeed) {
                        monitor.applySpeedLimiter(speedMbps: 0.0) { msg, success in displayNotification(message: msg, success: success) }
                    }
                    SpeedOptionButton(title: "2 Mbps (Slow)", speed: 2.0, current: monitor.currentShaperSpeed) {
                        monitor.applySpeedLimiter(speedMbps: 2.0) { msg, success in displayNotification(message: msg, success: success) }
                    }
                    SpeedOptionButton(title: "5 Mbps (Standard)", speed: 5.0, current: monitor.currentShaperSpeed) {
                        monitor.applySpeedLimiter(speedMbps: 5.0) { msg, success in displayNotification(message: msg, success: success) }
                    }
                    SpeedOptionButton(title: "10 Mbps (Fast)", speed: 10.0, current: monitor.currentShaperSpeed) {
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
                Text("Active Repeater Ping Quality Diagnostics")
                    .font(.headline)
                Spacer()
                Button(action: {
                    monitor.runQualityDiagnostics()
                }) {
                    HStack {
                        if monitor.isTestingPing {
                            ProgressView().scaleEffect(0.6).frame(width: 15, height: 15)
                            Text("Pinging Target...")
                        } else {
                            Image(systemName: "waveform.path.ecg")
                            Text("Run Ping Diagnostic")
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
            Text("Pings high-reliability nodes (1.1.1.1) to measure real-time latency, connection quality, packet loss, and potential signal jitter added by the repeater bridge.")
                .foregroundColor(.secondary)
            HStack(spacing: 15) {
                VStack(spacing: 8) {
                    Text("Connection Latency (RTT)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f ms", monitor.pingLatency))
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(monitor.pingLatency == 0 ? .secondary : (monitor.pingLatency < 50 ? .green : (monitor.pingLatency < 120 ? .orange : .red)))
                    Text(monitor.pingLatency == 0 ? "Diagnostic Idle" : (monitor.pingLatency < 50 ? "Excellent / Ideal" : "High Delay"))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.primary.opacity(0.03))
                .cornerRadius(10)
                
                VStack(spacing: 8) {
                    Text("Packet Loss Rate")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(String(format: "%.0f%%", monitor.pingLoss))
                        .font(.system(.title, design: .rounded))
                        .fontWeight(.bold)
                        .foregroundColor(monitor.pingLoss == 0 ? .green : .red)
                    Text(monitor.pingLoss == 0 ? "Perfect Quality" : "Dropped packets detected")
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
            Text("Repeater Bridge Hardware Combinations")
                .font(.headline)
            SetupMethodCard(
                number: "1",
                title: "Wi-Fi to Wi-Fi Repeater (Dual Wireless Interface)",
                difficulty: "Requires USB Wi-Fi dongle",
                desc: "Enable sharing from your primary built-in Wi-Fi interface (en0) connected to the internet, targeting your secondary USB Wi-Fi adapter (en1/en2) which broadcasts the SSID.",
                steps: [
                    "Plug in your external USB Wi-Fi adapter.",
                    "Select primary interface en0 and target en1 in Dashboard tab.",
                    "Click 'Start Hotspot' in the integrated controller.",
                    "Accept macOS administrative permission prompts to bind configuration."
                ]
            )
            SetupMethodCard(
                number: "2",
                title: "Wi-Fi to Bluetooth PAN",
                difficulty: "Zero hardware required, slower speeds",
                desc: "Tethers your Mac's internet connection over the built-in Bluetooth transceiver to deliver data to client phones/tablets.",
                steps: [
                    "Toggle Bluetooth PAN inside System Sharing pane.",
                    "Pair your phone/tablet to the Mac via Bluetooth.",
                    "Activate internet access over Bluetooth PAN on client."
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
                    Text("Systems Architect & Developer")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text("Developer of AirBridge Pro. Building high-performance, sandboxed, and bare-metal system tools designed to empower developers and network administrators on macOS.")
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
                Text("System Diagnostics & Environment")
                    .font(.headline)
                VStack(spacing: 1) {
                    TelemetryRow(title: "Active Developer", value: "Tiwut")
                    TelemetryRow(title: "Hostname", value: shell("hostname").trimmingCharacters(in: .whitespacesAndNewlines))
                    TelemetryRow(title: "macOS OS Version", value: shell("sw_vers -productVersion").trimmingCharacters(in: .whitespacesAndNewlines))
                    TelemetryRow(
                        title: "Swift Version",
                        value: shell("swift --version").components(separatedBy: .newlines).first?.replacingOccurrences(of: "Apple Swift version ", with: "").trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
                    )
                }
                .cornerRadius(10)
            }
        }
    }
    
    private func selectedTitle() -> String {
        switch selectedTab {
        case 0: return "AirBridge Dashboard"
        case 1: return "Client Management & Blocks"
        case 2: return "WLAN Diagnostic Telemetry"
        case 3: return "Integrated Port Forwarding"
        case 4: return "Bridge Fast DNS Options"
        case 5: return "Local Network Packet Sniffer"
        case 6: return "Bandwidth Speed Capper"
        case 7: return "Latency Quality Diagnostics"
        case 8: return "Bridge Setup Guide"
        default: return "About Developer Tiwut"
        }
    }
    
    private func selectedSubtitle() -> String {
        switch selectedTab {
        case 0: return "Real-time interface flow routing & Integrated controller."
        case 1: return "Dynamic IP Firewall block listing & Static DHCP reservations."
        case 2: return "Radio Signal strength metrics (RSSI), Channel, SNR, and Tx Link speeds."
        case 3: return "Direct external port redirections to local bridge devices."
        case 4: return "Override shared client DNS routing with zero ad AdGuard/Cloudflare tables."
        case 5: return "Packet sniffing utility capturing bridge socket headers."
        case 6: return "Set speed limits to manage overall data allocation."
        case 7: return "Interactive latency statistics and packet drop checks."
        case 8: return "Diagnostic information for repeater hardware."
        default: return "Developer background, links, and local system environment specs."
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
        displayNotification(message: "Copied \(type) \(text) to Clipboard.", success: true)
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
                    Text("SSID: \(ssid)").font(.caption).foregroundColor(.blue)
                } else {
                    Text(face.macAddress.uppercased()).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if face.isActive {
                Button(action: copyAction) {
                    HStack(spacing: 4) {
                        Text(face.ipAddress ?? "No IP").font(.system(.caption, design: .monospaced))
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
                Text("Inactive")
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
        window.title = "AirBridge Pro"
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
