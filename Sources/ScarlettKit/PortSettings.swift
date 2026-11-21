/// App-only settings for the device's ports: names, stereo links and hidden ports.
/// The device knows nothing of these. They travel with the state and with presets.
public struct PortSettings: Codable, Equatable, Sendable {
    /// Custom names. A port without one shows its own name.
    public var names: [Source: String]
    /// The left port of each linked pair, such as PCM 1 for PCM 1-2.
    public var linked: Set<Source>
    public var hidden: Set<Source>

    public init(names: [Source: String] = [:], linked: Set<Source> = [], hidden: Set<Source> = []) {
        self.names = names
        self.linked = linked
        self.hidden = hidden
    }

    /// PCM 1-2 and S/PDIF 1-2 linked, ADAT hidden. Right for every model; ports a model lacks are ignored.
    public static let standard = PortSettings(
        linked: [.pcm(1), .spdif(1)], hidden: Set(DeviceModel.channels(8).map(Source.adat)))

    /// The right port of a pair whose left port is `source`: odd-numbered PCM, Analog, S/PDIF or ADAT ports.
    public static func partner(of source: Source) -> Source? {
        switch source {
        case .pcm(let n) where n % 2 == 1: .pcm(n + 1)
        case .analog(let n) where n % 2 == 1: .analog(n + 1)
        case .spdif(let n) where n % 2 == 1: .spdif(n + 1)
        case .adat(let n) where n % 2 == 1: .adat(n + 1)
        default: nil
        }
    }
}
