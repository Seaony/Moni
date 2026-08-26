import AppKit
import SwiftUI

enum MoniPalette {
    static let panel = adaptive(light: rgb(0xF1F1F4), dark: rgb(0x0A0A0C))
    static let card = adaptive(light: rgb(0xFFFFFF), dark: rgb(0x17171A))
    static let cardHover = adaptive(light: rgb(0xF4F4F7), dark: rgb(0x1D1D21))
    static let inset = adaptive(light: rgb(0xF4F4F7), dark: rgb(0x101012))
    static let insetSecondary = adaptive(light: rgb(0xF7F7F9), dark: rgb(0x141416))
    static let selection = adaptive(light: rgb(0xE4EFFF), dark: rgb(0x1B2230))
    static let control = adaptive(light: rgb(0xEAEAEF), dark: rgb(0x1C1C1F))
    static let controlHover = adaptive(light: rgb(0xE0E0E6), dark: rgb(0x26262A))
    static let controlSelected = adaptive(light: rgb(0xD6D6DD), dark: rgb(0x3A3A3F))

    static let foreground = adaptive(light: rgb(0x16161A), dark: rgb(0xFFFFFF))
    static let foregroundSecondary = adaptive(
        light: rgb(0x000000, alpha: 0.62),
        dark: rgb(0xFFFFFF, alpha: 0.60)
    )
    static let foregroundTertiary = adaptive(
        light: rgb(0x000000, alpha: 0.45),
        dark: rgb(0xFFFFFF, alpha: 0.45)
    )
    static let foregroundQuaternary = adaptive(
        light: rgb(0x000000, alpha: 0.30),
        dark: rgb(0xFFFFFF, alpha: 0.35)
    )
    static let track = adaptive(
        light: rgb(0x000000, alpha: 0.10),
        dark: rgb(0xFFFFFF, alpha: 0.12)
    )
    static let line = adaptive(
        light: rgb(0x000000, alpha: 0.09),
        dark: rgb(0xFFFFFF, alpha: 0.05)
    )
    static let panelLine = adaptive(
        light: rgb(0x000000, alpha: 0.09),
        dark: rgb(0xFFFFFF, alpha: 0.09)
    )

    static let blue = Color(nsColor: rgb(0x0A84FF))
    static let pink = Color(nsColor: rgb(0xFF375F))
    static let cyan = Color(nsColor: rgb(0x32ADE6))
    static let orange = Color(nsColor: rgb(0xFF9F0A))
    static let purple = Color(nsColor: rgb(0xBF5AF0))
    static let indigo = Color(nsColor: rgb(0x5E5CE6))
    static let claude = Color(nsColor: rgb(0xD97757))
    static let red = Color(nsColor: rgb(0xFF453A))
    static let green = adaptive(light: rgb(0x1F9E46), dark: rgb(0x30D158))
    static let yellow = adaptive(light: rgb(0xB8860B), dark: rgb(0xFFD60A))

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}
