import SwiftUI

/// A peak meter from -60 to 0 dBFS, colored by position like a hardware meter:
/// green below -12, yellow to -3, red in the top 3 dB. nil draws an empty meter.
struct MeterView: View {
    let dB: Double?
    var axis: Axis = .vertical

    private static let gradientStops: [Gradient.Stop] = [
        .init(color: Theme.green, location: 0), .init(color: Theme.green, location: 0.8),
        .init(color: Theme.yellow, location: 0.8), .init(color: Theme.yellow, location: 0.95),
        .init(color: Theme.red, location: 0.95), .init(color: Theme.red, location: 1),
    ]

    var body: some View {
        GeometryReader { g in
            let fraction = max(0, min(1, ((dB ?? -100) + 60) / 60))
            let vertical = axis == .vertical
            ZStack(alignment: vertical ? .bottom : .leading) {
                Theme.meterTrack
                LinearGradient(stops: Self.gradientStops,
                               startPoint: vertical ? .bottom : .leading, endPoint: vertical ? .top : .trailing)
                    .mask(alignment: vertical ? .bottom : .leading) {
                        Rectangle().frame(width: vertical ? nil : g.size.width * fraction,
                                          height: vertical ? g.size.height * fraction : nil)
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(width: axis == .vertical ? 6 : nil, height: axis == .vertical ? nil : 6)
        .accessibilityElement()
        .accessibilityLabel("Level")
        .accessibilityValue(dB.map { String(format: "%.0f dB", $0) } ?? "No signal")
    }
}

/// dB marks for a -60...0 meter, top to bottom.
struct MeterScale: View {
    private static let marks = [0, 6, 12, 18, 24, 30, 36, 48, 60]

    var body: some View {
        GeometryReader { g in
            ForEach(Self.marks, id: \.self) { m in
                Text(m == 0 ? "0" : "-\(m)")
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(Theme.tertiaryText)
                    .position(x: g.size.width / 2, y: min(max(g.size.height * Double(m) / 60, 5), g.size.height - 5))
            }
        }
        .frame(width: 20)
        .accessibilityHidden(true)
    }
}
