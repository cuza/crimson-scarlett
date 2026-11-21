/// What one Scarlett 1st Gen model has, and how its sources are numbered.
public struct DeviceModel: Sendable {
    public let productID: UInt16
    public let name: String
    public let pcmCount, analogCount, spdifCount, adatCount, mixCount: Int
    public let matrixInputs: Int
    public let captureCount: Int
    public let outputPairs: [String]
    public let impedanceInputs: [Int]
    public let padInputs: [Int]
    /// Inputs with a hi/lo gain switch (6i6).
    public let gainInputs: [Int]
    public var defaultMixerInputs: [Source]
    public let inputMeterCount, mixMeterCount, pcmMeterCount: Int
    /// The raw meter value that means 0 dBFS. On the 18i8 a peak of 0.5 reads 32768.
    public let meterFullScale: Double

    public func meterCount(_ bank: MeterBank) -> Int {
        switch bank {
        case .inputs: inputMeterCount
        case .mixes: mixMeterCount
        case .pcm: pcmMeterCount
        }
    }

    public var mixPairs: Int { mixCount / 2 }

    /// Off first, then PCM, Analog, S/PDIF, ADAT, Mix. Position minus one is the device value.
    public var allSources: [Source] {
        [.off]
            + mixerInputSources.dropFirst()
            + (0..<mixCount).map(Source.mix)
    }

    /// What a mixer input can play: Off and every source but the mixes.
    public var mixerInputSources: [Source] {
        [.off]
            + Self.channels(pcmCount).map(Source.pcm)
            + Self.channels(analogCount).map(Source.analog)
            + Self.channels(spdifCount).map(Source.spdif)
            + Self.channels(adatCount).map(Source.adat)
    }

    public func value(of source: Source) -> Int16 {
        Int16(allSources.firstIndex(of: source) ?? 0) - 1
    }

    /// Unknown values read as Off.
    public func source(forValue value: Int16) -> Source {
        let all = allSources
        let i = Int(value) + 1
        return all.indices.contains(i) ? all[i] : .off
    }

    /// Channel numbers 1...n, empty when n is 0.
    public static func channels(_ n: Int) -> [Int] { (0..<n).map { $0 + 1 } }

    /// Builds a model from the Linux driver's table facts. Meter counts beyond the 18i8 are unconfirmed.
    private static func make(_ productID: UInt16, _ name: String, pcm: Int, analog: Int, spdif: Int, adat: Int,
                             mixes: Int, capture: Int, outputs: [String], impedance: [Int] = [], pad: [Int] = [],
                             gain: [Int] = [], mixerInputs: [Int]) -> DeviceModel {
        var m = DeviceModel(
            productID: productID, name: name, pcmCount: pcm, analogCount: analog, spdifCount: spdif, adatCount: adat,
            mixCount: mixes, matrixInputs: 18, captureCount: capture, outputPairs: outputs,
            impedanceInputs: impedance, padInputs: pad, gainInputs: gain, defaultMixerInputs: [],
            inputMeterCount: capture, mixMeterCount: mixes, pcmMeterCount: min(pcm, 8), meterFullScale: 65536)
        m.defaultMixerInputs = mixerInputs.map { m.source(forValue: Int16($0)) }
        return m
    }

    public static let scarlett6i6 = make(
        0x8012, "Scarlett 6i6", pcm: 12, analog: 4, spdif: 2, adat: 0, mixes: 8, capture: 6,
        outputs: ["Monitor", "Headphones", "S/PDIF"], impedance: [1, 2], pad: [1, 2], gain: [3, 4],
        mixerInputs: [12, 13, 14, 15, 16, 17] + Array(0...11))

    public static let scarlett8i6 = make(
        0x8002, "Scarlett 8i6", pcm: 12, analog: 4, spdif: 2, adat: 0, mixes: 6, capture: 8,
        outputs: ["Monitor", "Headphones", "S/PDIF"], impedance: [1, 2], pad: [3, 4],
        mixerInputs: [12, 13, 14, 15, 16, 17] + Array(0...11))

    public static let scarlett18i6 = make(
        0x8004, "Scarlett 18i6", pcm: 6, analog: 8, spdif: 2, adat: 8, mixes: 6, capture: 18,
        outputs: ["Monitor", "Headphones", "S/PDIF"], impedance: [1, 2],
        mixerInputs: Array(6...13) + Array(16...21) + [14, 15, 0, 1])

    public static let scarlett18i8 = make(
        0x8014, "Scarlett 18i8", pcm: 8, analog: 8, spdif: 2, adat: 8, mixes: 8, capture: 18,
        outputs: ["Monitor", "Headphones 1", "Headphones 2", "S/PDIF"], impedance: [1, 2], pad: [1, 2, 3, 4],
        mixerInputs: Array(8...15) + Array(18...23) + [16, 17, 0, 1])

    public static let scarlett18i20 = make(
        0x800C, "Scarlett 18i20", pcm: 20, analog: 8, spdif: 2, adat: 8, mixes: 8, capture: 18,
        outputs: ["Monitor", "Line 3/4", "Line 5/6", "Line 7/8", "Line 9/10", "S/PDIF",
                  "ADAT 1/2", "ADAT 3/4", "ADAT 5/6", "ADAT 7/8"],
        mixerInputs: Array(20...27) + Array(30...35) + [28, 29, 0, 1])

    public static let all: [DeviceModel] = [.scarlett6i6, .scarlett8i6, .scarlett18i6, .scarlett18i8, .scarlett18i20]

    public static func model(productID: UInt16) -> DeviceModel? {
        all.first { $0.productID == productID }
    }
}
