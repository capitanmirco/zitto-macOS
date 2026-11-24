import AppKit
import SwiftUI
import ZittoCore

/// Colours of the window: the same as theme.py.
enum Theme {
    static let bg = hex("#14171c"), panel = hex("#1b1f26"), button = hex("#262c36"), hover = hex("#343c49")
    static let edge = hex("#2a303a"), text = hex("#e6e9ee"), dim = hex("#8a93a1"), accent = hex("#f5c451")
    static let bad = hex("#ff7a7a")
    // The waveform.
    static let grid = hex("#2a303a"), loopOn = hex("#3a3420"), loopOff = hex("#23272e"), muted = hex("#39404b")

    static func part(_ name: String) -> NSColor {
        hex(Parts.colors[name] ?? "#9fb0c3")
    }

    static func hex(_ text: String) -> NSColor {
        let value = UInt32(text.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

extension Color {
    static let zBg = Color(nsColor: Theme.bg), zPanel = Color(nsColor: Theme.panel)
    static let zButton = Color(nsColor: Theme.button), zHover = Color(nsColor: Theme.hover)
    static let zText = Color(nsColor: Theme.text), zDim = Color(nsColor: Theme.dim)
    static let zAccent = Color(nsColor: Theme.accent), zBad = Color(nsColor: Theme.bad)
    static let zEdge = Color(nsColor: Theme.edge)

    static func part(_ name: String) -> Color {
        Color(nsColor: Theme.part(name))
    }
}

/// The flat buttons of zitto.
struct FlatButtonStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundColor(active ? .zBg : .zText)
            .background(active ? Color.zAccent : configuration.isPressed ? Color.zHover : Color.zButton)
            .cornerRadius(3)
            .contentShape(Rectangle())
    }
}
