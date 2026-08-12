import Foundation
import CoreGraphics

/// Recenter when less than 25% of the window intersects the visible screen.
func shouldRecenterWindow(frame: CGRect, screenVisible: CGRect) -> Bool {
    let visible = frame.intersection(screenVisible)
    if visible.isNull || visible.isEmpty { return true }
    let area = frame.width * frame.height
    guard area > 0 else { return true }
    return (visible.width * visible.height) / area < 0.25
}

func airbridgeHelpURL() -> String {
    "https://github.com/wizizm/MacOS-AirBridge-Pro/issues"
}

func airbridgeReleasesURL() -> String {
    "https://github.com/wizizm/MacOS-AirBridge-Pro/releases"
}

func airbridgeLocalShortVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
}
