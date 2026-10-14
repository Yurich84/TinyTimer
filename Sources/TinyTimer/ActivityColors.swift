import AppKit
import SwiftUI
import TinyTimerCore

/// Colors of activities on the timeline and in statistics.
enum ActivityColors {
    /// "#RRGGBB" of every palette color.
    static let palette = ["#4C8DF6", "#F5A524", "#34C759", "#AF52DE", "#FF5A5F", "#14B8A6", "#C8A400", "#8E8E93"]

    /// The color of an activity without a chosen one: the three default activities get the first three
    /// palette colors, the others a color from a hash of the name. Stable across launches.
    static func defaultHex(for activity: Activity) -> String {
        switch activity {
        case .development: return palette[0]
        case .investigation: return palette[1]
        case .meeting: return palette[2]
        default: return palette[3 + Int(stableHash(activity.name) % UInt64(palette.count - 3))]
        }
    }

    /// FNV-1a. Swift's `hashValue` changes on every launch.
    static func stableHash(_ text: String) -> UInt64 {
        text.utf8.reduce(14695981039346656037) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    static func color(hex: String) -> Color? {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return Color(.sRGB, red: Double(value >> 16 & 0xFF) / 255, green: Double(value >> 8 & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255, opacity: 1)
    }

    static func hex(of color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        func byte(_ component: CGFloat) -> Int { Int((component * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(ns.redComponent), byte(ns.greenComponent), byte(ns.blueComponent))
    }
}
