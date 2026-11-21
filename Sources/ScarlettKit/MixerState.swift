import Foundation

/// One stereo hardware output. Volume and mute apply to both channels.
public struct OutputPair: Codable, Equatable, Sendable {
    public var left: Source
    public var right: Source
    public var volume: Int
    public var muted: Bool

    public init(left: Source, right: Source, volume: Int = 0, muted: Bool = false) {
        self.left = left
        self.right = right
        self.volume = volume
        self.muted = muted
    }
}

/// One mixer input in one stereo mix.
public struct MixStrip: Codable, Equatable, Sendable {
    /// Whole dB, -128 (silent) to 6.
    public var level: Int = -128
    /// -100 (left) to 100 (right).
    public var pan: Int = 0
    public var muted: Bool = false

    public init(level: Int = -128, pan: Int = 0, muted: Bool = false) {
        self.level = level
        self.pan = pan
        self.muted = muted
    }
}

/// Everything the app sets on the device. The device cannot report most of it, so this is the truth.
public struct MixerState: Codable, Equatable, Sendable {
    public var formatVersion: Int = 2
    public var clock: ClockSource
    /// Input number to instrument (true) or line (false).
    public var instrument: [Int: Bool]
    /// Input number to pad on.
    public var pad: [Int: Bool]
    /// Input number to hi gain on (6i6 inputs 3 and 4).
    public var hiGain: [Int: Bool] = [:]
    public var outputs: [OutputPair]
    public var capture: [Source]
    public var mixerInputs: [Source]
    /// `mixes[mixPair][mixerInput]`. Mix pair 0 is Mix A/B.
    public var mixes: [[MixStrip]]
    /// Per mix pair, the soloed mixer input. Every other input of that mix is silent.
    public var solo: [Int?]

    public var ports: PortSettings = .standard

    /// True when mixer inputs `i` and `i + 1` hold a linked pair (left, right). Strip `i` then drives both.
    public func linkedMixerInput(_ i: Int) -> Bool {
        i % 2 == 0 && i + 1 < mixerInputs.count && ports.linked.contains(mixerInputs[i])
            && PortSettings.partner(of: mixerInputs[i]) == mixerInputs[i + 1]
    }

    public func displayName(_ source: Source) -> String {
        let name = ports.names[source]?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? source.name : name
    }

    /// The strip that sends `left` dB to the left side and `right` dB to the right side:
    /// level is the louder side, pan (or balance) comes from the difference.
    public static func strip(left: Int, right: Int) -> MixStrip {
        let left = min(max(left, -128), 6), right = min(max(right, -128), 6)
        let hi = max(left, right), lo = min(left, right)
        guard hi > -128 else { return MixStrip() }
        let pan = Int(((1 - pow(10, Double(lo - hi) / 20)) * 100).rounded())
        return MixStrip(level: hi, pan: left >= right ? -pan : pan)
    }

    /// Mixer inputs that became a stereo strip since `old`, by a link or by a source change, keep what
    /// their two strips sent: the left strip's left side and the right strip's right side.
    public mutating func mergeNewlyLinkedPairs(from old: MixerState) {
        // A file from elsewhere can have arrays of any size. Leave it alone; `matches` rejects it later.
        let n = mixerInputs.count
        guard old.mixes.count == mixes.count, solo.count == mixes.count,
              (mixes + old.mixes).allSatisfy({ $0.count == n }) else { return }
        for i in stride(from: 0, to: mixerInputs.count - 1, by: 2) where linkedMixerInput(i) && !old.linkedMixerInput(i) {
            for k in mixes.indices {
                let a = old.mixes[k][i], b = old.mixes[k][i + 1]
                let l = Self.panGains(level: a.level, pan: a.pan).left
                let r = Self.panGains(level: b.level, pan: b.pan).right
                if a.muted && b.muted {
                    mixes[k][i] = Self.strip(left: l, right: r)
                    mixes[k][i].muted = true
                } else {
                    mixes[k][i] = Self.strip(left: a.muted ? -128 : l, right: b.muted ? -128 : r)
                }
                if solo[k] == i + 1 { solo[k] = i }
            }
        }
    }

