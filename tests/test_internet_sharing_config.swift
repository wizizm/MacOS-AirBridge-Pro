import Foundation

@main
struct InternetSharingConfigTests {
    static func main() {
        let cfg = buildNatShareConfiguration(
            enabled: true,
            primaryDevice: "en0",
            primaryReadable: "Wi-Fi",
            primaryService: "0E51679D-9BA7-4658-8CF5-113F9DF2B8C0",
            targetDevice: "en8"
        )
        expectTrue(cfg.enabled, "enabled")
        expectEqual(cfg.primary.device, "en0", "primary device")
        expectEqual(cfg.sharingDevices, ["en8"], "sharing devices modern schema")
        expectTrue(!cfg.sharingDevices.isEmpty, "not legacy SharingInterfaces")

        let off = buildNatShareConfiguration(
            enabled: false,
            primaryDevice: "en0",
            primaryReadable: "Wi-Fi",
            primaryService: "ABC",
            targetDevice: "en8"
        )
        expectTrue(off.sharingDevices.isEmpty, "disabled clears sharing devices")

        let ifconfig = """
        bridge100: flags=8863
        	inet 198.19.249.3 netmask 0xfffffe00
        	member: vmenet0 flags=10003
        bridge50: flags=8863
        	inet 192.168.2.1 netmask 0xffffff00
        	member: en8 flags=3
        en0: flags=8863
        	inet 10.0.0.2
        """
        expectTrue(isLikelyVirtualMachineBridge(interfaceName: "bridge100", ifconfigOutput: ifconfig), "orbstack bridge")
        expectTrue(!isLikelyVirtualMachineBridge(interfaceName: "bridge50", ifconfigOutput: ifconfig), "real sharing bridge")
        let selected = selectInternetSharingBridge(
            ipAddresses: ["bridge100": "198.19.249.3", "bridge50": "192.168.2.1", "en0": "10.0.0.2"],
            ifconfigOutput: ifconfig
        )
        expectEqual(selected?.name, "bridge50", "prefer real sharing bridge name")
        expectEqual(selected?.ip, "192.168.2.1", "prefer real sharing bridge IP")
        expectTrue(selectInternetSharingBridge(ipAddresses: ["bridge100": "198.19.249.3"], ifconfigOutput: ifconfig) == nil, "vm-only bridges → nil")

        expectTrue(isNatInternetSharingEnabled(enabledFlag: true, sharingDevices: ["en8"]), "nat on")
        expectTrue(!isNatInternetSharingEnabled(enabledFlag: true, sharingDevices: []), "enabled but no devices")
        expectTrue(!isNatInternetSharingEnabled(enabledFlag: false, sharingDevices: ["en8"]), "disabled")

        let plutilSample = """
        {
          "NAT" => {
            "Enabled" => 1
            "PrimaryInterface" => {
              "Device" => "en0"
              "Enabled" => 0
            }
            "SharingDevices" => [
              0 => "en8"
            ]
          }
        }
        """
        let parsed = parseNatSharingState(fromPlistText: plutilSample)
        expectTrue(parsed.enabled, "parse enabled")
        expectEqual(parsed.devices, ["en8"], "parse sharing devices")
        expectTrue(parseNatEnabledExtract("1\n"), "extract enabled 1")
        expectTrue(!parseNatEnabledExtract("0"), "extract enabled 0")
        expectEqual(parseNatSharingDevicesJSON("[\"en8\",\"en1\"]\n"), ["en8", "en1"], "extract devices json")

        let iface = parseScutilInterface(deviceNameFromShow: """
          DeviceName : en8
          Hardware : Ethernet
          UserDefinedName : iPhone USB
        """)
        expectEqual(iface?.device, "en8", "scutil device")
        expectEqual(iface?.readable, "iPhone USB", "scutil readable")

        let enableCmd = internetSharingEnableShell(
            primaryDevice: "en0",
            primaryReadable: "Wi-Fi",
            primaryService: "UUID",
            targetDevice: "en8"
        )
        expectTrue(enableCmd.contains("SharingDevices"), "enable uses SharingDevices")
        expectTrue(!enableCmd.contains("launchctl kickstart"), "SIP blocks kickstart — must not require it")
        expectTrue(enableCmd.contains("killall InternetSharing"), "enable best-effort reloads InternetSharing")
        expectTrue(!enableCmd.contains("InternetSharing.plist"), "no missing InternetSharing.plist")
        expectTrue(!enableCmd.contains("SharingInterfaces"), "no legacy SharingInterfaces")

        let disableCmd = internetSharingDisableShell()
        expectTrue(disableCmd.contains("Enabled -integer 0"), "disable clears Enabled")
        expectTrue(!disableCmd.contains("launchctl kickstart"), "disable must not use blocked kickstart")
        expectTrue(disableCmd.contains("killall InternetSharing"), "disable best-effort reloads InternetSharing")

        expectTrue(internetSharingSettingsURL().contains("Sharing-Settings"), "settings deep link")

        // 802.1X / Enterprise security (CWSecurity raw values)
        expectTrue(isEnterprise8021XSecurity(rawValue: 7), "WPA Enterprise")
        expectTrue(isEnterprise8021XSecurity(rawValue: 8), "WPA Enterprise Mixed")
        expectTrue(isEnterprise8021XSecurity(rawValue: 9), "WPA2 Enterprise")
        expectTrue(isEnterprise8021XSecurity(rawValue: 10), "Enterprise")
        expectTrue(isEnterprise8021XSecurity(rawValue: 12), "WPA3 Enterprise")
        expectTrue(!isEnterprise8021XSecurity(rawValue: 0), "None")
        expectTrue(!isEnterprise8021XSecurity(rawValue: 4), "WPA2 Personal")
        expectTrue(!isEnterprise8021XSecurity(rawValue: 11), "WPA3 Personal")

        expectTrue(isBypassInternetSharingActive(markerExists: true, targetHasShareIP: true), "bypass active")
        expectTrue(!isBypassInternetSharingActive(markerExists: true, targetHasShareIP: false), "marker alone insufficient")
        expectTrue(!isBypassInternetSharingActive(markerExists: false, targetHasShareIP: true), "IP alone insufficient")
        expectTrue(interfaceHasShareGatewayIP(ifconfigBlock: "inet 192.168.2.1 netmask 0xffffff00"), "detect share IP")
        expectTrue(!interfaceHasShareGatewayIP(ifconfigBlock: "inet 169.254.18.229 netmask 0xffff0000"), "link-local not share IP")
        let marker = parseAirbridgeShareMarker("{\"primary\":\"en0\",\"target\":\"en8\"}\n")
        expectEqual(marker?.primary, "en0", "marker primary")
        expectEqual(marker?.target, "en8", "marker target")
        expectTrue(parseAirbridgeShareMarker("not-json") == nil, "bad marker")

        let bypassOn = internetSharingBypassEnableShell(primaryDevice: "en0", targetDevice: "en8")
        expectTrue(bypassOn.contains("NAT.Enabled -integer 0"), "bypass disables Apple NAT")
        expectTrue(bypassOn.contains("SharingDevices -json '[]'"), "bypass clears SharingDevices")
        expectTrue(bypassOn.contains("killall InternetSharing"), "bypass kills InternetSharing")
        expectTrue(bypassOn.contains("net.inet.ip.forwarding=1"), "bypass enables forwarding")
        expectTrue(bypassOn.contains("ifconfig en8 inet 192.168.2.1 netmask 255.255.255.0"), "bypass assigns gateway on target")
        expectTrue(bypassOn.contains("/etc/pf.anchors/airbridge_share"), "bypass writes pf anchor file")
        expectTrue(bypassOn.contains("nat on en0"), "bypass NATs via primary")
        expectTrue(bypassOn.contains("192.168.2.0/24"), "bypass NAT subnet")
        // NAT must load into the already-active system nat-anchor — appending nat-anchor
        // after sangfor filter rules in pf.conf makes pfctl -f fail (rule order).
        expectTrue(bypassOn.contains("com.apple.internet-sharing"), "load NAT into active system nat-anchor")
        expectTrue(!bypassOn.contains("pfctl -f /etc/pf.conf"), "must not pfctl -f broken pf.conf")
        expectTrue(!bypassOn.contains("pfctl -f -"), "must not wipe pf via stdin")
        expectTrue(bypassOn.contains("AirBridge Pro") || bypassOn.contains("airbridge_share"), "strips broken pf.conf block")
        expectTrue(bypassOn.contains("/etc/bootpd.plist"), "bypass configures bootpd")
        expectTrue(bypassOn.contains("dhcp_enabled"), "bypass enables dhcp")
        expectTrue(bypassOn.contains("com.airbridge.bootpd"), "bypass uses LaunchDaemon label (survives AppleScript exit)")
        expectTrue(bypassOn.contains("/Library/LaunchDaemons/com.airbridge.bootpd.plist"), "bypass writes LaunchDaemon plist")
        expectTrue(bypassOn.contains("bootpd"), "bypass runs bootpd")
        expectTrue(bypassOn.contains("-D"), "bypass enables DHCP flag")
        expectTrue(bypassOn.contains("-d"), "bootpd -d stays foreground under launchd")
        expectTrue(bypassOn.contains("bootstrap system"), "bypass bootstraps LaunchDaemon")
        expectTrue(!bypassOn.contains("nohup"), "nohup dies when admin shell exits — must not use it")
        expectTrue(bypassOn.contains("/var/run/airbridge-share.json"), "bypass writes marker")
        expectTrue(!bypassOn.contains("Sharing-Settings"), "bypass does not open System Settings")

        let bypassOff = internetSharingBypassDisableShell(targetDevice: "en8")
        expectTrue(bypassOff.contains("rm -f /var/run/airbridge-share.json"), "disable removes marker")
        expectTrue(
            bypassOff.contains("cp /dev/null /etc/pf.anchors/airbridge_share")
                || bypassOff.contains("rm -f /etc/pf.anchors/airbridge_share"),
            "disable empties/removes pf anchor file so reload cannot revive NAT"
        )
        expectTrue(bypassOff.contains("com.apple.internet-sharing"), "disable flushes system nat-anchor rules")
        expectTrue(bypassOff.contains("dhcp_enabled"), "disable clears dhcp_enabled")
        expectTrue(bypassOff.contains("Subnets"), "disable clears bootpd Subnets")
        expectTrue(bypassOff.contains("bootout") || bypassOff.contains("com.airbridge.bootpd"), "disable stops LaunchDaemon")
        expectTrue(bypassOff.contains("192.168.2.1") || bypassOff.contains("delete"), "disable removes share IP")
        expectTrue(bypassOff.contains("net.inet.ip.forwarding=0"), "disable clears forwarding")

        let brokenPf = """
        anchor \"com.sangfor.atrust\"
        # AirBridge Pro 802.1X share bypass
        nat-anchor \"airbridge_share\"
        rdr-anchor \"airbridge_share\"
        anchor \"airbridge_share\"
        load anchor \"airbridge_share\" from \"/etc/pf.anchors/airbridge_share\"
        """
        let cleaned = stripAirbridgeShareFromPfConf(brokenPf)
        expectTrue(!cleaned.contains("airbridge_share"), "strip removes broken NAT-after-filter block")
        expectTrue(cleaned.contains("com.sangfor.atrust"), "strip keeps sangfor")

        // Prefer active USB/Link over inactive hardware "iPhone USB".
        let faces = [
            ShareTargetCandidate(device: "en9", type: "iPhone USB", isActive: false),
            ShareTargetCandidate(device: "en8", type: "USB/Link", isActive: true),
            ShareTargetCandidate(device: "en0", type: "Wi-Fi", isActive: true),
        ]
        expectEqual(selectDefaultShareTargetDevice(faces), "en8", "active USB/Link over inactive iPhone USB")

        expectTrue(isSafeBsdInterfaceName("en0"), "en0 safe")
        expectTrue(isSafeBsdInterfaceName("en12"), "en12 safe")
        expectTrue(isSafeBsdInterfaceName("bridge100"), "bridge safe")
        expectTrue(!isSafeBsdInterfaceName("en0;rm"), "reject shell meta")
        expectTrue(!isSafeBsdInterfaceName("../x"), "reject path")

        expectTrue(airbridgeSharePfAnchorRules(primaryDevice: "en0", targetDevice: "en8").contains("nat on en0"), "anchor is NAT")
        expectTrue(!airbridgeSharePfAnchorRules(primaryDevice: "en0", targetDevice: "en8").contains("pass "), "NAT-only file for system nat-anchor")

        print("All InternetSharingConfig tests passed.")
    }

    static func expectTrue(_ condition: Bool, _ label: String) {
        if !condition {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fputs("FAIL: \(label): got \(actual), expected \(expected)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }
}
