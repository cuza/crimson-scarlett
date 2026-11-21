import Foundation

/// What the device reports about its live setup. The 1st Gen firmware answers reads for these controls
/// only; it returns zeros for mix levels and routing. `matrix` comes from measuring the mixes instead.
public struct DeviceReadback: Equatable, Sendable {
    public var clock: ClockSource?
    public var instrument: [Int: Bool]
    public var pad: [Int: Bool]
    public var hiGain: [Int: Bool]
    /// Per output pair, the left channel's volume in dB.
    public var outputVolume: [Int]
    public var outputMuted: [Bool]
    public var mixerInputs: [Source]
    /// `matrix[input][mix]` in dB, when the mixes were measured.
    public var matrix: [[Int]]?
    /// The quietest mix gain, in dB, that Read from Device can measure with a margin. Quieter gains read
    /// as silent, so the two count as the same.
    public static let measurementFloor = -80

    public init(clock: ClockSource?, instrument: [Int: Bool], pad: [Int: Bool], hiGain: [Int: Bool],
                outputVolume: [Int], outputMuted: [Bool], mixerInputs: [Source], matrix: [[Int]]? = nil) {
        self.clock = clock
        self.instrument = instrument
        self.pad = pad
        self.hiGain = hiGain
        self.outputVolume = outputVolume
        self.outputMuted = outputMuted
        self.mixerInputs = mixerInputs
        self.matrix = matrix
    }

    /// A gain reply: little-endian Int16, dB × 256.
    public static func volume(_ b: [UInt8]) -> Int? {
        guard b.count >= 2 else { return nil }
        return Int((Double(Int16(bitPattern: UInt16(b[0]) | UInt16(b[1]) << 8)) / 256).rounded())
    }

    /// A switch reply. Only the first byte counts; mute replies carry noise in the second.
    public static func flag(_ b: [UInt8]) -> Bool? { b.first.map { $0 != 0 } }

    /// A mixer input source reply: one signed byte, -1 for Off.
    public static func source(_ b: [UInt8], model: DeviceModel) -> Source? {
        b.first.map { model.source(forValue: Int16(Int8(bitPattern: $0))) }
    }

    /// Measured mix levels (nil for silence) as whole-dB device gains.
    public static func matrix(fromMixLevels levels: [[Double?]]) -> [[Int]] {
        levels.map { row in row.map { $0.map { min(max(Int($0.rounded()), -128), 6) } ?? -128 } }
    }
}

extension Gen1Protocol {
    /// The read of the control a write sets, with the same entity and selector.
    public static func reading(_ write: ControlRequest, length: UInt16) -> ControlRequest {
        ControlRequest(requestType: `in`, request: write.request, value: write.value, index: write.index, data: [], length: length)
    }
}

extension ClockSource {
    public var name: String {
        switch self {
        case .internal: "Internal"
        case .spdif: "S/PDIF"
        case .adat: "ADAT"
        }
    }
}

extension MixerState {
    /// This setup with everything the device reported. Routing the device can't report stays as it is.
    /// Measured mixes replace the strips: a linked pair takes its left input's left side and its right
    /// input's right side, other strips take both sides of their input. Solo and strip mutes clear,
    /// since the device has no such state to read.
    public func adopting(_ r: DeviceReadback, model: DeviceModel) -> MixerState {
        var s = self
        if let c = r.clock { s.clock = c }
        s.instrument.merge(r.instrument) { $1 }
        s.pad.merge(r.pad) { $1 }
        s.hiGain.merge(r.hiGain) { $1 }
        for p in s.outputs.indices where p < r.outputVolume.count && p < r.outputMuted.count {
            s.outputs[p].volume = min(max(r.outputVolume[p], -128), 6)
            s.outputs[p].muted = r.outputMuted[p]
        }
        if r.mixerInputs.count == s.mixerInputs.count {
            let allowed = Set(model.mixerInputSources)
            s.mixerInputs = r.mixerInputs.map { allowed.contains($0) ? $0 : .off }
        }
        if let m = r.matrix, m.count == s.mixerInputs.count, m.allSatisfy({ $0.count == model.mixCount }) {
            s.solo = Array(repeating: nil, count: s.solo.count)
            for k in s.mixes.indices {
                var i = 0
                while i < m.count {
                    if s.linkedMixerInput(i) {
                        s.mixes[k][i] = Self.strip(left: m[i][2 * k], right: m[i + 1][2 * k + 1])
                        s.mixes[k][i + 1] = MixStrip()
                        i += 2
                    } else {
                        s.mixes[k][i] = Self.strip(left: m[i][2 * k], right: m[i][2 * k + 1])
                        i += 1
                    }
                }
            }
        }
        return s
    }

    /// Plain descriptions of where the device differs from this setup, empty when they agree.
    /// Measured mix levels may differ by 1 dB from rounding, and gains below the measurement floor read as silent.
    public func differences(from r: DeviceReadback, model: DeviceModel) -> [String] {
        func onOff(_ b: Bool) -> String { b ? "on" : "off" }
        var d: [String] = []
        if let c = r.clock, c != clock { d.append("Clock: device \(c.name), app \(clock.name)") }
        for n in model.impedanceInputs where r.instrument[n] != nil && r.instrument[n] != (instrument[n] ?? false) {
            d.append("Input \(n): device \(r.instrument[n]! ? "Inst" : "Line"), app \(instrument[n] ?? false ? "Inst" : "Line")")
        }
        for n in model.padInputs where r.pad[n] != nil && r.pad[n] != (pad[n] ?? false) {
            d.append("Input \(n) pad: device \(onOff(r.pad[n]!)), app \(onOff(pad[n] ?? false))")
        }
        for n in model.gainInputs where r.hiGain[n] != nil && r.hiGain[n] != (hiGain[n] ?? false) {
            d.append("Input \(n) hi gain: device \(onOff(r.hiGain[n]!)), app \(onOff(hiGain[n] ?? false))")
        }
        for p in outputs.indices where p < r.outputVolume.count && p < r.outputMuted.count {
            let o = outputs[p]
            if o.volume != r.outputVolume[p] || o.muted != r.outputMuted[p] {
                func describe(_ v: Int, _ m: Bool) -> String { "\(v) dB" + (m ? " muted" : "") }
                d.append("\(model.outputPairs[p]): device \(describe(r.outputVolume[p], r.outputMuted[p])), app \(describe(o.volume, o.muted))")
            }
        }
        let differing = zip(mixerInputs, r.mixerInputs).filter { $0 != $1 }.count
        if r.mixerInputs.count == mixerInputs.count, differing > 0 {
            d.append("Mixer inputs: \(differing) of \(mixerInputs.count) play something else on the device")
        }
        if let m = r.matrix, m.count == matrix.count {
            let floor = DeviceReadback.measurementFloor
            let off = zip(matrix.joined(), m.joined()).contains { abs(max($0, floor) - max($1, floor)) > 1 }
            if off { d.append("Mix levels differ") }
        }
        return d
    }
}
