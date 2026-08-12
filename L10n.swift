import Foundation

enum AppLanguage: Equatable {
    case english
    case chinese

    /// Chinese if the first preferred language is any `zh*` variant; otherwise English.
    static func resolve(preferredLanguages: [String]) -> AppLanguage {
        guard let first = preferredLanguages.first?.lowercased() else { return .english }
        return first.hasPrefix("zh") ? .chinese : .english
    }

    static var current: AppLanguage {
        resolve(preferredLanguages: Locale.preferredLanguages)
    }
}

enum L10nKey: String, CaseIterable {
    // nav
    case appName
    case navDashboard
    case navDevicesAndBlock
    case navWlanTelemetry
    case navPortForwarding
    case navDnsAndAdBlock
    case navPacketSniffer
    case navBandwidthShaper
    case navBridgeQuality
    case navSetupGuide
    case navDeveloperInfo
    case formatSpeedKBps

    // headers
    case headerTitleDashboard
    case headerTitleClientManagement
    case headerTitleWlanTelemetry
    case headerTitlePortForwarding
    case headerTitleDns
    case headerTitleSniffer
    case headerTitleShaper
    case headerTitleQuality
    case headerTitleSetupGuide
    case headerTitleAboutDeveloper
    case headerSubtitleDashboard
    case headerSubtitleClientManagement
    case headerSubtitleWlanTelemetry
    case headerSubtitlePortForwarding
    case headerSubtitleDns
    case headerSubtitleSniffer
    case headerSubtitleShaper
    case headerSubtitleQuality
    case headerSubtitleSetupGuide
    case headerSubtitleDeveloper

    // dashboard
    case hotspotControllerTitle
    case sourceInterfaceLabel
    case hotspotOutgoingLabel
    case stopHotspot
    case startHotspot
    case connectionFlowTitle
    case topologySourceSsid
    case topologyMacBridge
    case topologyNoBridgeIp
    case formatTopologyDeviceCount
    case topologySharedHotspot
    case statDownloadSpeed
    case statUploadSpeed
    case statCumulativeData
    case formatDataMB
    case detectedHardwareInterfaces
    case clipboardItemIpAddress

    // devices
    case dhcpReservationTitle
    case placeholderMacAddress
    case placeholderDesiredIp
    case reserveLease
    case connectedClientsTable
    case noClientsOnBridge
    case dhcpReservedBadge
    case unblockDevice
    case blockClient
    case unknownDevice

    // telemetry
    case wifiDiagnosticsTitle
    case rssiSignal
    case noiseLevel
    case linkTxRate
    case formatRssiDbm
    case formatTxRateMbps
    case telemetryActiveSsid
    case telemetryBssid
    case telemetryRadioChannel
    case telemetryPhyStandard
    case telemetrySnr
    case formatSnrDb
    case phyMode80211a
    case phyMode80211b
    case phyMode80211g
    case phyMode80211n
    case phyMode80211ac
    case phyMode80211ax
    case phyMode80211be
    case phyModeMixed

    // forwarding
    case portForwardFormTitle
    case placeholderExtPort
    case placeholderClientIp
    case placeholderIntPort
    case addRule
    case activeRedirectAnchors
    case noPortForwardingRules
    case formatExternalPort

    // dns
    case dnsSectionTitle
    case dnsSectionDescription
    case dnsCardSystemDefaultsTitle
    case dnsCardSystemDefaultsDesc
    case dnsCardCloudflareTitle
    case dnsCardCloudflareDesc
    case dnsCardGoogleTitle
    case dnsCardGoogleDesc
    case dnsCardAdGuardTitle
    case dnsCardAdGuardDesc

    // sniffer
    case snifferTitle
    case snifferCapturing
    case snifferCapturePackets
    case snifferDescription
    case snifferConsoleEmpty

    // shaper
    case shaperTitle
    case shaperDescription
    case capSpeedRateLabel
    case shaperUnlimited
    case formatShaperSpeedMbps
    case shaperOptionUnlimitedDisable
    case shaperOption2MbpsSlow
    case shaperOption5MbpsStandard
    case shaperOption10MbpsFast

