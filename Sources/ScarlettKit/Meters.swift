import Foundation

/// The meter reads the 1st Gen answers. wValue 4 and up stall the device, so this list is closed.
public enum MeterBank: UInt16, CaseIterable, Sendable {
    case inputs = 0, mixes = 1, pcm = 3
}

/// Peak levels in dBFS, floored at -100.
public struct MeterLevels: Equatable, Sendable {
    public var inputs: [Double]
    public var mixes: [Double]
    public var pcm: [Double]

    public init(inputs: [Double], mixes: [Double], pcm: [Double]) {
        self.inputs = inputs
        self.mixes = mixes
        self.pcm = pcm
    }

    /// Display ballistics: each meter jumps up to a louder reading at once and falls back at most
    /// `dBPerSecond`, so short peaks stay readable. Floored at -100.
    public func falling(toward read: MeterLevels, dBPerSecond: Double, seconds: Double) -> MeterLevels {
        func step(_ shown: [Double], _ new: [Double]) -> [Double]? {
            guard shown.count == new.count else { return nil }
            return zip(shown, new).map { max($1, max($0 - dBPerSecond * seconds, -100)) }
        }
        guard let i = step(inputs, read.inputs), let m = step(mixes, read.mixes), let p = step(pcm, read.pcm)
        else { return read }
        return MeterLevels(inputs: i, mixes: m, pcm: p)
    }

    /// True when any port of one kind, such as `.adat`, reads above exact digital zero. A connected device's
    /// noise floor counts; an unplugged port reads exactly zero. A device sending pure zeros can't be told apart.
    public func hasSignal(on kind: (Int) -> Source, model: DeviceModel) -> Bool {
        DeviceModel.channels(32).map(kind).contains { (level(of: $0, model: model) ?? -100) > -100 }
    }

    /// The meter that shows a source. Input meters run analog, then S/PDIF, then ADAT.
    public func level(of source: Source, model: DeviceModel) -> Double? {
        func at(_ a: [Double], _ i: Int) -> Double? { a.indices.contains(i) ? a[i] : nil }
        switch source {
        case .off: return nil
        case .analog(let n): return n <= model.analogCount ? at(inputs, n - 1) : nil
        case .spdif(let n): return n <= model.spdifCount ? at(inputs, model.analogCount + n - 1) : nil
        case .adat(let n): return n <= model.adatCount ? at(inputs, model.analogCount + model.spdifCount + n - 1) : nil
        case .pcm(let n): return at(pcm, n - 1)
        case .mix(let n): return at(mixes, n)
        }
    }

    /// Reads little-endian UInt16 peak values and converts them to dBFS.
    public static func decode(_ bytes: [UInt8], fullScale: Double) -> [Double] {
        stride(from: 0, to: bytes.count - 1, by: 2).map { i in
            let v = Double(UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            return v > 0 ? max(20 * log10(v / fullScale), -100) : -100
        }
    }
}

/// Keeps a signal "present" until it has been silent for `seconds`, so a quiet passage doesn't flicker it off.
public struct SignalHold: Sendable {
    public let seconds: TimeInterval
    private var lastHeard: Date?

    public init(seconds: TimeInterval) { self.seconds = seconds }

    /// Records whether signal is there now and returns whether it counts as present.
    public mutating func update(_ signal: Bool, at now: Date) -> Bool {
        if signal { lastHeard = now }
        guard let lastHeard else { return false }
        return now.timeIntervalSince(lastHeard) <= seconds
    }
}
