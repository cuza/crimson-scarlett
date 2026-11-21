import ScarlettKit
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var app
    private var session: DeviceSession { app.session }
    private var model: DeviceModel { session.model }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Analog and digital inputs side by side, then outputs with the clock beside them.
                // Cards in a row share its height.
                HStack(alignment: .top, spacing: 16) {
                    inputs
                    digitalInputs
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    outputs
                    clock.frame(width: 300)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(Theme.window)
        .task(id: session.isConnected) { await app.pollMeters() }
    }

    private var clock: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Source", selection: binding(\.clock)) {
                    Text("Internal").tag(ClockSource.internal)
                    Text("S/PDIF").tag(ClockSource.spdif)
                    if session.model.adatCount > 0 || session.state.clock == .adat {
                        Text("ADAT").tag(ClockSource.adat)
                    }
                }
                .fixedSize()
                Label(syncText, systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(app.syncLocked == true ? .green : .secondary)
            }
            .padding(8)
        } label: { Text("Clock") }
    }

    private var syncText: String {
        switch app.syncLocked {
        case true?: "Locked"
        case false?: "No lock"
        case nil: "Unknown"
        }
    }

    /// Every input row is this tall, with or without a Line/Inst switch.
    private static let rowHeight: CGFloat = 26

    private var inputs: some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                ForEach(1...model.analogCount, id: \.self) { n in
                    GridRow {
                        Text(session.state.ports.names[.analog(n)] ?? "Input \(n)").frame(width: 90, alignment: .leading)
                        InputLevel(dB: app.meters?.level(of: .analog(n), model: model))
                        if model.impedanceInputs.contains(n) {
                            Picker("Input \(n) level", selection: binding(\.instrument[n], default: false)) {
                                Text("Line").tag(false)
                                Text("Inst").tag(true)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        } else {
                            Color.clear.frame(width: 1, height: 1)
                        }
                        if model.padInputs.contains(n) {
                            Toggle("Pad", isOn: binding(\.pad[n], default: false))
                        } else {
                            Color.clear.frame(width: 1, height: 1)
                        }
                        if model.gainInputs.contains(n) {
                            Toggle("Hi gain", isOn: binding(\.hiGain[n], default: false))
                        }
                    }
                    .frame(height: Self.rowHeight)
                }
            }
            .padding(8)
        } label: {
            HStack {
                Text("Analog inputs")
                Spacer()
                Text("Gain and 48V are on the front panel").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// S/PDIF always, ADAT ports once ADAT signal arrives or when not hidden.
    private var digitalPorts: [Source] {
        DeviceModel.channels(model.spdifCount).map(Source.spdif)
            + DeviceModel.channels(model.adatCount).map(Source.adat).filter { !app.isHidden($0) }
    }

    @ViewBuilder
    private var digitalInputs: some View {
        if !digitalPorts.isEmpty {
            Card {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 4) {
                    ForEach(digitalPorts, id: \.self) { port in
                        GridRow {
                            Text(session.state.displayName(port)).frame(width: 90, alignment: .leading)
                            InputLevel(dB: app.meters?.level(of: port, model: model))
                        }
                        .frame(height: Self.rowHeight)
                    }
                }
                .padding(8)
            } label: {
                HStack {
                    Text("Digital inputs")
                    Spacer()
                    let spdif = app.meters?.hasSignal(on: Source.spdif, model: model) ?? false
                    let detected = (spdif ? ["S/PDIF"] : []) + (app.adatDetected ? ["ADAT"] : [])
                    if !detected.isEmpty {
                        Label("Signal on " + detected.joined(separator: " and "), systemImage: "dot.radiowaves.left.and.right")
                            .font(.caption).foregroundStyle(Theme.digital)
                    }
                }
            }
        }
    }

    private var outputs: some View {
        Card {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                ForEach(Array(model.outputPairs.enumerated()), id: \.offset) { p, name in
                    GridRow {
                        Text(name)
                        SourcePairPicker(label: "\(name) source", model: model, ports: session.state.ports, isHidden: app.isHidden,
                                         selection: binding(\.outputs[p]))
                        Slider(value: volume(p), in: -128...6, step: 1) { Text("\(name) volume") }
                            .labelsHidden().frame(minWidth: 160)
                        Text("\(session.state.outputs[p].volume) dB").monospacedDigit().frame(width: 64, alignment: .trailing)
                        Toggle("Mute", isOn: binding(\.outputs[p].muted))
                    }
                }
            }
            .padding(8)
        } label: { Text("Outputs") }
    }

    // Bindings keep the session they were made for. Rows of the previous model can refresh once more
    // after a model switch, and reading the new model's shorter arrays would crash.
    private func volume(_ p: Int) -> Binding<Double> {
        let session = session
        return Binding(get: { Double(session.state.outputs[p].volume) },
                set: { v in session.update { $0.outputs[p].volume = Int(v.rounded()) } })
    }

    private func binding<T>(_ path: WritableKeyPath<MixerState, T>) -> Binding<T> {
        let session = session
        return Binding(get: { session.state[keyPath: path] },
                set: { v in session.update { $0[keyPath: path] = v } })
    }

    private func binding<T>(_ path: WritableKeyPath<MixerState, T?>, default d: T) -> Binding<T> {
        let session = session
        return Binding(get: { session.state[keyPath: path] ?? d },
                set: { v in session.update { $0[keyPath: path] = v } })
    }
}

/// Picks a consecutive pair of sources for a stereo output, such as PCM 1/2 or Mix A/B.
struct SourcePairPicker: View {
    let label: String
    let model: DeviceModel
    let ports: PortSettings
    /// The app's hiding rule, which shows ADAT ports again while an ADAT signal arrives.
    let isHidden: (Source) -> Bool
    @Binding var selection: OutputPair

    var body: some View {
        let current = Pair(left: selection.left, right: selection.right)
        let shown = Self.pairs(model).filter { $0 == current || !isHidden($0.left) }
        Picker(label, selection: Binding(
            get: { current },
            set: { selection.left = $0.left; selection.right = $0.right })) {
            ForEach(shown, id: \.self) { Text($0.name(ports)).tag($0) }
            if !shown.contains(current) { Text(current.name(ports)).tag(current) }
        }
        .labelsHidden().fixedSize()
    }

    struct Pair: Hashable {
        var left: Source, right: Source

        func name(_ ports: PortSettings) -> String {
            if left == .off && right == .off { return "Off" }
            if let custom = ports.names[left] { return custom }
            let r = right.name.split(separator: " ").last.map(String.init) ?? right.name
            return left.name + "/" + r
        }
    }

    /// Off, then each odd source with the one after it.
    static func pairs(_ model: DeviceModel) -> [Pair] {
        let s = Array(model.allSources.dropFirst())
        return [Pair(left: .off, right: .off)] + stride(from: 0, to: s.count - 1, by: 2).map { Pair(left: s[$0], right: s[$0 + 1]) }
    }
}

/// A horizontal meter with the level in dB next to it. Blank below -90 dB, where there is no signal.
struct InputLevel: View {
    let dB: Double?

    var body: some View {
        HStack(spacing: 10) {
            MeterView(dB: dB, axis: .horizontal).frame(width: 160)
            Text(dB.flatMap { $0 > -90 ? String(format: "%.0f dB", $0) : nil } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle((dB ?? -100) > -3 ? Theme.red : Theme.secondaryText)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
