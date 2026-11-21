import ScarlettKit
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Colors from the approved mockups. The app is dark only, like a hardware console.
enum Theme {
    static let window = Color(hex: 0x141416)
    static let card = Color(hex: 0x2A2A2E)
    static let cardBorder = Color(hex: 0x3A3A3F)
    static let strip = Color(hex: 0x232327)
    static let stripBorder = Color(hex: 0x34343A)
    static let stripHead = Color(hex: 0x1D1D21)
    static let master = Color(hex: 0x26262B)
    static let control = Color(hex: 0x2C2C30)
    static let controlBorder = Color(hex: 0x4A4A50)
    static let well = Color(hex: 0x1F1F23)
    static let selected = Color(hex: 0x5A5A61)
    static let meterTrack = Color(hex: 0x111113)
    static let secondaryText = Color(hex: 0xA1A1A6)
    static let tertiaryText = Color(hex: 0x8E8E93)
    static let green = Color(hex: 0x30D158)
    static let yellow = Color(hex: 0xFFD60A)
    static let red = Color(hex: 0xFF453A)
    static let orange = Color(hex: 0xFF9F0A)
    static let blue = Color(hex: 0x0A84FF)
    static let purple = Color(hex: 0xBF5AF2)
    static let analog = Color(hex: 0xFF9F0A)
    static let digital = Color(hex: 0x40C8E0)
    static let daw = Color(hex: 0x0A84FF)

    static func color(for source: Source) -> Color {
        switch source {
        case .analog: analog
        case .spdif, .adat: digital
        case .pcm: daw
        case .mix: purple
        case .off: tertiaryText
        }
    }
}

/// A rounded panel with a title, as in the mockups.
struct Card<Content: View, Label: View>: View {
    @ViewBuilder var content: Content
    @ViewBuilder var label: Label

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            label.font(.system(size: 15, weight: .semibold))
            content
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder))
    }
}