    // quality
    case qualityTitle
    case qualityPinging
    case qualityRunDiagnostic
    case qualityDescription
    case qualityLatencyRtt
    case formatLatencyMs
    case qualityDiagnosticIdle
    case qualityExcellentIdeal
    case qualityHighDelay
    case qualityPacketLossRate
    case formatPacketLossPercent
    case qualityPerfect
    case qualityDroppedPackets

    // setup
    case setupSectionTitle
    case setupMethod1Title
    case setupMethod1Difficulty
    case setupMethod1Desc
    case setupMethod1Step1
    case setupMethod1Step2
    case setupMethod1Step3
    case setupMethod1Step4
    case setupMethod2Title
    case setupMethod2Difficulty
    case setupMethod2Desc
    case setupMethod2Step1
    case setupMethod2Step2
    case setupMethod2Step3

    // developer
    case developerRole
    case developerBio
    case developerDiagnosticsTitle
    case developerActiveDeveloper
    case developerHostname
    case developerMacosVersion
    case developerSwiftVersion
    case developerSwiftVersionValue

    // status
    case repeaterActive
    case repeaterInactive
    case wlanNotConnected
    case wlanNotAssociated
    case wlanPhyUnknown
    case interfaceInactive
    case interfaceNoIp
    case formatSsidLabel
    case macUnknown
    case authorizationFailed

    // notifications
    case hotspotToggleSuccess
    case hotspotToggleError
    case hotspotConfiguredOpenSettings
    case hotspotBypass8021XSuccess
    case hotspotBypass8021XPolicyNote
    case hotspotMissingPrimaryService
    case hotspotVmConflictWarning
    case clientBlockedSuccess
    case firewallError
    case deviceUnblockedSuccess
    case dnsRevertedSuccess
    case dnsConfiguredSuccess
    case dnsOverrideError
    case redirectRuleSuccess
    case redirectApplyError
    case shaperDisabledSuccess
    case shaperLimitedSuccess
    case dummynetError
    case staticLeaseSuccess
    case dhcpConfigError
    case copiedToClipboard
}

struct L10n {
    var language: AppLanguage

    static var shared = L10n(language: .current)

    static func text(_ key: L10nKey) -> String {
        shared.string(key)
    }

    static func format(_ key: L10nKey, _ args: CVarArg...) -> String {
        shared.format(key, args)
    }

    func string(_ key: L10nKey) -> String {
        switch language {
        case .chinese: return Self.zh[key] ?? Self.en[key] ?? key.rawValue
        case .english: return Self.en[key] ?? key.rawValue
        }
    }

    func format(_ key: L10nKey, _ args: CVarArg...) -> String {
        format(key, Array(args))
    }

    func format(_ key: L10nKey, _ args: [CVarArg]) -> String {
        String(format: string(key), locale: Locale.current, arguments: args)
    }
}

// MARK: - English

