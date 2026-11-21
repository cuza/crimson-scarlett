import Testing
@testable import ScarlettKit

@Test func gainEncoding() {
    #expect(Gen1Protocol.gainBytes(0) == [0x00, 0x00])
    #expect(Gen1Protocol.gainBytes(-6) == [0x00, 0xFA])
    #expect(Gen1Protocol.gainBytes(-128) == [0x00, 0x80])
    #expect(Gen1Protocol.gainBytes(6) == [0x00, 0x06])
    #expect(Gen1Protocol.gainBytes(-200) == [0x00, 0x80])
    #expect(Gen1Protocol.gainBytes(20) == [0x00, 0x06])
}

@Test func padInput3On() {
    #expect(Gen1Protocol.pad(input: 3, on: true) ==
        ControlRequest(requestType: 0x21, request: 0x01, value: 0x0B03, index: 0x0100, data: [1, 0], length: 2))
}

@Test func impedanceInput2Instrument() {
    #expect(Gen1Protocol.impedance(input: 2, instrument: true).value == 0x0902)
    #expect(Gen1Protocol.impedance(input: 2, instrument: true).data == [1, 0])
}

@Test func headphones1RightVolumeAndMute() {
    let v = Gen1Protocol.outputVolume(pair: 1, channel: 1, dB: -6)
    #expect(v.index == 0x0A00 && v.value == 0x0204 && v.data == [0x00, 0xFA])
    let m = Gen1Protocol.outputMute(pair: 1, channel: 1, muted: true)
    #expect(m.index == 0x0A00 && m.value == 0x0104 && m.data == [1, 0])
}

@Test func masterAndClock() {
    #expect(Gen1Protocol.masterVolume(dB: 0).value == 0x0200)
    #expect(Gen1Protocol.masterMute(false).value == 0x0100)
    let c = Gen1Protocol.clock(.spdif)
    #expect(c.index == 0x2800 && c.value == 0x0100 && c.data == [2] && c.length == 1)
}

@Test func routingRequests() {
    #expect(Gen1Protocol.outputSource(pair: 2, channel: 1, value: 27) ==
        ControlRequest(requestType: 0x21, request: 0x01, value: 5, index: 0x3300, data: [27, 0], length: 2))
    #expect(Gen1Protocol.outputSource(pair: 0, channel: 0, value: -1).data == [0xFF, 0xFF])
    #expect(Gen1Protocol.captureSource(channel: 17, value: 8).value == 17)
    #expect(Gen1Protocol.captureSource(channel: 17, value: 8).index == 0x3400)
    #expect(Gen1Protocol.mixerInputSource(input: 4, value: 12).value == 0x0604)
    #expect(Gen1Protocol.mixerInputSource(input: 4, value: 12).index == 0x3200)
}

@Test func matrixGain() {
    let g = Gen1Protocol.matrixGain(input: 17, mix: 7, dB: -128)
    #expect(g.index == 0x3C00 && g.value == (17 << 3) + 7 && g.data == [0x00, 0x80])
}

@Test func memRequests() {
    #expect(Gen1Protocol.syncStatus() ==
        ControlRequest(requestType: 0xA1, request: 0x03, value: 0x0002, index: 0x3C00, data: [], length: 1))
    #expect(Gen1Protocol.saveToDevice() ==
        ControlRequest(requestType: 0x21, request: 0x03, value: 0x005A, index: 0x3C00, data: [0xA5], length: 1))
}

@Test func keysDifferAcrossRequestKinds() {
    #expect(Gen1Protocol.saveToDevice().key != Gen1Protocol.matrixGain(input: 11, mix: 2, dB: 0).key)
    #expect(Gen1Protocol.syncStatus().key != Gen1Protocol.matrixGain(input: 0, mix: 2, dB: 0).key)
    #expect(Gen1Protocol.pad(input: 1, on: true).key == Gen1Protocol.pad(input: 1, on: false).key)
}

@Test func onlyKnownMemReadsAreSafe() {
    #expect(Gen1Protocol.isSafe(Gen1Protocol.syncStatus()))
    for bank in MeterBank.allCases { #expect(Gen1Protocol.isSafe(Gen1Protocol.meters(bank, count: 8))) }
    #expect(Gen1Protocol.isSafe(Gen1Protocol.saveToDevice()))
    #expect(Gen1Protocol.isSafe(Gen1Protocol.pad(input: 1, on: true)))
    #expect(!Gen1Protocol.isSafe(ControlRequest(requestType: 0xA1, request: 0x03, value: 4, index: 0x3C00, data: [], length: 2)))
}
