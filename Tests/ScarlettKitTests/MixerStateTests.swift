import Foundation
import Testing
@testable import ScarlettKit

@Test func allRequestsCount18i8() {
    let m = DeviceModel.scarlett18i8
    let r = MixerState.defaults(for: m).allRequests(for: m)
    // 2 master + 1 clock + 2 impedance + 4 pad + 8 output source + 8 volume + 8 mute
    // + 18 capture + 18 mixer input + 18*8 matrix
    #expect(r.count == 2 + 1 + 2 + 4 + 8 + 8 + 8 + 18 + 18 + 144)
    #expect(!r.contains { $0.index >> 8 == 0x29 })
    #expect(r.first == Gen1Protocol.masterVolume(dB: 0))
}

@Test func headphones1DefaultsToMixAB() {
    let m = DeviceModel.scarlett18i8
    let r = MixerState.defaults(for: m).allRequests(for: m)
    #expect(r.contains(Gen1Protocol.outputSource(pair: 1, channel: 0, value: 26)))
    #expect(r.contains(Gen1Protocol.outputSource(pair: 1, channel: 1, value: 27)))
}

@Test func roundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    var s = MixerState.defaults(for: .scarlett18i8)
    s.pad[3] = true; s.outputs[0].volume = -12
    try StateStore.save(s, to: url)
    #expect(try StateStore.load(from: url) == s)
}

@Test func corruptFileLeavesStateUnchanged() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    try Data("{not json".utf8).write(to: url)
    #expect(throws: (any Error).self) { try StateStore.load(from: url) }
    try Data().write(to: url)
    #expect(throws: (any Error).self) { try StateStore.load(from: url) }
    var future = MixerState.defaults(for: .scarlett18i8); future.formatVersion = 3
    try StateStore.save(future, to: url)
    #expect(throws: StateStoreError.unsupportedVersion(3)) { try StateStore.load(from: url) }
}

@Test func stateShapeMustMatchModel() {
    let m = DeviceModel.scarlett18i8
    var s = MixerState.defaults(for: m)
    #expect(s.matches(m))
    s.capture.removeLast()
    #expect(!s.matches(m))
    s = .defaults(for: m); s.outputs.append(s.outputs[0])
    #expect(!s.matches(m))
    s = .defaults(for: m); s.mixes[3].append(MixStrip())
    #expect(!s.matches(m))
    s = .defaults(for: m); s.mixerInputs = []
    #expect(!s.matches(m))
}

@Test func stateWithOutOfRangeValuesDoesNotMatch() {
    let m = DeviceModel.scarlett18i8
    var s = MixerState.defaults(for: m); s.outputs[0].left = .mix(300)
    #expect(!s.matches(m))
    s = .defaults(for: m); s.capture[0] = .analog(9)
    #expect(!s.matches(m))
    s = .defaults(for: m); s.mixerInputs[0] = .pcm(0)
    #expect(!s.matches(m))
    s = .defaults(for: m); s.outputs[1].volume = 7
    #expect(!s.matches(m))
    s = .defaults(for: m); s.mixes[0][0].level = -129
    #expect(!s.matches(m))
}

@Test func sourceNameNeverTraps() {
    #expect(Source.mix(300).name == "Mix 301")
    #expect(Source.mix(-1).name == "Mix 0")
}
