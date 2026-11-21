import ScarlettKit
import SwiftUI

/// Four stereo mixes. Each mixer input is one strip with pan, fader, meter, mute and solo.
struct MixerView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedMix = 0
    /// The shown mix, kept in range when a model with fewer mixes connects.
    private var mix: Int { min(selectedMix, max(model.mixPairs - 1, 0)) }
    private var session: DeviceSession { app.session }
    private var model: DeviceModel { session.model }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            playsOn
            // Faders take the height the window leaves; the console scrolls sideways when it is wider than the window.
            GeometryReader { g in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 4) {
                        ForEach(Array(stride(from: 0, to: session.state.mixerInputs.count, by: 2)), id: \.self) { pair($0, Self.faderHeight(g.size.height)) }
                        outputStrip(Self.faderHeight(g.size.height))
                    }
                    .fixedSize()
                    .frame(minWidth: g.size.width)
                }
            }
            Text("The \(model.name) mixes \(model.matrixInputs) inputs at a time. Click a strip's name to change what it plays, for example to bring in ADAT 7-8.")
                .font(.caption).foregroundStyle(Theme.tertiaryText)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(Theme.window)
        .task(id: session.isConnected) { await app.pollMeters() }
    }

    private var header: some View {
        HStack {
            Spacer().frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                ForEach(0..<model.mixPairs, id: \.self) { k in
                    Button(Self.mixName(k)) { selectedMix = k }
                        .buttonStyle(TabButtonStyle(selected: k == mix))
                        .accessibilityAddTraits(k == mix ? .isSelected : [])
                }
            }
            .fixedSize()
            .padding(3)
            .background(Theme.well, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.cardBorder))
            Menu {
                let hidden = model.allSources.filter { app.isHidden($0) }
                Menu("Show hidden") {
                    ForEach(hidden, id: \.self) { port in
                        Button(session.state.displayName(port)) { session.update { $0.ports.hidden.remove(port) } }
                    }
                    if !hidden.isEmpty {
                        Divider()
                        Button("Show all") { session.update { $0.ports.hidden.subtract(hidden) } }
                    }
                }
                .disabled(hidden.isEmpty)
                Menu("Copy mix to") {
                    ForEach(0..<model.mixPairs, id: \.self) { k in
                        if k != mix { Button(Self.mixName(k)) { session.update { $0.copyMix(mix, to: k) } } }
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Mix actions")
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var playsOn: some View {
        let names = session.state.outputsPlaying(mixPair: mix).map { model.outputPairs[$0] }
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("Plays on").foregroundStyle(Color(hex: 0xC7C7CC))
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(Theme.secondaryText)
                if names.isEmpty {
                    Text("Nothing yet").font(.caption).foregroundStyle(Theme.secondaryText)
                }
                ForEach(names, id: \.self) { Chip(text: $0) }
                Menu {
                    ForEach(Array(model.outputPairs.enumerated()), id: \.offset) { p, name in
                        Button(name) {
                            session.update { $0.outputs[p].left = .mix(2 * mix); $0.outputs[p].right = .mix(2 * mix + 1) }
                        }
                    }
                } label: {
                    Image(systemName: "pencil")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Change where this mix plays")
                Spacer()
            }
            .font(.system(size: 13))
            .frame(height: 28)   // same height with or without output chips, so the console doesn't move
            Rectangle().fill(Color(hex: 0x2E2E33)).frame(height: 1)
        }
    }

    /// A strip is its fader plus 147 pt of header, pan, level, buttons and name.
    static func faderHeight(_ available: CGFloat) -> CGFloat { max(160, available - 147) }

    static func mixName(_ k: Int) -> String {
        let a = Character(UnicodeScalar(UInt8(65 + 2 * k)))
        let b = Character(UnicodeScalar(UInt8(66 + 2 * k)))
        return "Mix \(a)/\(b)"
    }

    /// Hidden ports have no strip unless soloed.
    private func visible(_ i: Int) -> Bool {
        let state = session.state
        return i < state.mixerInputs.count && (!app.isHidden(state.mixerInputs[i]) || state.solo[mix] == i)
    }

    /// Mixer inputs `i` and `i + 1` share one panel: a single stereo strip when linked, else two strips.
    /// When they hold a port pair, a chain button on the seam links or unlinks them.
    @ViewBuilder
    private func pair(_ i: Int, _ fh: CGFloat) -> some View {
        let state = session.state
        let linked = state.linkedMixerInput(i)
        let a = visible(i), b = !linked && visible(i + 1)
        if a || b {
            HStack(spacing: 0) {
                if a { strip(i, fh) }
                if a && b { Rectangle().fill(Theme.stripBorder).frame(width: 1) }
                if b { strip(i + 1, fh) }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.strip)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stripBorder))
            .overlay(alignment: .top) {
                if let left = linkablePort(i), a && (linked || b) {
                    LinkButton(linked: linked, soloed: [i, i + 1].contains(state.solo[mix] ?? -1)) {
                        session.update { $0.setLinked(left, !linked) }
                    }
                    .offset(y: StripHeader.height - 11)
                }
            }
        }
    }

    /// The left port when inputs `i` and `i + 1` hold a port and its partner.
    private func linkablePort(_ i: Int) -> Source? {
        let inputs = session.state.mixerInputs
        guard i + 1 < inputs.count, PortSettings.partner(of: inputs[i]) == inputs[i + 1] else { return nil }
        return inputs[i]
    }

    private func strip(_ i: Int, _ fh: CGFloat) -> some View {
        let state = session.state
        let source = state.mixerInputs[i]
        let linked = state.linkedMixerInput(i)
        let s = state.mixes[mix][i]
        let soloed = state.solo[mix] == i
        let port = linked ? "\(source.name)-\(Self.channel(state.mixerInputs[i + 1]))" : source.name
        let custom = state.ports.names[source]
        return VStack(spacing: 0) {
            Menu {
                sourceChoices(i, linked: linked)
            } label: {
                StripHeader(title: port, color: Theme.color(for: source), pickable: true)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Pick what this strip plays")
            VStack(spacing: 1) {
                PanControl(pan: Binding(get: { s.pan }, set: { v in session.update { $0.mixes[mix][i].pan = v } }),
                           label: "\(source.name) \(linked ? "balance" : "pan")")
                    .frame(width: 52, height: 14)
                Text(Self.panText(s.pan))
                    .font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.tertiaryText)
            }
            .padding(.top, 14)
            .help(linked ? "Balance" : "Pan")
            HStack(alignment: .top, spacing: 3) {
                Fader(level: Binding(get: { s.level }, set: { v in session.update { $0.mixes[mix][i].level = v } }),
                      label: "\(source.name) level")
                LiveMeter(dB: app.meters?.level(of: source, model: model))
                if linked { LiveMeter(dB: app.meters?.level(of: state.mixerInputs[i + 1], model: model)) }
            }
            .padding(.vertical, 6)
            .frame(height: fh)
            Text(Self.gainText(s.level))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(s.level > -128 ? .primary : Theme.tertiaryText)
            HStack(spacing: 4) {
                StripButton(title: "M", isOn: s.muted, onColor: Theme.orange, onText: Color(hex: 0x1C1C1E),
                            help: "Mute \(source.name) in this mix") { session.update { $0.mixes[mix][i].muted.toggle() } }
                StripButton(title: "S", isOn: soloed, onColor: Theme.blue, onText: .white,
                            help: "Hear only \(source.name) in this mix. The app mutes the other inputs of this mix.") {
                    session.update { $0.solo[mix] = soloed ? nil : i }
                }
            }
            .padding(.top, 6)
            TextField("Name", text: Binding(get: { custom ?? "" },
                                            set: { v in session.update { $0.ports.names[source] = v.isEmpty ? nil : v } }))
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 11, weight: custom == nil ? .regular : .semibold))
                .lineLimit(1)
                .padding(.vertical, 4).padding(.horizontal, 4)
                .background(Theme.stripHead, in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 5).padding(.vertical, 6)
                .accessibilityLabel("Name for \(port)")
                .help("Name this strip")
        }
        .frame(width: linked ? 88 : 62)
        .contextMenu {
            Button(linked ? "Hide \(port)" : "Hide \(source.name)") {
                session.update { s in
                    s.ports.hidden.insert(source)
                    if linked { s.ports.hidden.insert(state.mixerInputs[i + 1]) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(source.name)
    }

    /// What a strip can play: single ports, or port pairs for a stereo strip. Hidden ports are left out.
    @ViewBuilder
    private func sourceChoices(_ i: Int, linked: Bool) -> some View {
        let state = session.state
        let ports = model.mixerInputSources.dropFirst().filter { !app.isHidden($0) || $0 == state.mixerInputs[i] }
        if linked {
            ForEach(ports.filter { PortSettings.partner(of: $0) != nil }, id: \.self) { left in
                let right = PortSettings.partner(of: left)!
                Button("\(left.name)-\(Self.channel(right))") {
                    session.update { s in
                        s.mixerInputs[i] = left
                        s.mixerInputs[i + 1] = right
                        s.ports.linked.insert(left)
                    }
                }
            }
        } else {
            Button("Off") { session.update { $0.mixerInputs[i] = .off } }
            ForEach(Array(ports), id: \.self) { p in
                Button(state.displayName(p)) { session.update { $0.mixerInputs[i] = p } }
            }
        }
    }

    private func outputStrip(_ fh: CGFloat) -> some View {
        VStack(spacing: 0) {
            StripHeader(title: Self.mixName(mix), color: Theme.purple)
            HStack(alignment: .top, spacing: 4) {
                HStack(spacing: 3) {
                    LiveMeter(dB: app.meters?.level(of: .mix(2 * mix), model: model))
                    LiveMeter(dB: app.meters?.level(of: .mix(2 * mix + 1), model: model))
                }
                MeterScale().padding(.top, 16)
            }
            .padding(.vertical, 6)
            .frame(height: fh)
            .padding(.top, 41)   // level with the input strips' meters, below their pan controls
            Text("L    R").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.secondaryText)
            Text("Output").font(.system(size: 10)).foregroundStyle(Theme.tertiaryText).padding(.top, 2)
            Spacer(minLength: 0)
        }
        .frame(width: 70)
        .frame(maxHeight: .infinity)   // as tall as the input strips
        .background(Theme.master)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.controlBorder))
    }

    /// The channel number of a port, such as 2 for PCM 2.
    static func channel(_ s: Source) -> Int {
        switch s {
        case .pcm(let n), .analog(let n), .spdif(let n), .adat(let n): n
        case .mix(let n): n + 1
        case .off: 0
        }
    }

    static func gainText(_ dB: Int) -> String { dB <= -128 ? "-∞" : dB > 0 ? "+\(dB) dB" : "\(dB) dB" }

    static func panText(_ pan: Int) -> String { pan == 0 ? "C" : pan < 0 ? "L\(-pan)" : "R\(pan)" }
}

