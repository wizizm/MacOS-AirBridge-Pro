import Foundation

@main
struct IfconfigParserTests {
    static func main() {
        let sample = """
        lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
        	inet 127.0.0.1 netmask 0xff000000
        en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        	ether a1:b2:c3:d4:e5:f6
        	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
        en1: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        	ether 11:22:33:44:55:66
        """
        let parsed = parseIfconfigOutput(sample)
        expectEqual(parsed.ips["lo0"], "127.0.0.1", "lo0 ip")
        expectEqual(parsed.ips["en0"], "192.168.1.20", "en0 ip")
        expectEqual(parsed.macs["en0"], "a1:b2:c3:d4:e5:f6", "en0 mac")
        expectEqual(parsed.macs["en1"], "11:22:33:44:55:66", "en1 mac")
        if parsed.ips["en1"] != nil {
            fputs("FAIL: en1 should have no ipv4\n", stderr)
            exit(1)
        }
        print("PASS: en1 has no ipv4")

        let netstat = """
        Name  Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
        en0   1500  <Link#14>    a1.b2.c3.d4.e5.f6  100 0 123456789 200 0 987654321 0
        en0   1500  192.168.1/24 192.168.1.20       100 0 1 200 0 2 0
        """
        guard let bytes = parseNetstatLinkBytes(netstat) else {
            fputs("FAIL: expected netstat link bytes\n", stderr)
            exit(1)
        }
        expectEqual("\(Int(bytes.0))", "123456789", "netstat in bytes")
        expectEqual("\(Int(bytes.1))", "987654321", "netstat out bytes")

        // Speedometer must reset when netstat target NIC flips (en0 ↔ bridge100),
        // otherwise lastInBytes from the previous iface produce a huge false spike.
        expectTrue(!speedometerBaselineNeedsReset(previousInterface: Optional<String>.none, currentInterface: "en0"), "nil previous → no reset")
        expectTrue(!speedometerBaselineNeedsReset(previousInterface: "", currentInterface: "en0"), "empty previous → no reset")
        expectTrue(!speedometerBaselineNeedsReset(previousInterface: "en0", currentInterface: "en0"), "same iface → no reset")
        expectTrue(speedometerBaselineNeedsReset(previousInterface: "en0", currentInterface: "bridge100"), "en0→bridge100 → reset")
        expectTrue(speedometerBaselineNeedsReset(previousInterface: "bridge100", currentInterface: "en0"), "bridge100→en0 → reset")

        // Live getifaddrs path — en0 (or lo0) must resolve without spawning netstat.
        if let en0 = interfaceByteCounters(named: "en0") {
            expectTrue(en0.0 >= 0 && en0.1 >= 0, "getifaddrs en0 counters non-negative")
        } else if let lo0 = interfaceByteCounters(named: "lo0") {
            expectTrue(lo0.0 >= 0 && lo0.1 >= 0, "getifaddrs lo0 counters non-negative")
        } else {
            fputs("FAIL: getifaddrs returned nil for en0 and lo0\n", stderr)
            exit(1)
        }
        expectTrue(interfaceByteCounters(named: "airbridge-no-such-iface") == nil, "missing iface → nil")

        print("All ifconfig/netstat parser tests passed.")
    }

    static func expectTrue(_ condition: Bool, _ label: String) {
        if !condition {
            fputs("FAIL: \(label)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }

    static func expectEqual(_ actual: String?, _ expected: String, _ label: String) {
        if actual != expected {
            fputs("FAIL: \(label): got \(actual ?? "nil"), expected \(expected)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }
}
