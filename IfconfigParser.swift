import Foundation
import Darwin

struct IfconfigAddresses {
    var ips: [String: String] = [:]
    var macs: [String: String] = [:]
}

/// Parses `ifconfig` text into per-interface IPv4 and ethernet MAC maps.
func parseIfconfigOutput(_ output: String) -> IfconfigAddresses {
    var result = IfconfigAddresses()
    var currentInterface = ""
    for line in output.components(separatedBy: "\n") {
        if line.isEmpty { continue }
        if let firstWord = line.components(separatedBy: .whitespaces).first, firstWord.contains(":") {
            currentInterface = firstWord.replacingOccurrences(of: ":", with: "")
            continue
        }
        if currentInterface.isEmpty { continue }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("inet ") {
            let parts = trimmed.components(separatedBy: .whitespaces)
            if parts.count > 1 {
                result.ips[currentInterface] = parts[1]
            }
        } else if trimmed.hasPrefix("ether ") {
            result.macs[currentInterface] = trimmed
                .replacingOccurrences(of: "ether ", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return result
}

/// When the speedometer switches NIC (e.g. en0 → bridge100), byte counters are
/// not comparable — callers must zero lastIn/lastOut baselines.
func speedometerBaselineNeedsReset(previousInterface: String?, currentInterface: String) -> Bool {
    guard let previous = previousInterface, !previous.isEmpty else { return false }
    return previous != currentInterface
}

/// Parses `netstat -ib` link-row byte counters: (inBytes, outBytes).
func parseNetstatLinkBytes(_ output: String) -> (Double, Double)? {
    for line in output.components(separatedBy: .newlines) {
        if line.contains("<Link#") {
            let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count >= 10 {
                let inbound = Double(parts[6]) ?? 0.0
                let outbound = Double(parts[9]) ?? 0.0
                return (inbound, outbound)
            }
        }
    }
    return nil
}

/// Reads interface byte counters via getifaddrs (microseconds; no Process/netstat).
func interfaceByteCounters(named name: String) -> (Double, Double)? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(first) }
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let iface = ptr {
        if String(cString: iface.pointee.ifa_name) == name,
           let addr = iface.pointee.ifa_addr,
           addr.pointee.sa_family == UInt8(AF_LINK),
           let data = iface.pointee.ifa_data {
            let d = data.assumingMemoryBound(to: if_data.self).pointee
            return (Double(d.ifi_ibytes), Double(d.ifi_obytes))
        }
        ptr = iface.pointee.ifa_next
    }
    return nil
}
