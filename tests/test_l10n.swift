import Foundation

@main
struct L10nTests {
    static func main() {
        expectEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hans-CN"]), .chinese, "zh-Hans → chinese")
        expectEqual(AppLanguage.resolve(preferredLanguages: ["zh-Hant-TW"]), .chinese, "zh-Hant → chinese")
        expectEqual(AppLanguage.resolve(preferredLanguages: ["en-US"]), .english, "en → english")
        expectEqual(AppLanguage.resolve(preferredLanguages: ["ja-JP"]), .english, "ja → english fallback")
        expectEqual(AppLanguage.resolve(preferredLanguages: []), .english, "empty → english")

        let en = L10n(language: .english)
        let zh = L10n(language: .chinese)

        for key in L10nKey.allCases {
            let enValue = en.string(key)
            let zhValue = zh.string(key)
            if enValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fputs("FAIL: empty English for \(key)\n", stderr)
                exit(1)
            }
            if zhValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                fputs("FAIL: empty Chinese for \(key)\n", stderr)
                exit(1)
            }
        }
        print("PASS: all \(L10nKey.allCases.count) keys have en+zh")

        expectEqual(en.string(.navDashboard), "Dashboard", "en dashboard")
        expectEqual(zh.string(.navDashboard), "仪表盘", "zh dashboard")
        expectEqual(en.string(.startHotspot), "Start Hotspot", "en start hotspot")
        expectEqual(zh.string(.startHotspot), "启动热点", "zh start hotspot")
        expectEqual(en.string(.repeaterActive), "Repeater Active", "en repeater active")
        expectEqual(zh.string(.repeaterActive), "中继已激活", "zh repeater active")

        let formatted = zh.format(.formatTopologyDeviceCount, 3)
        expectEqual(formatted, "3 台设备", "zh device count format")

        print("All L10n tests passed.")
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        if actual != expected {
            fputs("FAIL: \(label): got \(actual), expected \(expected)\n", stderr)
            exit(1)
        }
        print("PASS: \(label)")
    }
}