private struct StripHeader: View {
    static let height: CGFloat = 32
    let title: String
    let color: Color
    var pickable = false

    var body: some View {
        HStack(spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
            if pickable {
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.tertiaryText)
            }
        }
            .frame(maxWidth: .infinity)
            .frame(height: Self.height)
            .padding(.horizontal, 4)
            .background(Theme.stripHead)
            .overlay(alignment: .bottom) { color.frame(height: 3) }
    }
}

private struct StripButton: View {
    let title: String
    let isOn: Bool
    let onColor: Color
    let onText: Color
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? onText : Color(hex: 0xC7C7CC))
                .frame(width: 25, height: 24)
                .background(isOn ? onColor : Theme.control, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(isOn ? onColor : Theme.controlBorder))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Theme.control, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
    }
}

struct TabButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? .white : Color(hex: 0xC7C7CC))
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(selected ? Theme.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A vertical fader from -60 to +6 dB. The bottom step is silent (-128).
/// Dragging moves the level by how far the pointer moves, so grabbing it never makes it jump.
/// Double-click sets 0 dB.
struct Fader: View {
    @Binding var level: Int
    let label: String
    @State private var dragStart: Double?

    private static let top = 6.0, bottom = -61.0
    private static let marks = [6, 0, -10, -20, -30, -40, -50, -61]

    /// Levels between -127 and -62 (from Read from Device or a preset) sit at the bottom; the text below shows them.
    private var position: Double { max(Double(level), Self.bottom) }

    private func set(_ dB: Double) {
        let v = min(max(dB.rounded(), Self.bottom), Self.top)
        level = v <= Self.bottom ? -128 : Int(v)
    }

    var body: some View {
        GeometryReader { g in
            let travel = g.size.height - 34
            let y = 17 + travel * (1 - (position - Self.bottom) / (Self.top - Self.bottom))
            let unity = 17 + travel * (1 - (0 - Self.bottom) / (Self.top - Self.bottom))
            let trackX = g.size.width - 14
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(Theme.meterTrack).frame(width: 4).position(x: trackX, y: g.size.height / 2)
                    .frame(height: g.size.height)
                ForEach(Self.marks, id: \.self) { m in
                    let my = 17 + travel * (1 - (Double(m) - Self.bottom) / (Self.top - Self.bottom))
                    Text(m == -61 ? "∞" : m > 0 ? "+\(m)" : "\(m)")
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(m == 0 ? Color(hex: 0xC7C7CC) : Theme.tertiaryText)
                        .position(x: 10, y: my)
                    Rectangle().fill(Theme.stripBorder).frame(width: 6, height: 1).position(x: trackX - 8, y: my)
                }
                Rectangle().fill(Theme.tertiaryText).frame(width: 12, height: 1).position(x: trackX, y: unity)
                FaderCap().position(x: trackX, y: y)
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard v.translation.height != 0 || dragStart != nil else { return }   // a click alone changes nothing
                    let start = dragStart ?? position
                    dragStart = start
                    set(start - v.translation.height / travel * (Self.top - Self.bottom))
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { level = 0 })
        }
        .frame(width: 44)
        .help("Drag to set the level. Double-click for 0 dB.")
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(MixerView.gainText(level))
        .accessibilityAdjustableAction { direction in
            set(position + (direction == .increment ? 1 : -1))
        }
    }
}

