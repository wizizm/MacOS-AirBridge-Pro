import Foundation
import CoreGraphics

@main
struct MenuBarSupportTests {
    static func main() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let onScreen = CGRect(x: 100, y: 100, width: 900, height: 640)
        expectTrue(!shouldRecenterWindow(frame: onScreen, screenVisible: screen), "fully visible → no recenter")

        let mostlyOff = CGRect(x: 1400, y: 800, width: 900, height: 640)
        expectTrue(shouldRecenterWindow(frame: mostlyOff, screenVisible: screen), "mostly off-screen → recenter")

        let tinyOverlap = CGRect(x: 1430, y: 880, width: 900, height: 640)
        expectTrue(shouldRecenterWindow(frame: tinyOverlap, screenVisible: screen), "tiny overlap → recenter")

        expectTrue(airbridgeHelpURL().contains("wizizm/MacOS-AirBridge-Pro/issues"), "help → Issues")
        expectTrue(airbridgeReleasesURL().contains("wizizm/MacOS-AirBridge-Pro/releases"), "updates → Releases")
        expectEqual(airbridgeLocalShortVersion().isEmpty, false, "local version non-empty")

        print("All MenuBarSupport tests passed.")
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
