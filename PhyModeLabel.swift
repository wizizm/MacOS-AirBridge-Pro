import Foundation

/// Maps CoreWLAN CWPHYMode raw values to display labels.
/// Uses rawValue so Wi-Fi 7 (802.11be) works even when the SDK lacks `.mode11be`.
func phyModeLabel(rawValue: Int) -> String {
    switch rawValue {
    case 1: return L10n.text(.phyMode80211a)
    case 2: return L10n.text(.phyMode80211b)
    case 3: return L10n.text(.phyMode80211g)
    case 4: return L10n.text(.phyMode80211n)
    case 5: return L10n.text(.phyMode80211ac)
    case 6: return L10n.text(.phyMode80211ax)
    case 7: return L10n.text(.phyMode80211be)
    default: return L10n.text(.phyModeMixed)
    }
}
