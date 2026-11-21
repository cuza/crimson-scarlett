/// A signal the device can route. Channel numbers start at 1, except `mix`, where 0 is Mix A.
public enum Source: Hashable, Codable, Sendable {
    case off, pcm(Int), analog(Int), spdif(Int), adat(Int), mix(Int)

    public var name: String {
        switch self {
        case .off: "Off"
        case .pcm(let n): "PCM \(n)"
        case .analog(let n): "Analog \(n)"
        case .spdif(let n): "S/PDIF \(n)"
        case .adat(let n): "ADAT \(n)"
        case .mix(let n): (0..<26).contains(n) ? "Mix \(Character(UnicodeScalar(UInt8(65 + n))))" : "Mix \(n + 1)"
        }
    }
}