/// A meter with its live peak in dB above it.
private struct LiveMeter: View {
    let dB: Double?

    var body: some View {
        VStack(spacing: 4) {
            Text(text)
                .font(.system(size: 8, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .frame(width: 16, height: 12)
                .accessibilityHidden(true)
            MeterView(dB: dB)
        }
    }

    private var text: String {
        guard let dB, dB > -60 else { return "" }
        return String(format: "%.0f", dB)
    }

    private var color: Color {
        switch dB ?? -100 {
        case ..<(-12): Theme.tertiaryText
        case ..<(-3): Theme.yellow
        default: Theme.red
        }
    }
}

/// A console fader cap: light grey with a center line.
private struct FaderCap: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(LinearGradient(colors: [Color(hex: 0xE5E5EA), Color(hex: 0xAEAEB2)], startPoint: .top, endPoint: .bottom))
            .overlay(Rectangle().fill(Color(hex: 0x1C1C1E)).frame(height: 2))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.black.opacity(0.4)))
            .frame(width: 24, height: 34)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

/// The chain button on the seam of a port pair, as in Focusrite's MixControl.
private struct LinkButton: View {
    let linked: Bool
    let soloed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "link")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(linked ? .white : Theme.secondaryText)
                .frame(width: 30, height: 20)
                .background(linked ? Theme.blue : Theme.control, in: Capsule())
                .overlay(Capsule().strokeBorder(linked ? Theme.blue : Theme.controlBorder))
                .opacity(soloed ? 0.4 : 1)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(soloed)
        .help(soloed ? "Turn off solo first" : linked ? "Split into two mono strips" : "Link as one stereo strip")
        .accessibilityLabel(linked ? "Unlink stereo pair" : "Link as stereo pair")
    }
}