    /// Links or unlinks a port pair. Unlinking turns each mix's pair strip into a hard-left and a
    /// hard-right strip with the same gains, so nothing sounds different.
    public mutating func setLinked(_ left: Source, _ on: Bool) {
        guard PortSettings.partner(of: left) != nil else { return }
        if on {
            let old = self
            ports.linked.insert(left)
            mergeNewlyLinkedPairs(from: old)
            return
        }
        for i in mixerInputs.indices where linkedMixerInput(i) && mixerInputs[i] == left {
            for k in mixes.indices {
                let s = mixes[k][i]
                let g = Self.panGains(level: s.level, pan: s.pan)
                mixes[k][i] = MixStrip(level: g.left, pan: -100, muted: s.muted)
                mixes[k][i + 1] = MixStrip(level: g.right, pan: 100, muted: s.muted)
            }
        }
        ports.linked.remove(left)
    }

    /// `matrix[input][mix]` in whole dB, as the device gets it.
    /// A linked pair sends its left input to the left side and its right input to the right side only.
    public var matrix: [[Int]] {
        let n = mixes.first?.count ?? 0
        var m = Array(repeating: Array(repeating: -128, count: mixes.count * 2), count: n)
        for k in mixes.indices {
            var i = 0
            while i < n {
                let linked = linkedMixerInput(i)
                let strip = mixes[k][i]
                let silenced = strip.muted || (solo[k] != nil && solo[k] != i && !(linked && solo[k] == i + 1))
                if !silenced {
                    let g = Self.panGains(level: strip.level, pan: strip.pan)
                    if linked {
                        m[i][2 * k] = g.left
                        m[i + 1][2 * k + 1] = g.right
                    } else {
                        m[i][2 * k] = g.left
                        m[i][2 * k + 1] = g.right
                    }
                }
                i += linked ? 2 : 1
            }
        }
        return m
    }

    /// Balance pan law: the side the strip pans away from drops by 20 log10((100 - |pan|) / 100) dB.
    public static func panGains(level: Int, pan: Int) -> (left: Int, right: Int) {
        guard level > -128 else { return (-128, -128) }
        let p = min(abs(pan), 100)
        let quiet = p == 100 ? -128 : max(level + Int((20 * log10(Double(100 - p) / 100)).rounded()), -128)
        return pan > 0 ? (quiet, level) : pan < 0 ? (level, quiet) : (level, level)
    }

    public mutating func copyMix(_ from: Int, to: Int) {
        mixes[to] = mixes[from]
        solo[to] = solo[from]
    }

    /// Output pair indices that play mix pair `k`.
    public func outputsPlaying(mixPair k: Int) -> [Int] {
        outputs.indices.filter { outputs[$0].left == .mix(2 * k) && outputs[$0].right == .mix(2 * k + 1) }
    }

    public static func defaults(for model: DeviceModel) -> MixerState {
        // Monitor plays PCM 1/2, S/PDIF the last PCM pair, every other output the next mix pair,
        // or PCM 1/2 once the mixes run out.
        let pairs: [OutputPair] = model.outputPairs.enumerated().map { p, name in
            if p == 0 { return OutputPair(left: .pcm(1), right: .pcm(2)) }
            if name == "S/PDIF" { return OutputPair(left: .pcm(model.pcmCount - 1), right: .pcm(model.pcmCount)) }
            if 2 * p <= model.mixCount { return OutputPair(left: .mix(2 * p - 2), right: .mix(2 * p - 1)) }
            return OutputPair(left: .pcm(1), right: .pcm(2))
        }
        let inputs = DeviceModel.channels(model.analogCount).map(Source.analog)
            + DeviceModel.channels(model.spdifCount).map(Source.spdif)
            + DeviceModel.channels(model.adatCount).map(Source.adat)
        let capture = inputs + Array(repeating: Source.off, count: max(model.captureCount - inputs.count, 0))
        // Every mix starts with the linked PCM 1-2 pair at 0 dB, centered, so headphones play the DAW.
        var strips = Array(repeating: MixStrip(), count: model.matrixInputs)
        if let l = model.defaultMixerInputs.firstIndex(of: .pcm(1)) { strips[l] = MixStrip(level: 0, pan: 0) }
        return MixerState(
            clock: .internal,
            instrument: Dictionary(uniqueKeysWithValues: model.impedanceInputs.map { ($0, false) }),
            pad: Dictionary(uniqueKeysWithValues: model.padInputs.map { ($0, false) }),
            hiGain: Dictionary(uniqueKeysWithValues: model.gainInputs.map { ($0, false) }),
            outputs: pairs,
            capture: Array(capture.prefix(model.captureCount)),
            mixerInputs: model.defaultMixerInputs,
            mixes: Array(repeating: strips, count: model.mixPairs),
            solo: Array(repeating: nil, count: model.mixPairs))
    }

