public enum ClockSource: UInt8, Codable, CaseIterable, Sendable {
    case `internal` = 1, spdif = 2, adat = 3
}

/// Request encoding for Scarlett 1st Gen controls. All requests go to interface 0.
public enum Gen1Protocol {
    static let out: UInt8 = 0x21
    static let `in`: UInt8 = 0xA1
    static let cur: UInt8 = 0x01
    static let mem: UInt8 = 0x03

    static func entity(_ id: UInt8) -> UInt16 { UInt16(id) << 8 }

    static func int16Bytes(_ v: Int16) -> [UInt8] {
        let u = UInt16(bitPattern: v)
        return [UInt8(u & 0xFF), UInt8(u >> 8)]
    }

    static func write(_ entityID: UInt8, _ value: Int, _ data: [UInt8], request: UInt8 = cur) -> ControlRequest {
        ControlRequest(requestType: out, request: request, value: UInt16(value), index: entity(entityID),
                       data: data, length: UInt16(data.count))
    }

    /// Whole dB times 256 as little-endian Int16, clamped to -128...6 dB.
    public static func gainBytes(_ dB: Int) -> [UInt8] {
        int16Bytes(Int16(min(max(dB, -128), 6) * 256))
    }

    public static func impedance(input: Int, instrument: Bool) -> ControlRequest {
        write(0x01, 0x0900 + input, int16Bytes(instrument ? 1 : 0))
    }

    public static func pad(input: Int, on: Bool) -> ControlRequest {
        write(0x01, 0x0B00 + input, int16Bytes(on ? 1 : 0))
    }

    public static func hiGain(input: Int, on: Bool) -> ControlRequest {
        write(0x01, 0x0800 + input, int16Bytes(on ? 1 : 0))
    }

    public static func outputVolume(pair: Int, channel: Int, dB: Int) -> ControlRequest {
        write(0x0A, 0x0200 + 2 * pair + 1 + channel, gainBytes(dB))
    }

    public static func outputMute(pair: Int, channel: Int, muted: Bool) -> ControlRequest {
        write(0x0A, 0x0100 + 2 * pair + 1 + channel, int16Bytes(muted ? 1 : 0))
    }

    public static func masterVolume(dB: Int) -> ControlRequest { write(0x0A, 0x0200, gainBytes(dB)) }

    public static func masterMute(_ muted: Bool) -> ControlRequest { write(0x0A, 0x0100, int16Bytes(muted ? 1 : 0)) }

    public static func clock(_ source: ClockSource) -> ControlRequest { write(0x28, 0x0100, [source.rawValue]) }

    public static func outputSource(pair: Int, channel: Int, value: Int16) -> ControlRequest {
        write(0x33, 2 * pair + channel, int16Bytes(value))
    }

    public static func captureSource(channel: Int, value: Int16) -> ControlRequest {
        write(0x34, channel, int16Bytes(value))
    }

    public static func mixerInputSource(input: Int, value: Int16) -> ControlRequest {
        write(0x32, 0x0600 + input, int16Bytes(value))
    }

    public static func matrixGain(input: Int, mix: Int, dB: Int) -> ControlRequest {
        write(0x3C, (input << 3) + mix, gainBytes(dB))
    }

    /// Reads one byte: 1 when the clock is locked.
    public static func syncStatus() -> ControlRequest {
        ControlRequest(requestType: `in`, request: mem, value: 0x0002, index: entity(0x3C), data: [], length: 1)
    }

    /// False for a MEM read the device doesn't answer. wValue 4 and up stall the 18i8 until a power cycle.
    public static func isSafe(_ r: ControlRequest) -> Bool {
        !(r.isRead && r.request == mem && r.value > 3)
    }

    /// Reads one meter bank: `count` little-endian UInt16 peaks.
    public static func meters(_ bank: MeterBank, count: Int) -> ControlRequest {
        ControlRequest(requestType: `in`, request: mem, value: bank.rawValue, index: entity(0x3C), data: [],
                       length: UInt16(count * 2))
    }

    /// Stores the current settings in the device's flash memory.
    public static func saveToDevice() -> ControlRequest { write(0x3C, 0x005A, [0xA5], request: mem) }
}
