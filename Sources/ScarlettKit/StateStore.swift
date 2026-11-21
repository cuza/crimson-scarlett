import Foundation

public enum StateStoreError: Error, Equatable {
    case unsupportedVersion(Int)
}

/// Reads and writes `MixerState` as JSON. Used for the app's own state and for presets.
public enum StateStore {
    private struct Version: Decodable { var formatVersion: Int }

    /// Format 1 (stage 1) stored the raw matrix instead of strips.
    private struct Format1: Decodable {
        var clock: ClockSource
        var instrument: [Int: Bool]
        var pad: [Int: Bool]
        var outputs: [OutputPair]
        var capture: [Source]
        var mixerInputs: [Source]
        var matrix: [[Int]]

        func converted() throws -> MixerState {
            let width = matrix.first?.count ?? 0
            guard width % 2 == 0, matrix.allSatisfy({ $0.count == width }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Matrix rows differ in length"))
            }
            let pairs = width / 2
            let mixes = (0..<pairs).map { k in matrix.map { row in MixerState.strip(left: row[2 * k], right: row[2 * k + 1]) } }
            var state = MixerState(clock: clock, instrument: instrument, pad: pad, outputs: outputs, capture: capture,
                                   mixerInputs: mixerInputs, mixes: mixes, solo: Array(repeating: nil, count: pairs))
            state.applyStandardPorts()
            return state
        }

    }

    public static func load(from url: URL) throws -> MixerState {
        let data = try Data(contentsOf: url)
        switch try JSONDecoder().decode(Version.self, from: data).formatVersion {
        case 1: return try JSONDecoder().decode(Format1.self, from: data).converted()
        case 2: return try JSONDecoder().decode(MixerState.self, from: data)
        case let v: throw StateStoreError.unsupportedVersion(v)
        }
    }

    public static func save(_ state: MixerState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