    /// True when every array has the size the model needs and every value is one the device accepts.
    /// Files from elsewhere must pass this before use.
    public func matches(_ model: DeviceModel) -> Bool {
        let sources = Set(model.allSources)
        let gains = -128...6
        return outputs.count == model.outputPairs.count
            && capture.count == model.captureCount
            && mixerInputs.count == model.matrixInputs
            && mixes.count == model.mixPairs
            && mixes.allSatisfy { $0.count == model.matrixInputs }
            && mixes.joined().allSatisfy { gains.contains($0.level) && (-100...100).contains($0.pan) }
            && solo.count == model.mixPairs
            && solo.allSatisfy { $0 == nil || (0..<model.matrixInputs).contains($0!) }
            && outputs.allSatisfy { sources.contains($0.left) && sources.contains($0.right) && gains.contains($0.volume) }
            && capture.allSatisfy(sources.contains)
            && mixerInputs.allSatisfy(Set(model.mixerInputSources).contains)
    }

    /// Every write needed to put this state on the device. Never includes the sample rate.
    public func allRequests(for model: DeviceModel) -> [ControlRequest] {
        typealias P = Gen1Protocol
        var r = [P.masterVolume(dB: 0), P.masterMute(false), P.clock(clock)]
        r += model.impedanceInputs.map { P.impedance(input: $0, instrument: instrument[$0] ?? false) }
        r += model.padInputs.map { P.pad(input: $0, on: pad[$0] ?? false) }
        r += model.gainInputs.map { P.hiGain(input: $0, on: hiGain[$0] ?? false) }
        for (p, o) in outputs.enumerated() {
            r += [P.outputSource(pair: p, channel: 0, value: model.value(of: o.left)),
                  P.outputSource(pair: p, channel: 1, value: model.value(of: o.right))]
        }
        for (p, o) in outputs.enumerated() {
            r += (0...1).map { P.outputVolume(pair: p, channel: $0, dB: o.volume) }
        }
        for (p, o) in outputs.enumerated() {
            r += (0...1).map { P.outputMute(pair: p, channel: $0, muted: o.muted) }
        }
        r += capture.enumerated().map { P.captureSource(channel: $0, value: model.value(of: $1)) }
        r += mixerInputs.enumerated().map { P.mixerInputSource(input: $0, value: model.value(of: $1)) }
        for (i, row) in matrix.enumerated() {
            r += row.enumerated().map { P.matrixGain(input: i, mix: $0, dB: $1) }
        }
        return r
    }
}

extension MixerState {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, clock, instrument, pad, hiGain, outputs, capture, mixerInputs, mixes, solo, ports
    }

    /// Fields added after format 2 shipped are optional, so older files still load.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        clock = try c.decode(ClockSource.self, forKey: .clock)
        instrument = try c.decode([Int: Bool].self, forKey: .instrument)
        pad = try c.decode([Int: Bool].self, forKey: .pad)
        hiGain = try c.decodeIfPresent([Int: Bool].self, forKey: .hiGain) ?? [:]
        outputs = try c.decode([OutputPair].self, forKey: .outputs)
        capture = try c.decode([Source].self, forKey: .capture)
        mixerInputs = try c.decode([Source].self, forKey: .mixerInputs)
        mixes = try c.decode([[MixStrip]].self, forKey: .mixes)
        solo = try c.decode([Int?].self, forKey: .solo)
        if let ports = try c.decodeIfPresent(PortSettings.self, forKey: .ports) {
            self.ports = ports
        } else {
            applyStandardPorts()
        }
    }
}

extension MixerState {
    /// Gives a state from before port settings the standard ones, linking pairs so they sound the same.
    mutating func applyStandardPorts() {
        ports = PortSettings(hidden: PortSettings.standard.hidden)
        for left in PortSettings.standard.linked.sorted(by: { $0.name < $1.name }) { setLinked(left, true) }
    }
}
