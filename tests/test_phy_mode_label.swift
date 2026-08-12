import Foundation

@main
struct PhyModeLabelTests {
    static func main() {
        L10n.shared = L10n(language: .english)
        expectEqual(phyModeLabel(rawValue: 1), "802.11a", "mode 11a")
        expectEqual(phyModeLabel(rawValue: 2), "802.11b", "mode 11b")
        expectEqual(phyModeLabel(rawValue: 3), "802.11g", "mode 11g")
        expectEqual(phyModeLabel(rawValue: 4), "802.11n", "mode 11n")
        expectEqual(phyModeLabel(rawValue: 5), "802.11ac", "mode 11ac")
        expectEqual(phyModeLabel(rawValue: 6), "802.11ax (Wi-Fi 6)", "mode 11ax")
        expectEqual(phyModeLabel(rawValue: 7), "802.11be (Wi-Fi 7)", "mode 11be via rawValue")
        expectEqual(phyModeLabel(rawValue: 99), "802.11 Mixed", "unknown mode")
        print("All phyModeLabel tests passed.")
    }

    static func expectEqual(_ actual: String, _ expected: String, _ label: String) {
        if actual != expected {
            fputs("FAIL: \(label): got \(actual), expected \(expected)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }
}