/// Pan or balance: a track with a center tick, filled from the center toward the knob.
/// Dragging moves it by the drag distance; double-click centers it. Snaps to center near zero.
struct PanControl: View {
    @Binding var pan: Int
    let label: String
    @State private var dragStart: Int?

    private func set(_ v: Double) {
        let r = Int(v.rounded())
        pan = abs(r) <= 3 ? 0 : min(max(r, -100), 100)
    }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, mid = w / 2, y = g.size.height / 2
            let x = mid + CGFloat(pan) / 100 * (mid - 5)
            ZStack {
                Capsule().fill(Theme.meterTrack).frame(height: 3).position(x: mid, y: y)
                Rectangle().fill(Color(hex: 0xC7C7CC))
                    .frame(width: abs(x - mid), height: 3)
                    .position(x: (x + mid) / 2, y: y)
                Rectangle().fill(Theme.tertiaryText).frame(width: 1, height: 8).position(x: mid, y: y)
                Circle().fill(Color(hex: 0xE5E5EA)).frame(width: 9, height: 9)
                    .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
                    .position(x: x, y: y)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard v.translation.width != 0 || dragStart != nil else { return }
                    let start = dragStart ?? pan
                    dragStart = start
                    set(Double(start) + v.translation.width / (w - 10) * 200)
                }
                .onEnded { _ in dragStart = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { pan = 0 })
        }
        .help("Drag left or right. Double-click to center.")
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(MixerView.panText(pan))
        .accessibilityAdjustableAction { set(Double(pan) + ($0 == .increment ? 5 : -5)) }
    }
}
