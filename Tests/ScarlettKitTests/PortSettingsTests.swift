import Foundation
import Testing
@testable import ScarlettKit

@Test func linkedPairPlaysLeftToLeft() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.mixes[0][16] = MixStrip(level: 0, pan: 0)          // PCM 1-2 linked by default, centered
    s.mixes[0][17] = MixStrip(level: 6, pan: -100)        // ignored while linked
    #expect(s.linkedMixerInput(16))
    #expect(s.matrix[16][0] == 0 && s.matrix[16][1] == -128)
    #expect(s.matrix[17][0] == -128 && s.matrix[17][1] == 0)
    s.mixes[0][16].pan = 50                               // balance right: left side drops 6 dB
    #expect(s.matrix[16][0] == -6 && s.matrix[17][1] == 0)
}

@Test func stage2StateGetsDefaultLinks() throws {
    var old = MixerState.defaults(for: .scarlett18i8)
    old.mixes[0][16] = MixStrip(level: 0, pan: 0); old.mixes[0][17] = MixStrip(level: 0, pan: 0)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    json.removeValue(forKey: "ports")
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let s = try StateStore.load(from: url)
    #expect(s.ports == PortSettings.standard)
    #expect(s.matrix[16][0] == 0 && s.matrix[16][1] == -128 && s.matrix[17][1] == 0)
}

@Test func linkTakesLeftStrip() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.mixes[1][0] = MixStrip(level: -10, pan: 0); s.mixes[1][1] = MixStrip(level: 6, pan: 0)
    s.setLinked(.analog(1), true)
    #expect(s.matrix[0][2] == -10 && s.matrix[1][3] == 6)   // each side keeps what it sent
    #expect(s.matrix[0][3] == -128 && s.matrix[1][2] == -128)
}

@Test func unlinkKeepsTheSound() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.mixes[0][16] = MixStrip(level: -3, pan: 0)
    let before = s.matrix
    s.setLinked(.pcm(1), false)
    #expect(s.matrix == before)
}

@Test func namesAndPartners() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.ports.names[.analog(1)] = "Vocal"
    #expect(s.displayName(.analog(1)) == "Vocal" && s.displayName(.analog(2)) == "Analog 2")
    #expect(PortSettings.partner(of: .pcm(1)) == .pcm(2))
    #expect(PortSettings.partner(of: .pcm(2)) == nil)
    #expect(PortSettings.partner(of: .mix(0)) == nil)
}

@Test func linkHardPannedPairKeepsBothSides() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.mixes[0][0] = MixStrip(level: 0, pan: -100); s.mixes[0][1] = MixStrip(level: -6, pan: 100)
    let before = s.matrix
    s.setLinked(.analog(1), true)
    #expect(s.matrix[0][0] == before[0][0] && s.matrix[1][1] == before[1][1])   // 0 left, -6 right
    #expect(s.mixes[0][0] == MixStrip(level: 0, pan: -50))
}

@Test func linkMovesSoloFromRightPort() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.solo[0] = 1
    s.setLinked(.analog(1), true)
    #expect(s.solo[0] == 0)
}

@Test func olderFilesWithHardPannedPairsKeepTheRightChannel() throws {
    var old = MixerState.defaults(for: .scarlett18i8)
    old.mixes[1][16] = MixStrip(level: 0, pan: -100); old.mixes[1][17] = MixStrip(level: 0, pan: 100)
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
    json.removeValue(forKey: "ports")
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    let s = try StateStore.load(from: url)
    #expect(s.matrix[16][2] == 0 && s.matrix[17][3] == 0)
}

@Test func namesIgnoreSurroundingSpaces() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.ports.names[.analog(1)] = "Lead "
    #expect(s.displayName(.analog(1)) == "Lead")
    s.ports.names[.analog(1)] = "  "
    #expect(s.displayName(.analog(1)) == "Analog 1")
}

@Test func fileWithShortMixRowsLoadsAndFailsTheModelCheck() throws {
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(MixerState.defaults(for: .scarlett18i8))) as! [String: Any]
    json.removeValue(forKey: "ports")
    json["mixes"] = (json["mixes"] as! [[Any]]).map { Array($0.prefix(4)) }
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    try JSONSerialization.data(withJSONObject: json).write(to: url)
    #expect(try !StateStore.load(from: url).matches(.scarlett18i8))
}
