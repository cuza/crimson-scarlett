import ScarlettKit
import SwiftUI

/// Routing as patch lines, as on the approved mockup: sources on the left, destinations on the right.
/// Drag from a source onto a destination to connect it. Drag a line or a destination into empty space
/// to disconnect it, or onto another destination to move it. Click a line and press Delete to remove it.
///
/// Every row has a fixed height, so row and dot positions are computed, not measured. That keeps the
/// lines drawn on every appearance.
struct PatchView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("patchTab") private var tab = Tab.outputs
    @State private var drag: Drag?
    @State private var selected: Int?
    /// How far the sources are scrolled.
    @State private var scrollTop: CGFloat = 0

    enum Tab: String, CaseIterable { case outputs = "Hardware outputs", capture = "Recording channels", mixer = "Mixer inputs" }

    fileprivate struct Destination: Identifiable {
        let id: Int
        let group: String?
        let name: String
        let path: WritableKeyPath<MixerState, Source>
    }

    private struct Drag {
        var source: Source
        /// The destination whose connection is being moved or removed, if the drag started on one.
        var from: Int?
        var point: CGPoint
    }

    private enum Row { case title(String), source(Source), destination(Destination) }

    private static let pad: CGFloat = 18, titleHeight: CGFloat = 30, rowHeight: CGFloat = 22
    private static let sourceWidth: CGFloat = 230, destinationWidth: CGFloat = 330, dotInset: CGFloat = 12

    private var session: DeviceSession { app.session }
    private var model: DeviceModel { session.model }

    private var destinations: [Destination] {
        switch tab {
        case .outputs:
            model.outputPairs.enumerated().flatMap { p, name in
                [Destination(id: 2 * p, group: name, name: "\(name) L", path: \.outputs[p].left),
                 Destination(id: 2 * p + 1, group: nil, name: "\(name) R", path: \.outputs[p].right)]
            }
        case .capture:
            (0..<model.captureCount).map { Destination(id: $0, group: $0 == 0 ? "To the Mac" : nil, name: "Mac input \($0 + 1)", path: \.capture[$0]) }
        case .mixer:
            (0..<model.matrixInputs).map { Destination(id: $0, group: $0 == 0 ? "Mixer" : nil, name: "Mixer in \($0 + 1)", path: \.mixerInputs[$0]) }
        }
    }

    private var sourceRows: [Row] {
        let visible = { (s: [Source]) in s.filter { !app.isHidden($0) } }
        var groups: [(String, [Source])] = [
            ("From the Mac", DeviceModel.channels(model.pcmCount).map(Source.pcm)),
            ("Analog inputs", visible(DeviceModel.channels(model.analogCount).map(Source.analog))),
            ("S/PDIF in", visible(DeviceModel.channels(model.spdifCount).map(Source.spdif))),
            ("ADAT in", visible(DeviceModel.channels(model.adatCount).map(Source.adat))),
        ]
        if tab != .mixer { groups.append(("Mixes", (0..<model.mixCount).map(Source.mix))) }
        return groups.filter { !$0.1.isEmpty }.flatMap { [Row.title($0.0)] + $0.1.map(Row.source) }
    }

    private var destinationRows: [Row] {
        destinations.flatMap { d in (d.group.map { [Row.title($0)] } ?? []) + [Row.destination(d)] }
    }

    /// The top of each row, in content coordinates.
    private static func tops(_ rows: [Row]) -> [CGFloat] {
        var y = pad, out: [CGFloat] = []
        for r in rows {
            out.append(y)
            if case .title = r { y += titleHeight } else { y += rowHeight }
        }
        return out
    }

    private static func height(_ rows: [Row]) -> CGFloat {
        rows.reduce(pad * 2) { h, r in if case .title = r { h + titleHeight } else { h + rowHeight } }
    }

    /// Where the destination column starts, in content coordinates, so every source can reach every destination.
    /// If the destinations fit the panel, they stay in its vertical middle while the sources scroll.
    /// If not, they move through the panel in step with the scroll, so the last one shows when the scroll ends.
    static func destinationTop(scrollTop: CGFloat, view: CGFloat, sources: CGFloat, destinations: CGFloat) -> CGFloat {
        if destinations <= view { return scrollTop + (view - destinations) / 2 }
        let maxScroll = max(sources, destinations) - view
        guard maxScroll > 0 else { return 0 }
        let progress = min(max(scrollTop / maxScroll, 0), 1)
        return scrollTop - (destinations - view) * progress
    }

    // MARK: Geometry

    private struct Geometry {
        var sourceDot: [Source: CGPoint] = [:]
        var destinationDot: [Int: CGPoint] = [:]
        var sourceRow: [Source: CGRect] = [:]
        var destinationRow: [Int: CGRect] = [:]
    }

    /// `destinationTop` is where the destination column starts, in content coordinates.
    private func geometry(width: CGFloat, sources: [Row], targets: [Row], destinationTop: CGFloat) -> Geometry {
        var g = Geometry()
        let destX = width - Self.pad - Self.destinationWidth
        for (row, top) in zip(sources, Self.tops(sources)) {
            guard case .source(let s) = row else { continue }
            g.sourceRow[s] = CGRect(x: Self.pad, y: top, width: Self.sourceWidth, height: Self.rowHeight)
            g.sourceDot[s] = CGPoint(x: Self.pad + Self.sourceWidth - Self.dotInset, y: top + Self.rowHeight / 2)
        }
        for (row, rowTop) in zip(targets, Self.tops(targets)) {
            guard case .destination(let d) = row else { continue }
            let top = rowTop + destinationTop
            g.destinationRow[d.id] = CGRect(x: destX, y: top, width: Self.destinationWidth, height: Self.rowHeight)
            g.destinationDot[d.id] = CGPoint(x: destX + Self.dotInset, y: top + Self.rowHeight / 2)
        }
        return g
    }

    private func curve(_ a: CGPoint, _ b: CGPoint) -> Path {
        var p = Path()
        let dx = max(abs(b.x - a.x) * 0.45, 40)
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }

    /// The destination whose line passes within a few points of `point`.
    private func line(at point: CGPoint, in g: Geometry) -> Int? {
        destinations.first { d in
            let s = session.state[keyPath: d.path]
            guard s != .off, let a = g.sourceDot[s], let b = g.destinationDot[d.id] else { return false }
            return curve(a, b).strokedPath(StrokeStyle(lineWidth: 10, lineCap: .round)).contains(point)
        }?.id
    }

    // MARK: Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                HStack(spacing: 0) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Button(t.rawValue) { tab = t; selected = nil }.buttonStyle(TabButtonStyle(selected: t == tab))
                    }
                }
                .fixedSize()
                .padding(3)
                .background(Theme.well, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.cardBorder))
                if let id = selected, let d = destinations.first(where: { $0.id == id }) {
                    let s = session.state[keyPath: d.path]
                    Text("\(d.name) ← \(session.state.displayName(s))").font(.caption.weight(.semibold))
                    // A button, not a key listener: its Delete shortcut works without keyboard focus.
                    Button("Disconnect") { disconnect(id) }
                        .keyboardShortcut(.delete, modifiers: [])
                        .controlSize(.small)
                    Button("Done") { selected = nil }
                        .keyboardShortcut(.cancelAction)
                        .controlSize(.small)
                } else {
                    Text("Drag a source onto a destination. Drag a line away, or click it and press Delete, to disconnect.")
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                RoutingModePicker()
            }
            .frame(height: 34)
            GeometryReader { outer in
                let sources = sourceRows, targets = destinationRows
                let width = outer.size.width
                let destinationTop = Self.destinationTop(scrollTop: scrollTop, view: outer.size.height,
                                                         sources: Self.height(sources), destinations: Self.height(targets))
                let g = geometry(width: width, sources: sources, targets: targets, destinationTop: destinationTop)
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        lines(g)
                        column(sources).frame(width: Self.sourceWidth).offset(x: Self.pad)
                        column(targets).frame(width: Self.destinationWidth)
                            .offset(x: width - Self.pad - Self.destinationWidth, y: destinationTop)
                    }
                    .frame(width: width, height: max(Self.height(sources), Self.height(targets)), alignment: .topLeading)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("patchPanel")).minY } action: { scrollTop = -$0 }
                    .contentShape(Rectangle())
                    .gesture(dragGesture(g))
                    .simultaneousGesture(SpatialTapGesture().onEnded { v in
                        selected = line(at: v.location, in: g)
                    })
                }
            }
            .coordinateSpace(name: "patchPanel")
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.cardBorder))
        }
    }

    // MARK: Rows

    private func column(_ rows: [Row]) -> some View {
        let used = Set(destinations.map { session.state[keyPath: $0.path] })
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                switch row {
                case .title(let text):
                    Text(text)
                        .font(.system(size: 10, weight: .semibold)).textCase(.uppercase).tracking(0.5)
                        .foregroundStyle(Theme.secondaryText)
                        .frame(height: Self.titleHeight, alignment: .bottomLeading)
                case .source(let s):
                    sourceRow(s, used: used.contains(s))
                case .destination(let d):
                    destinationRow(d)
                }
            }
        }
        .padding(.top, Self.pad)
    }

    private func sourceRow(_ s: Source, used: Bool) -> some View {
        HStack {
            Text(session.state.displayName(s))
                .font(.system(size: 12, weight: used ? .semibold : .regular))
                .foregroundStyle(used ? Color.primary : Theme.secondaryText)
            Spacer()
            DotMark(filled: used, color: Theme.color(for: s))
        }
        .frame(height: Self.rowHeight)
        .help("Drag onto a destination to connect")
    }

    private func destinationRow(_ d: Destination) -> some View {
        let current = session.state[keyPath: d.path]
        return HStack(spacing: 8) {
            DotMark(filled: current != .off, color: Theme.color(for: current))
            Text(d.name).font(.system(size: 12, weight: current == .off ? .regular : .semibold))
            Spacer()
            Text(current == .off ? "Off" : session.state.displayName(current))
                .font(.system(size: 11)).foregroundStyle(Theme.tertiaryText)
        }
        .frame(height: Self.rowHeight)
        .contextMenu {
            Button("Disconnect") { disconnect(d.id) }.disabled(current == .off)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(d.name): \(current == .off ? "Off" : session.state.displayName(current))")
        .accessibilityAction(named: "Disconnect") { disconnect(d.id) }
    }

    // MARK: Lines

    private func lines(_ g: Geometry) -> some View {
        Canvas { context, _ in
            if let drag, let target = g.destinationRow.first(where: { $0.value.contains(drag.point) }) {
                context.fill(Path(roundedRect: target.value.insetBy(dx: -4, dy: 0), cornerRadius: 5),
                             with: .color(Theme.blue.opacity(0.25)))
            }
            for d in destinations where d.id != drag?.from {
                let s = session.state[keyPath: d.path]
                guard s != .off, let a = g.sourceDot[s], let b = g.destinationDot[d.id] else { continue }
                let isSelected = d.id == selected
                context.stroke(curve(a, b), with: .color(Theme.color(for: s).opacity(selected == nil || isSelected ? 1 : 0.55)),
                               lineWidth: isSelected ? 3.5 : 1.6)
            }
            if let drag, let a = g.sourceDot[drag.source] {
                context.stroke(curve(a, drag.point), with: .color(Theme.orange), style: StrokeStyle(lineWidth: 1.6, dash: [5, 4]))
                context.fill(Path(ellipseIn: CGRect(x: drag.point.x - 4, y: drag.point.y - 4, width: 8, height: 8)),
                             with: .color(Theme.orange))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Editing

    private func disconnect(_ id: Int) {
        guard let d = destinations.first(where: { $0.id == id }) else { return }
        session.update { $0[keyPath: d.path] = .off }
        if selected == id { selected = nil }
    }

    /// Starting on a source makes a new connection; starting on a connected destination or on a line
    /// picks that connection up, to move it or drop it in empty space.
    private func dragGesture(_ g: Geometry) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { v in
                if drag == nil {
                    if let s = g.sourceRow.first(where: { $0.value.contains(v.startLocation) })?.key {
                        drag = Drag(source: s, from: nil, point: v.location)
                    } else if let id = g.destinationRow.first(where: { $0.value.contains(v.startLocation) })?.key ?? line(at: v.startLocation, in: g),
                              let d = destinations.first(where: { $0.id == id }), session.state[keyPath: d.path] != .off {
                        drag = Drag(source: session.state[keyPath: d.path], from: id, point: v.location)
                    } else {
                        return
                    }
                }
                drag?.point = v.location
            }
            .onEnded { v in
                guard let current = drag else { return }
                drag = nil
                let target = g.destinationRow.first { $0.value.contains(v.location) }?.key
                let byID = Dictionary(uniqueKeysWithValues: destinations.map { ($0.id, $0.path) })
                if target == current.from { return }
                session.update { s in
                    if let from = current.from, let path = byID[from] { s[keyPath: path] = .off }
                    if let target, let path = byID[target] { s[keyPath: path] = current.source }
                }
                selected = nil
            }
    }
}

private struct DotMark: View {
    let filled: Bool
    let color: Color

    var body: some View {
        Circle()
            .fill(filled ? color : .clear)
            .overlay(Circle().strokeBorder(filled ? color : Theme.tertiaryText, lineWidth: 1.5))
            .frame(width: 10, height: 10)
            .frame(width: 24, height: Self.size)
    }

    private static let size: CGFloat = 22
}
