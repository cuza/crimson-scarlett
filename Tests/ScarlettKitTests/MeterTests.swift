import Foundation
import Testing
@testable import ScarlettKit

@Test func memReadsStayInTheSafeTable() {
    let values = MeterBank.allCases.map { Gen1Protocol.meters($0, count: 1).value } + [Gen1Protocol.syncStatus().value]
    #expect(Set(values) == [0, 1, 2, 3])
    #expect(Gen1Protocol.meters(.pcm, count: 8) ==
        ControlRequest(requestType: 0xA1, request: 0x03, value: 3, index: 0x3C00, data: [], length: 16))
}

@Test func meterDecoding() {
    #expect(MeterLevels.decode([0xFF, 0xFF, 0x00, 0x00], fullScale: 65535) == [0, -100])
    let half = MeterLevels.decode([0xFF, 0x7F], fullScale: 65535)[0]
    #expect(abs(half - -6.02) < 0.01)
}

@MainActor @Test func readsAndWritesShareQueueInOrder() async throws {
    let t = FakeTransport(delay: .milliseconds(2)); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t)
    s.update { $0.pad[1] = true }
    async let meters = s.readMeters()
    for v in stride(from: 0, through: -40, by: -1) { s.update { $0.outputs[0].volume = v } }
    _ = await meters
    await s.flush()
    #expect(t.sent.first == Gen1Protocol.pad(input: 1, on: true))
    #expect(t.sent.filter { $0.isRead }.count == 3)
    #expect(t.sent.filter { $0.index == 0x0A00 }.count < 10)
    #expect(t.sent.last(where: { $0.index == 0x0A00 })?.data == Gen1Protocol.gainBytes(-40))
}

@MainActor @Test func meterLevelsHaveModelCounts() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    #expect(await s.readMeters() == nil)
    s.connect(t)
    let m = await s.readMeters()
    #expect(m?.inputs.count == 18 && m?.mixes.count == 8 && m?.pcm.count == 8)
    #expect(s.status == .justConnected)
}

@MainActor @Test func meterReadFailureDisconnectsOnce() async {
    let t = FakeTransport(failAfter: 1); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t)
    #expect(await s.readMeters() == nil)
    #expect(s.status == .disconnected && s.lastError != nil)
    s.lastError = nil
    #expect(await s.readMeters() == nil)
    #expect(s.lastError == nil)   // already disconnected: no second error
}

@Test func meterForSource() {
    let m = MeterLevels(inputs: (0..<18).map(Double.init), mixes: (100..<108).map(Double.init), pcm: (200..<208).map(Double.init))
    let model = DeviceModel.scarlett18i8
    #expect(m.level(of: .analog(1), model: model) == 0)
    #expect(m.level(of: .spdif(2), model: model) == 9)
    #expect(m.level(of: .adat(8), model: model) == 17)
    #expect(m.level(of: .pcm(3), model: model) == 202)
    #expect(m.level(of: .mix(7), model: model) == 107)
    #expect(m.level(of: .off, model: model) == nil)
    #expect(m.level(of: .pcm(9), model: model) == nil)
}

@Test func metersRiseAtOnceAndFallSlowly() {
    let shown = MeterLevels(inputs: [-10, -50], mixes: [], pcm: [0])
    let read = MeterLevels(inputs: [-5, -100], mixes: [], pcm: [-100])
    let next = shown.falling(toward: read, dBPerSecond: 24, seconds: 0.5)
    #expect(next.inputs == [-5, -62])   // rises at once; falls 12 dB in 0.5 s
    #expect(next.pcm == [-12])
    // A reading with a different shape replaces the shown one.
    #expect(MeterLevels(inputs: [], mixes: [], pcm: []).falling(toward: read, dBPerSecond: 24, seconds: 1) == read)
}

@Test func adatSignalIsDetectedFromInputMeters() {
    let model = DeviceModel.scarlett18i8
    var inputs = Array(repeating: -100.0, count: 18)
    inputs[0] = -20   // Analog 1 alone is not ADAT
    #expect(!MeterLevels(inputs: inputs, mixes: [], pcm: []).hasSignal(on: Source.adat, model: model))
    inputs[10 + 3] = -70   // ADAT 4
    #expect(MeterLevels(inputs: inputs, mixes: [], pcm: []).hasSignal(on: Source.adat, model: model))
    #expect(!MeterLevels(inputs: inputs, mixes: [], pcm: []).hasSignal(on: Source.adat, model: .scarlett6i6))
}

@Test func anyNonZeroLevelCountsAsSignal() {
    var inputs = Array(repeating: -100.0, count: 18)
    inputs[10] = -95   // a faint noise floor still means a device is sending
    #expect(MeterLevels(inputs: inputs, mixes: [], pcm: []).hasSignal(on: Source.adat, model: .scarlett18i8))
}

@Test func signalHoldDropsAfterSilence() {
    var hold = SignalHold(seconds: 10)
    let t0 = Date(timeIntervalSince1970: 0)
    let before = hold.update(false, at: t0)
    let heard = hold.update(true, at: t0)
    let quiet9 = hold.update(false, at: t0.addingTimeInterval(9))
    let quiet11 = hold.update(false, at: t0.addingTimeInterval(11))
    let back = hold.update(true, at: t0.addingTimeInterval(12))
    #expect(!before && heard && quiet9 && !quiet11 && back)
}
