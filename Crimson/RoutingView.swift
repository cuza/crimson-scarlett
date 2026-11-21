import ScarlettKit
import SwiftUI

/// Each destination plays one source: as patch lines, or picked from menus in the list view.
struct RoutingView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("routingAsPatch") private var asPatch = true
    private var session: DeviceSession { app.session }
    private var model: DeviceModel { session.model }

    var body: some View {
        Group {
            if asPatch {
                PatchView().padding(16)
            } else {
                list
            }
        }
        .background(Theme.window)
    }

    private var list: some View {
        // Rows of the previous model can refresh once more after a switch; they must keep its session.
        let session = session
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Each destination plays one source. Pick it from the menu.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    RoutingModePicker()
                }
                HStack(alignment: .top, spacing: 18) {
                    column("Hardware outputs", "Stereo pairs") {
                        ForEach(Array(model.outputPairs.enumerated()), id: \.offset) { p, name in
                            row(name) {
                                SourcePairPicker(label: "\(name) source", model: model, ports: session.state.ports, isHidden: app.isHidden, selection: Binding(
                                    get: { session.state.outputs[p] },
                                    set: { v in session.update { $0.outputs[p] = v } }))
                            }
                        }
                    }
                    column("Recording channels", "What your DAW sees as inputs 1-\(model.captureCount)") {
                        ForEach(0..<model.captureCount, id: \.self) { i in
                            row("Mac input \(i + 1)") { picker("Mac input \(i + 1) source", \.capture[i], from: model.allSources) }
                        }
                    }
                    column("Mixer inputs", "Levels are on the Mixer screen") {
                        ForEach(0..<model.matrixInputs, id: \.self) { i in
                            row("Mixer in \(i + 1)") { picker("Mixer in \(i + 1) source", \.mixerInputs[i], from: model.mixerInputSources) }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.window)
    }

    private func column(_ title: String, _ subtitle: String, @ViewBuilder rows: () -> some View) -> some View {
        Card {
            VStack(spacing: 6) { rows() }.padding(8)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ name: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            Text(name)
            Spacer()
            control()
        }
    }

    /// A source menu with display names. Hidden ports are left out unless one is the current choice.
    private func picker(_ label: String, _ path: WritableKeyPath<MixerState, Source>, from options: [Source]) -> some View {
        let session = session
        let state = session.state
        let current = state[keyPath: path]
        let shown = options.filter { $0 == current || !app.isHidden($0) }
        return Picker(label, selection: Binding(get: { current },
                                                set: { v in session.update { $0[keyPath: path] = v } })) {
            ForEach(shown, id: \.self) { Text(state.displayName($0)).tag($0) }
            if !shown.contains(current) { Text(state.displayName(current)).tag(current) }
        }
        .labelsHidden().fixedSize()
    }
}

/// Switches the Routing screen between the patch bay and the list. Each mode shows it in its own top row.
struct RoutingModePicker: View {
    @AppStorage("routingAsPatch") private var asPatch = true

    var body: some View {
        Picker("View", selection: $asPatch) {
            Text("Patch").tag(true)
            Text("List").tag(false)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
    }
}
