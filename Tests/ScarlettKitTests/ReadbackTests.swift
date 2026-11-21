import Foundation
import Testing
@testable import ScarlettKit

@Test func readingRequestMirrorsTheWrite() {
    #expect(Gen1Protocol.reading(Gen1Protocol.pad(input: 3, on: true), length: 1) ==
        ControlRequest(requestType: 0xA1, request: 0x01, value: 0x0B03, index: 0x0100, data: [], length: 1))
    #expect(Gen1Protocol.isSafe(Gen1Protocol.reading(Gen1Protocol.clock(.internal), length: 1)))
}

@Test func readbackDecoding() {
    let m = DeviceModel.scarlett18i8
    #expect(DeviceReadback.volume([0x00, 0xEC]) == -20)
    #expect(DeviceReadback.volume([0x00, 0x00]) == 0)
    #expect(DeviceReadback.flag([0x01, 0x0D]) == true)    // mute: first byte only
    #expect(DeviceReadback.source([0xFF], model: m) == .off)
    #expect(DeviceReadback.source([0x10], model: m) == .spdif(1))
    #expect(DeviceReadback.source([], model: m) == nil)
}

@Test func measuredLevelsBecomeMatrix() {
    let levels: [[Double?]] = [[-20.2, -29.6, nil, 9.0]]
    #expect(DeviceReadback.matrix(fromMixLevels: levels) == [[-20, -30, -128, 6]])
}

private func deviceSetup() -> DeviceReadback {
    let m = DeviceModel.scarlett18i8
    var matrix = Array(repeating: Array(repeating: -128, count: 8), count: 18)
    matrix[16][0] = 0; matrix[17][1] = 0          // S/PDIF 1 left, S/PDIF 2 right in Mix A/B
    matrix[8][2] = -20; matrix[8][3] = -30        // Analog 1 in Mix C/D, louder on the left
    return DeviceReadback(
        clock: .adat, instrument: [1: true, 2: false], pad: [1: false, 2: false, 3: false, 4: true], hiGain: [:],
        outputVolume: [0, -10, -20, 0], outputMuted: [false, true, false, false],
        mixerInputs: (1...8).map(Source.pcm) + (1...8).map(Source.analog) + [.spdif(1), .spdif(2)],
        matrix: matrix)
    _ = m
}

@Test func adoptingTakesTheDeviceSetup() {
    let m = DeviceModel.scarlett18i8
    let before = MixerState.defaults(for: m)
    let s = before.adopting(deviceSetup(), model: m)
    #expect(s.clock == .adat && s.instrument[1] == true && s.pad[4] == true)
    #expect(s.outputs[1].volume == -10 && s.outputs[1].muted)
    #expect(s.mixerInputs[16] == .spdif(1))
    #expect(s.linkedMixerInput(16))                                   // S/PDIF 1-2 stays a stereo strip
    #expect(s.mixes[0][16] == MixStrip(level: 0, pan: 0))
    #expect(s.matrix[16][0] == 0 && s.matrix[17][1] == 0 && s.matrix[16][1] == -128)
    #expect(s.mixes[1][8].level == -20 && s.mixes[1][8].pan < 0)       // mono strip, panned left
    #expect(s.outputs[0].left == before.outputs[0].left)              // routing stays the app's
    #expect(s.capture == before.capture)
    #expect(s.matches(m))
}

@Test func adoptingWithoutMeasurementKeepsTheMixes() {
    let m = DeviceModel.scarlett18i8
    var r = deviceSetup(); r.matrix = nil
    let before = MixerState.defaults(for: m)
    #expect(before.adopting(r, model: m).mixes == before.mixes)
}

@Test func differencesNameWhatDiffers() {
    let m = DeviceModel.scarlett18i8
    let d = MixerState.defaults(for: m).differences(from: deviceSetup(), model: m)
    #expect(d.contains { $0.hasPrefix("Clock") })
    #expect(d.contains { $0.hasPrefix("Headphones 1") })
    #expect(d.contains { $0.hasPrefix("Mixer inputs") })
    let same = MixerState.defaults(for: m).adopting(deviceSetup(), model: m)
    #expect(same.differences(from: deviceSetup(), model: m).isEmpty)
}

@MainActor @Test func readDeviceSendsOnlyReads() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    #expect(await s.readDevice() == nil)
    s.connect(t)
    let r = await s.readDevice()
    #expect(r?.mixerInputs.count == 18 && r?.outputVolume.count == 4)
    #expect(t.sent.allSatisfy { $0.isRead && Gen1Protocol.isSafe($0) })
    #expect(s.status == .justConnected)
}

@Test func adoptingTurnsSourcesTheMixerCantTakeIntoOff() {
    let m = DeviceModel.scarlett18i8
    var r = deviceSetup(); r.mixerInputs[3] = .mix(0)
    let s = MixerState.defaults(for: m).adopting(r, model: m)
    #expect(s.mixerInputs[3] == .off)
    #expect(s.matches(m))
}

/// The measurement can't see gains below about -83 dB and reports them as silent. A strip that quiet
/// in the app must not count as a difference.
@Test func mixesBelowTheMeasurementFloorMatchSilence() {
    let m = DeviceModel.scarlett18i8
    var s = MixerState.defaults(for: m).adopting(deviceSetup(), model: m)
    s.mixes[1][8] = MixStrip(level: -60, pan: -95)          // quiet side about -86 dB
    var r = deviceSetup(); r.matrix = s.matrix
    r.matrix![8].indices.forEach { if r.matrix![8][$0] < DeviceReadback.measurementFloor { r.matrix![8][$0] = -128 } }
    #expect(s.matrix[8].contains { $0 < DeviceReadback.measurementFloor && $0 > -128 })
    #expect(s.differences(from: r, model: m).isEmpty)
}