extension L10n {
    private static let en: [L10nKey: String] = [
        .appName: "AirBridge Pro",
        .navDashboard: "Dashboard",
        .navDevicesAndBlock: "Devices & Block",
        .navWlanTelemetry: "WLAN Telemetry",
        .navPortForwarding: "Port Forwarding",
        .navDnsAndAdBlock: "DNS & AdBlock",
        .navPacketSniffer: "Packet Sniffer",
        .navBandwidthShaper: "Bandwidth Shaper",
        .navBridgeQuality: "Bridge Quality",
        .navSetupGuide: "Setup Guide",
        .navDeveloperInfo: "Developer Info",
        .formatSpeedKBps: "%.1f KB/s",

        .headerTitleDashboard: "AirBridge Dashboard",
        .headerTitleClientManagement: "Client Management & Blocks",
        .headerTitleWlanTelemetry: "WLAN Diagnostic Telemetry",
        .headerTitlePortForwarding: "Integrated Port Forwarding",
        .headerTitleDns: "Bridge Fast DNS Options",
        .headerTitleSniffer: "Local Network Packet Sniffer",
        .headerTitleShaper: "Bandwidth Speed Capper",
        .headerTitleQuality: "Latency Quality Diagnostics",
        .headerTitleSetupGuide: "Bridge Setup Guide",
        .headerTitleAboutDeveloper: "About Developer Tiwut",
        .headerSubtitleDashboard: "Real-time interface flow routing & Integrated controller.",
        .headerSubtitleClientManagement: "Dynamic IP Firewall block listing & Static DHCP reservations.",
        .headerSubtitleWlanTelemetry: "Radio Signal strength metrics (RSSI), Channel, SNR, and Tx Link speeds.",
        .headerSubtitlePortForwarding: "Direct external port redirections to local bridge devices.",
        .headerSubtitleDns: "Override shared client DNS routing with zero ad AdGuard/Cloudflare tables.",
        .headerSubtitleSniffer: "Packet sniffing utility capturing bridge socket headers.",
        .headerSubtitleShaper: "Set speed limits to manage overall data allocation.",
        .headerSubtitleQuality: "Interactive latency statistics and packet drop checks.",
        .headerSubtitleSetupGuide: "Diagnostic information for repeater hardware.",
        .headerSubtitleDeveloper: "Developer background, links, and local system environment specs.",

        .hotspotControllerTitle: "Integrated Hotspot Controller",
        .sourceInterfaceLabel: "Source Interface (Wi-Fi/Client)",
        .hotspotOutgoingLabel: "Hotspot Outgoing (AP)",
        .stopHotspot: "Stop Hotspot",
        .startHotspot: "Start Hotspot",
        .connectionFlowTitle: "Real-time Connection Flow",
        .topologySourceSsid: "Source SSID",
        .topologyMacBridge: "Mac Bridge",
        .topologyNoBridgeIp: "No Bridge IP",
        .formatTopologyDeviceCount: "%d Devices",
        .topologySharedHotspot: "Shared Hotspot",
        .statDownloadSpeed: "Download Speed",
        .statUploadSpeed: "Upload Speed",
        .statCumulativeData: "Cumulative Data",
        .formatDataMB: "%.1f MB",
        .detectedHardwareInterfaces: "Detected Hardware interfaces",
        .clipboardItemIpAddress: "IP Address",

        .dhcpReservationTitle: "Add Dynamic DHCP IP Reservation",
        .placeholderMacAddress: "MAC Address (e.g. 3c:13:d6:23:10:f5)",
        .placeholderDesiredIp: "Desired IP Address (e.g. 192.168.2.80)",
        .reserveLease: "Reserve Lease",
        .connectedClientsTable: "Connected Clients Table",
        .noClientsOnBridge: "No clients found on DHCP bridge network.",
        .dhcpReservedBadge: "DHCP Reserved",
        .unblockDevice: "Unblock Device",
        .blockClient: "Block Client",
        .unknownDevice: "Unknown Device",

        .wifiDiagnosticsTitle: "Detailed Wi-Fi Signal Diagnostics",
        .rssiSignal: "RSSI (Signal)",
        .noiseLevel: "Noise Level",
        .linkTxRate: "Link Tx Rate",
        .formatRssiDbm: "%d dBm",
        .formatTxRateMbps: "%.0f Mbps",
        .telemetryActiveSsid: "Active SSID",
        .telemetryBssid: "BSSID (Access Point)",
        .telemetryRadioChannel: "Radio Channel",
        .telemetryPhyStandard: "PHY Standard Mode",
        .telemetrySnr: "Signal-to-Noise Ratio (SNR)",
        .formatSnrDb: "%d dB",
        .phyMode80211a: "802.11a",
        .phyMode80211b: "802.11b",
        .phyMode80211g: "802.11g",
        .phyMode80211n: "802.11n",
        .phyMode80211ac: "802.11ac",
        .phyMode80211ax: "802.11ax (Wi-Fi 6)",
        .phyMode80211be: "802.11be (Wi-Fi 7)",
        .phyModeMixed: "802.11 Mixed",

        .portForwardFormTitle: "Load Redirect Rule into Packet Filter (PF)",
        .placeholderExtPort: "Ext Port (e.g. 8080)",
        .placeholderClientIp: "Client IP (e.g. 192.168.2.5)",
        .placeholderIntPort: "Int Port (e.g. 80)",
        .addRule: "Add Rule",
        .activeRedirectAnchors: "Active Redirect Anchors",
        .noPortForwardingRules: "No active port forwarding redirects loaded.",
        .formatExternalPort: "External Port: %@",

        .dnsSectionTitle: "Fast DNS Server Redirection",
        .dnsSectionDescription: "Force all shared clients to resolve domain names through specific servers. Toggling DNS values updates bootpd.plist on the fly.",
        .dnsCardSystemDefaultsTitle: "System Defaults",
        .dnsCardSystemDefaultsDesc: "Use the primary DNS server configured on your Mac's active interface.",
        .dnsCardCloudflareTitle: "Cloudflare Fast DNS",
        .dnsCardCloudflareDesc: "Configures 1.1.1.1 & 1.0.0.1 for high-speed browsing and extreme privacy.",
        .dnsCardGoogleTitle: "Google Public DNS",
        .dnsCardGoogleDesc: "Configures 8.8.8.8 & 8.8.4.4 for ultra-reliable global routing.",
        .dnsCardAdGuardTitle: "AdGuard Ad-Blocker DNS",
        .dnsCardAdGuardDesc: "Configures 94.140.14.14 & 94.140.15.15 to automatically drop ad domains and telemetry tracking.",

        .snifferTitle: "Live Packet Flow Terminal Capture (tcpdump)",
        .snifferCapturing: "Sniffing Live IP Packets...",
        .snifferCapturePackets: "Capture Packets",
        .snifferDescription: "Extracts active communication sockets from the active bridge interfaces. Safe, isolated sniffer automatically ends after 15 packet readings.",
        .snifferConsoleEmpty: "Terminal Console is empty. Press Capture Packets above.",

        .shaperTitle: "Bandwidth Throttler (Traffic Capper)",
        .shaperDescription: "Throttle the download and upload bandwidth on all shared AP networks to prevent clients from consuming all your system's network capacity.",
        .capSpeedRateLabel: "Cap Speed Rate:",
        .shaperUnlimited: "Unlimited",
        .formatShaperSpeedMbps: "%d Mbps",
        .shaperOptionUnlimitedDisable: "Unlimited (Disable)",
        .shaperOption2MbpsSlow: "2 Mbps (Slow)",
        .shaperOption5MbpsStandard: "5 Mbps (Standard)",
        .shaperOption10MbpsFast: "10 Mbps (Fast)",

        .qualityTitle: "Active Repeater Ping Quality Diagnostics",
        .qualityPinging: "Pinging Target...",
        .qualityRunDiagnostic: "Run Ping Diagnostic",
        .qualityDescription: "Pings high-reliability nodes (1.1.1.1) to measure real-time latency, connection quality, packet loss, and potential signal jitter added by the repeater bridge.",
        .qualityLatencyRtt: "Connection Latency (RTT)",
        .formatLatencyMs: "%.1f ms",
        .qualityDiagnosticIdle: "Diagnostic Idle",
        .qualityExcellentIdeal: "Excellent / Ideal",
        .qualityHighDelay: "High Delay",
        .qualityPacketLossRate: "Packet Loss Rate",
        .formatPacketLossPercent: "%.0f%%",
        .qualityPerfect: "Perfect Quality",
        .qualityDroppedPackets: "Dropped packets detected",

        .setupSectionTitle: "Repeater Bridge Hardware Combinations",
        .setupMethod1Title: "Wi-Fi to Wi-Fi Repeater (Dual Wireless Interface)",
        .setupMethod1Difficulty: "Requires USB Wi-Fi dongle",
        .setupMethod1Desc: "Enable sharing from your primary built-in Wi-Fi interface (en0) connected to the internet, targeting your secondary USB Wi-Fi adapter (en1/en2) which broadcasts the SSID.",
        .setupMethod1Step1: "Plug in your external USB Wi-Fi adapter.",
        .setupMethod1Step2: "Select primary interface en0 and target en1 in Dashboard tab.",
        .setupMethod1Step3: "Click 'Start Hotspot' in the integrated controller.",
        .setupMethod1Step4: "Accept macOS administrative permission prompts to bind configuration.",
        .setupMethod2Title: "Wi-Fi to Bluetooth PAN",
        .setupMethod2Difficulty: "Zero hardware required, slower speeds",
        .setupMethod2Desc: "Tethers your Mac's internet connection over the built-in Bluetooth transceiver to deliver data to client phones/tablets.",
        .setupMethod2Step1: "Toggle Bluetooth PAN inside System Sharing pane.",
        .setupMethod2Step2: "Pair your phone/tablet to the Mac via Bluetooth.",
        .setupMethod2Step3: "Activate internet access over Bluetooth PAN on client.",

        .developerRole: "Systems Architect & Developer",
        .developerBio: "Developer of AirBridge Pro. Building high-performance, sandboxed, and bare-metal system tools designed to empower developers and network administrators on macOS.",
        .developerDiagnosticsTitle: "System Diagnostics & Environment",
        .developerActiveDeveloper: "Active Developer",
        .developerHostname: "Hostname",
        .developerMacosVersion: "macOS OS Version",
        .developerSwiftVersion: "Swift Version",
        .developerSwiftVersionValue: "6.0 (bundled build)",

        .repeaterActive: "Repeater Active",
        .repeaterInactive: "Repeater Inactive",
        .wlanNotConnected: "Not Connected",
        .wlanNotAssociated: "Not Associated",
        .wlanPhyUnknown: "Unknown",
        .interfaceInactive: "Inactive",
        .interfaceNoIp: "No IP",
        .formatSsidLabel: "SSID: %@",
        .macUnknown: "Unknown",
        .authorizationFailed: "Authorization Failed",

        .hotspotToggleSuccess: "Hotspot toggled successfully.",
        .hotspotToggleError: "Error toggling hotspot: %@",
        .hotspotConfiguredOpenSettings: "NAT config written and NetworkSharing restarted. If the phone still has no route, open System Settings → General → Sharing, select Wi-Fi → iPhone USB, then enable Internet Sharing and confirm Start.",
        .hotspotBypass8021XSuccess: "Source Wi‑Fi is 802.1X/Enterprise — system Internet Sharing is blocked. AirBridge enabled a manual share (IP forward + pf NAT + DHCP) instead. Do not turn on System Settings → Sharing.",
        .hotspotBypass8021XPolicyNote: " Note: corporate policy may disallow re-sharing this network.",
        .hotspotMissingPrimaryService: "Could not resolve network service UUID for source interface %@.",
        .hotspotVmConflictWarning: " Note: OrbStack/VM bridges detected — virtual networking may conflict with Internet Sharing.",
        .clientBlockedSuccess: "Client %@ has been blocked on firewall.",
        .firewallError: "Firewall Error: %@",
        .deviceUnblockedSuccess: "Firewall rules flushed. Device is unblocked.",
        .dnsRevertedSuccess: "DNS settings reverted to System Defaults.",
        .dnsConfiguredSuccess: "Successfully configured shared bridge DNS to %@ (%@).",
        .dnsOverrideError: "Error overriding DNS: %@",
        .redirectRuleSuccess: "Redirect rule successfully loaded in Packet Filter (Port %@ ➡️ %@:%@).",
        .redirectApplyError: "Error applying Redirect: %@",
        .shaperDisabledSuccess: "Bandwidth shaper successfully disabled. Unlimited speed.",
        .shaperLimitedSuccess: "Successfully limited hotspot clients download bandwidth to %d Mbps.",
        .dummynetError: "Dummynet Error: %@",
        .staticLeaseSuccess: "Static lease configured inside /etc/bootpd.plist (MAC %@ ➡️ IP %@).",
        .dhcpConfigError: "DHCP Config Error: %@",
        .copiedToClipboard: "Copied %@ %@ to Clipboard.",
    ]
}

