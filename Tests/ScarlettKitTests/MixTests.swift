import Foundation
import Testing
@testable import ScarlettKit

@Test func panLaw() {
    #expect(MixerState.panGains(level: -6, pan: 0) == (-6, -6))
    #expect(MixerState.panGains(level: 0, pan: 50) == (-6, 0))
    #expect(MixerState.panGains(level: 0, pan: -50) == (0, -6))
    #expect(MixerState.panGains(level: 0, pan: 100) == (-128, 0))
    #expect(MixerState.panGains(level: -128, pan: 0) == (-128, -128))
    #expect(MixerState.panGains(level: 6, pan: -100) == (6, -128))
}

@Test func defaultMixesPlayDAW() {
    let m = DeviceModel.scarlett18i8
    let s = MixerState.defaults(for: m)
    // Mixer inputs 17 and 18 (index 16, 17) are PCM 1 and 2.
    for mix in 0..<8 {
        #expect(s.matrix[16][mix] == (mix % 2 == 0 ? 0 : -128))
        #expect(s.matrix[17][mix] == (mix % 2 == 0 ? -128 : 0))
        #expect(s.matrix[0][mix] == -128)
    }
}

@Test func muteAndSolo() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.mixes[0][0] = MixStrip(level: -3, pan: 0, muted: false)
    #expect(s.matrix[0][0] == -3 && s.matrix[0][1] == -3)
    s.mixes[0][0].muted = true
    #expect(s.matrix[0][0] == -128)
    s.mixes[0][0].muted = false
    s.solo[0] = 0
    #expect(s.matrix[0][0] == -3)
    #expect(s.matrix[16][0] == -128)   // PCM 1 silenced in mix A/B
    #expect(s.matrix[16][2] == 0)      // but not in mix C/D
}

@Test func soloRestoresOnUnsolo() {
    var s = MixerState.defaults(for: .scarlett18i8)
    let before = s.matrix
    s.solo[1] = 5
    #expect(s.matrix != before)
    s.solo[1] = nil
    #expect(s.matrix == before)
}

@Test func copyMixAndPlaysOn() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.mixes[0][3].level = -10
    s.copyMix(0, to: 2)
    #expect(s.mixes[2] == s.mixes[0])
    #expect(s.outputsPlaying(mixPair: 0) == [1])   // Headphones 1 plays Mix A/B
    #expect(s.outputsPlaying(mixPair: 3) == [])
}

@Test func stripRangesAreValidated() {
    let m = DeviceModel.scarlett18i8
    var s = MixerState.defaults(for: m); s.mixes[0][0].pan = 500
    #expect(!s.matches(m))
    s = .defaults(for: m); s.mixes[1][2].level = 99
    #expect(!s.matches(m))
    s = .defaults(for: m); s.solo[0] = 18
    #expect(!s.matches(m))
    s = .defaults(for: m); s.mixes.removeLast()
    #expect(!s.matches(m))
}

@Test func loadsFormat1State() throws {
    // A stage 1 file: routing plus a raw matrix. Input 0 sends -6/-6 to mix A/B, input 1 sends 0/-6.
    var matrix = Array(repeating: Array(repeating: -128, count: 8), count: 18)
    matrix[0][0] = -6; matrix[0][1] = -6
    matrix[1][0] = 0; matrix[1][1] = -6
    let v1: [String: Any] = [
        "formatVersion": 1, "clock": 1, "instrument": ["1": false, "2": false],
        "pad": ["1": false, "2": false, "3": true, "4": false],
        "outputs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(MixerState.defaults(for: .scarlett18i8).outputs)),
        "capture": try JSONSerialization.jsonObject(with: JSONEncoder().encode(MixerState.defaults(for: .scarlett18i8).capture)),
        "mixerInputs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(DeviceModel.scarlett18i8.defaultMixerInputs)),
        "matrix": matrix,
    ]
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: v1).write(to: url)
    let s = try StateStore.load(from: url)
    #expect(s.formatVersion == 2 && s.pad[3] == true)
    #expect(s.mixes[0][0] == MixStrip(level: -6, pan: 0, muted: false))
    #expect(s.mixes[0][1] == MixStrip(level: 0, pan: -50, muted: false))   // louder on the left
    #expect(s.matrix[1][0] == 0 && s.matrix[1][1] == -6)
    #expect(s.matches(.scarlett18i8))
}

@Test func format1WithUnevenRowsIsRejected() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    var matrix = Array(repeating: Array(repeating: -128, count: 8), count: 18)
    matrix[5] = [0, 0]
    let s = MixerState.defaults(for: .scarlett18i8)
    let v1: [String: Any] = [
        "formatVersion": 1, "clock": 1, "instrument": ["1": false, "2": false],
        "pad": ["1": false, "2": false, "3": false, "4": false],
        "outputs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.outputs)),
        "capture": try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.capture)),
        "mixerInputs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(s.mixerInputs)),
        "matrix": matrix,
    ]
    try JSONSerialization.data(withJSONObject: v1).write(to: url)
    #expect(throws: (any Error).self) { try StateStore.load(from: url) }
    var huge = v1; var m2 = Array(repeating: Array(repeating: -128, count: 8), count: 18)
    m2[0][0] = Int.max; m2[0][1] = Int.min
    huge["matrix"] = m2
    try JSONSerialization.data(withJSONObject: huge).write(to: url)
    _ = try? StateStore.load(from: url)   // must not trap
}