// MARK: - Simplified Chinese

extension L10n {
    private static let zh: [L10nKey: String] = [
        .appName: "AirBridge Pro",
        .navDashboard: "仪表盘",
        .navDevicesAndBlock: "设备与屏蔽",
        .navWlanTelemetry: "WLAN 遥测",
        .navPortForwarding: "端口转发",
        .navDnsAndAdBlock: "DNS 与广告拦截",
        .navPacketSniffer: "抓包终端",
        .navBandwidthShaper: "带宽限速",
        .navBridgeQuality: "桥接质量",
        .navSetupGuide: "设置指南",
        .navDeveloperInfo: "开发者信息",
        .formatSpeedKBps: "%.1f KB/s",

        .headerTitleDashboard: "AirBridge 仪表盘",
        .headerTitleClientManagement: "客户端管理与屏蔽",
        .headerTitleWlanTelemetry: "WLAN 诊断遥测",
        .headerTitlePortForwarding: "集成端口转发",
        .headerTitleDns: "桥接快速 DNS 选项",
        .headerTitleSniffer: "本地网络抓包",
        .headerTitleShaper: "带宽限速器",
        .headerTitleQuality: "延迟质量诊断",
        .headerTitleSetupGuide: "桥接设置指南",
        .headerTitleAboutDeveloper: "关于开发者 Tiwut",
        .headerSubtitleDashboard: "实时接口流量路由与集成控制器。",
        .headerSubtitleClientManagement: "动态 IP 防火墙屏蔽列表与静态 DHCP 预留。",
        .headerSubtitleWlanTelemetry: "无线信号强度（RSSI）、信道、SNR 与链路速率。",
        .headerSubtitlePortForwarding: "将外部端口直接转发到本地桥接设备。",
        .headerSubtitleDns: "覆盖共享客户端 DNS，支持 AdGuard / Cloudflare。",
        .headerSubtitleSniffer: "抓取桥接接口上的数据包头信息。",
        .headerSubtitleShaper: "设置速率上限以管理整体带宽占用。",
        .headerSubtitleQuality: "交互式延迟统计与丢包检测。",
        .headerSubtitleSetupGuide: "中继硬件组合与配置说明。",
        .headerSubtitleDeveloper: "开发者背景、链接与本机环境信息。",

        .hotspotControllerTitle: "集成热点控制器",
        .sourceInterfaceLabel: "源接口（Wi-Fi/客户端）",
        .hotspotOutgoingLabel: "热点出口（AP）",
        .stopHotspot: "停止热点",
        .startHotspot: "启动热点",
        .connectionFlowTitle: "实时连接拓扑",
        .topologySourceSsid: "源 SSID",
        .topologyMacBridge: "Mac 桥接",
        .topologyNoBridgeIp: "无桥接 IP",
        .formatTopologyDeviceCount: "%d 台设备",
        .topologySharedHotspot: "共享热点",
        .statDownloadSpeed: "下载速度",
        .statUploadSpeed: "上传速度",
        .statCumulativeData: "累计流量",
        .formatDataMB: "%.1f MB",
        .detectedHardwareInterfaces: "已检测到的硬件接口",
        .clipboardItemIpAddress: "IP 地址",

        .dhcpReservationTitle: "添加动态 DHCP IP 预留",
        .placeholderMacAddress: "MAC 地址（如 3c:13:d6:23:10:f5）",
        .placeholderDesiredIp: "目标 IP（如 192.168.2.80）",
        .reserveLease: "预留租约",
        .connectedClientsTable: "已连接客户端",
        .noClientsOnBridge: "DHCP 桥接网络上未发现客户端。",
        .dhcpReservedBadge: "DHCP 已预留",
        .unblockDevice: "解除屏蔽",
        .blockClient: "屏蔽客户端",
        .unknownDevice: "未知设备",

        .wifiDiagnosticsTitle: "详细 Wi-Fi 信号诊断",
        .rssiSignal: "RSSI（信号）",
        .noiseLevel: "噪声电平",
        .linkTxRate: "链路发送速率",
        .formatRssiDbm: "%d dBm",
        .formatTxRateMbps: "%.0f Mbps",
        .telemetryActiveSsid: "当前 SSID",
        .telemetryBssid: "BSSID（接入点）",
        .telemetryRadioChannel: "无线信道",
        .telemetryPhyStandard: "PHY 标准模式",
        .telemetrySnr: "信噪比（SNR）",
        .formatSnrDb: "%d dB",
        .phyMode80211a: "802.11a",
        .phyMode80211b: "802.11b",
        .phyMode80211g: "802.11g",
        .phyMode80211n: "802.11n",
        .phyMode80211ac: "802.11ac",
        .phyMode80211ax: "802.11ax（Wi-Fi 6）",
        .phyMode80211be: "802.11be（Wi-Fi 7）",
        .phyModeMixed: "802.11 混合",

        .portForwardFormTitle: "向数据包过滤器（PF）加载转发规则",
        .placeholderExtPort: "外部端口（如 8080）",
        .placeholderClientIp: "客户端 IP（如 192.168.2.5）",
        .placeholderIntPort: "内部端口（如 80）",
        .addRule: "添加规则",
        .activeRedirectAnchors: "活动转发规则",
        .noPortForwardingRules: "当前没有已加载的端口转发规则。",
        .formatExternalPort: "外部端口：%@",

        .dnsSectionTitle: "快速 DNS 服务器重定向",
        .dnsSectionDescription: "强制所有共享客户端通过指定 DNS 解析域名。切换会即时更新 bootpd.plist。",
        .dnsCardSystemDefaultsTitle: "系统默认",
        .dnsCardSystemDefaultsDesc: "使用 Mac 当前活动接口上配置的主 DNS 服务器。",
        .dnsCardCloudflareTitle: "Cloudflare 快速 DNS",
        .dnsCardCloudflareDesc: "配置 1.1.1.1 与 1.0.0.1，兼顾速度与隐私。",
        .dnsCardGoogleTitle: "Google 公共 DNS",
        .dnsCardGoogleDesc: "配置 8.8.8.8 与 8.8.4.4，提供稳定的全球解析。",
        .dnsCardAdGuardTitle: "AdGuard 广告拦截 DNS",
        .dnsCardAdGuardDesc: "配置 94.140.14.14 与 94.140.15.15，自动拦截广告与遥测域名。",

        .snifferTitle: "实时数据包流终端捕获（tcpdump）",
        .snifferCapturing: "正在抓取 IP 数据包…",
        .snifferCapturePackets: "开始抓包",
        .snifferDescription: "从活动桥接接口提取通信套接字。安全隔离，约 15 个数据包后自动结束。",
        .snifferConsoleEmpty: "终端控制台为空。请点击上方「开始抓包」。",

        .shaperTitle: "带宽限速（流量封顶）",
        .shaperDescription: "限制共享 AP 网络的上下行带宽，避免客户端占满本机网络容量。",
        .capSpeedRateLabel: "限速速率：",
        .shaperUnlimited: "不限速",
        .formatShaperSpeedMbps: "%d Mbps",
        .shaperOptionUnlimitedDisable: "不限速（关闭）",
        .shaperOption2MbpsSlow: "2 Mbps（慢）",
        .shaperOption5MbpsStandard: "5 Mbps（标准）",
        .shaperOption10MbpsFast: "10 Mbps（快）",

        .qualityTitle: "活动中继 Ping 质量诊断",
        .qualityPinging: "正在 Ping 目标…",
        .qualityRunDiagnostic: "运行 Ping 诊断",
        .qualityDescription: "向高可用节点（1.1.1.1）发送 Ping，测量延迟、连接质量、丢包，以及中继可能引入的抖动。",
        .qualityLatencyRtt: "连接延迟（RTT）",
        .formatLatencyMs: "%.1f ms",
        .qualityDiagnosticIdle: "诊断空闲",
        .qualityExcellentIdeal: "优秀 / 理想",
        .qualityHighDelay: "延迟较高",
        .qualityPacketLossRate: "丢包率",
        .formatPacketLossPercent: "%.0f%%",
        .qualityPerfect: "质量完美",
        .qualityDroppedPackets: "检测到丢包",

        .setupSectionTitle: "中继桥接硬件组合",
        .setupMethod1Title: "Wi-Fi 到 Wi-Fi 中继（双无线网卡）",
        .setupMethod1Difficulty: "需要 USB Wi-Fi 网卡",
        .setupMethod1Desc: "从已连网的主 Wi-Fi（en0）共享到副 USB Wi-Fi 适配器（en1/en2）进行广播。",
        .setupMethod1Step1: "插入外置 USB Wi-Fi 适配器。",
        .setupMethod1Step2: "在仪表盘选择主接口 en0 与目标 en1。",
        .setupMethod1Step3: "在集成控制器中点击「启动热点」。",
        .setupMethod1Step4: "在 macOS 管理员权限提示中批准配置绑定。",
        .setupMethod2Title: "Wi-Fi 到蓝牙 PAN",
        .setupMethod2Difficulty: "无需额外硬件，速度较慢",
        .setupMethod2Desc: "通过内置蓝牙将 Mac 的网络共享给手机/平板。",
        .setupMethod2Step1: "在系统「共享」面板中开启蓝牙 PAN。",
        .setupMethod2Step2: "将手机/平板通过蓝牙与 Mac 配对。",
        .setupMethod2Step3: "在客户端启用通过蓝牙 PAN 访问互联网。",

        .developerRole: "系统架构师与开发者",
        .developerBio: "AirBridge Pro 开发者。打造高性能、沙盒化、贴近系统层的 macOS 网络管理工具。",
        .developerDiagnosticsTitle: "系统诊断与环境",
        .developerActiveDeveloper: "当前开发者",
        .developerHostname: "主机名",
        .developerMacosVersion: "macOS 版本",
        .developerSwiftVersion: "Swift 版本",
        .developerSwiftVersionValue: "6.0（捆绑构建）",

        .repeaterActive: "中继已激活",
        .repeaterInactive: "中继未激活",
        .wlanNotConnected: "未连接",
        .wlanNotAssociated: "未关联",
        .wlanPhyUnknown: "未知",
        .interfaceInactive: "未激活",
        .interfaceNoIp: "无 IP",
        .formatSsidLabel: "SSID：%@",
        .macUnknown: "未知",
        .authorizationFailed: "授权失败",

        .hotspotToggleSuccess: "热点切换成功。",
        .hotspotToggleError: "切换热点失败：%@",
        .hotspotConfiguredOpenSettings: "已写入 NAT 配置并重启 NetworkSharing。若手机仍无法上网，请打开系统设置→通用→共享，选择将 Wi-Fi 共享到 iPhone USB，开启「互联网共享」并确认开始。",
        .hotspotBypass8021XSuccess: "当前 Wi‑Fi 为 802.1X/企业认证，系统「互联网共享」会被拒绝。已改用 AirBridge 自建共享（IP 转发 + pf NAT + DHCP）。请不要再打开系统设置里的共享开关。",
        .hotspotBypass8021XPolicyNote: " 注意：企业网络策略可能不允许再次共享该连接。",
        .hotspotMissingPrimaryService: "无法解析源接口 %@ 的网络服务 UUID。",
        .hotspotVmConflictWarning: " 注意：检测到 OrbStack/虚拟机网桥，可能与互联网共享冲突。",
        .clientBlockedSuccess: "客户端 %@ 已在防火墙上被屏蔽。",
        .firewallError: "防火墙错误：%@",
        .deviceUnblockedSuccess: "防火墙规则已清空。设备已解除屏蔽。",
        .dnsRevertedSuccess: "DNS 设置已恢复为系统默认。",
        .dnsConfiguredSuccess: "已将共享桥接 DNS 配置为 %@（%@）。",
        .dnsOverrideError: "覆盖 DNS 失败：%@",
        .redirectRuleSuccess: "转发规则已加载到数据包过滤器（端口 %@ ➡️ %@:%@）。",
        .redirectApplyError: "应用转发规则失败：%@",
        .shaperDisabledSuccess: "带宽限速已关闭。恢复不限速。",
        .shaperLimitedSuccess: "已将热点客户端下载带宽限制为 %d Mbps。",
        .dummynetError: "Dummynet 错误：%@",
        .staticLeaseSuccess: "已在 /etc/bootpd.plist 配置静态租约（MAC %@ ➡️ IP %@）。",
        .dhcpConfigError: "DHCP 配置错误：%@",
        .copiedToClipboard: "已将 %@ %@ 复制到剪贴板。",
    ]
}
