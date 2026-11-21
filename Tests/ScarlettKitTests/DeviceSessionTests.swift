import Foundation
import Testing
@testable import ScarlettKit

/// Records every request. Can sleep per request and throw after a number of requests.
final class FakeTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [ControlRequest] = []
    let delay: Duration
    let failAfter: Int?

    init(delay: Duration = .zero, failAfter: Int? = nil) {
        self.delay = delay
        self.failAfter = failAfter
    }

    var sent: [ControlRequest] { lock.withLock { _sent } }

    func send(_ r: ControlRequest) throws -> [UInt8] {
        if delay > .zero { Thread.sleep(forTimeInterval: Double(delay.components.attoseconds) / 1e18) }
        return try lock.withLock {
            if let failAfter, _sent.count >= failAfter { throw USBError.ioReturn(-536_870_186) }
            _sent.append(r)
            return r.isRead ? [UInt8](repeating: 1, count: Int(r.length)) : []
        }
    }
}

@MainActor @Test func connectDoesNotWrite() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t); await s.flush()
    #expect(t.sent.isEmpty && s.status == .justConnected)
}

@MainActor @Test func reconnectDoesNotWrite() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t); s.disconnect(); s.connect(t); await s.flush()
    #expect(t.sent.isEmpty && s.status == .justConnected)
}

@MainActor @Test func editSendsOnlyThatControl() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t); s.update { $0.pad[3] = true }; await s.flush()
    #expect(t.sent == [Gen1Protocol.pad(input: 3, on: true)])
}

@MainActor @Test func sliderDragIsCoalesced() async {
    let t = FakeTransport(delay: .milliseconds(5)); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t)
    for v in stride(from: 0, through: -60, by: -1) { s.update { $0.outputs[0].volume = v } }
    await s.flush()
    #expect(t.sent.count < 10)
    #expect(t.sent.suffix(2).allSatisfy { $0.data == Gen1Protocol.gainBytes(-60) })
}

@MainActor @Test func statusTransitions() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t); await s.sendAll(); #expect(s.status == .unsaved)
    #expect(t.sent.count == 213)
    await s.saveToDevice(); #expect(s.status == .inSync)
    #expect(t.sent.last == Gen1Protocol.saveToDevice())
    s.update { $0.pad[1] = true }; #expect(s.status == .unsaved)
}

@MainActor @Test func editsWhileDisconnectedAreStoredNotSent() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: url)
    s.update { $0.pad[2] = true }; await s.flush()
    #expect(s.status == .disconnected)
    #expect(try StateStore.load(from: url).pad[2] == true)
}

@MainActor @Test func unplugMidSendAll() async {
    let t = FakeTransport(failAfter: 10); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    let before = s.state
    s.connect(t); await s.sendAll()
    #expect(s.status == .disconnected && s.lastError != nil && s.state == before)
}

@MainActor @Test func syncReadReportsLockAndWritesNothing() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    #expect(await s.readSyncLocked() == nil)
    s.connect(t)
    #expect(await s.readSyncLocked() == true)
    #expect(t.sent == [Gen1Protocol.syncStatus()] && s.status == .justConnected)
}

@MainActor @Test func saveSendsEverythingThenStores() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t); s.update { $0.pad[1] = true }
    await s.saveToDevice()
    // Right after connecting the device may differ from the app, so Save sends the whole setup first.
    #expect(t.sent.count == 213 + 1)   // the pending pad edit merges into the full setup
    #expect(t.sent.last == Gen1Protocol.saveToDevice())
    #expect(s.status == .inSync)
}

@MainActor @Test func editDuringSaveLeavesUnsaved() async {
    let t = FakeTransport(delay: .milliseconds(2)); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t); await s.sendAll()
    let before = t.sent.count
    async let saved: Void = s.saveToDevice()
    while t.sent.count == before { await Task.yield() }   // the save is under way
    s.update { $0.pad[2] = true }
    await saved
    #expect(s.status == .unsaved)
}

@MainActor @Test func saveWhileSendAllDrainsKeepsEveryWrite() async {
    let t = FakeTransport(delay: .milliseconds(1)); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t)
    async let sent: Void = s.sendAll()
    await Task.yield()
    await s.saveToDevice()
    await sent
    #expect(t.sent.count == 214)
    #expect(t.sent.last == Gen1Protocol.saveToDevice())
    #expect(t.sent.contains(Gen1Protocol.matrixGain(input: 11, mix: 2, dB: -128)))
}

@MainActor @Test func stateFileIsWrittenOnFlushAfterManyEdits() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: url)
    for v in stride(from: 0, through: -60, by: -1) { s.update { $0.outputs[0].volume = v } }
    #expect(!FileManager.default.fileExists(atPath: url.path))   // not written per tick
    await s.flush()
    #expect(try StateStore.load(from: url).outputs[0].volume == -60)
}

@MainActor @Test func appOnlyEditsKeepInSync() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t); await s.sendAll(); await s.saveToDevice()
    s.update { $0.ports.names[.analog(1)] = "Vocal" }
    #expect(s.status == .inSync)
}

@MainActor @Test func adoptChangesStateWithoutWriting() async {
    let t = FakeTransport(); let m = DeviceModel.scarlett18i8
    let s = DeviceSession(model: m, state: .defaults(for: m), stateURL: nil)
    s.connect(t)
    var next = s.state; next.outputs[0].volume = -20; next.mixes[0][0].level = -30
    s.adopt(next); await s.flush()
    #expect(t.sent.isEmpty)
    #expect(s.state == next && s.status == .justConnected)
}

@MainActor @Test func lostConnectionReportsUnsavedChanges() async {
    let m = DeviceModel.scarlett18i8
    let saveCount = MixerState.defaults(for: m).allRequests(for: m).count + 1
    let t = FakeTransport(failAfter: saveCount)
    let s = DeviceSession(model: m, state: .defaults(for: m), stateURL: nil)
    var lost: [Bool] = []
    s.onConnectionLost = { wasUnsaved, _ in lost.append(wasUnsaved) }
    s.connect(t)
    await s.saveToDevice()
    #expect(s.status == .inSync)
    s.update { $0.outputs[0].volume = -20 }   // this write fails: the device went away
    await s.flush()
    #expect(lost == [true])
    #expect(s.status == .disconnected && s.lastError == nil)
}

@MainActor @Test func editRightAfterConnectingIsUnsaved() async {
    let t = FakeTransport(); let s = DeviceSession(model: .scarlett18i8, state: .defaults(for: .scarlett18i8), stateURL: nil)
    s.connect(t)
    s.update { $0.outputs[0].volume = -20 }
    #expect(s.status == .unsaved)
}

/// Putting Analog 1-2 on a stereo strip links the pair, so the mono Analog 1 and 2 strips elsewhere
/// become one stereo strip. That strip must keep what the two sent, as the link button does.
@MainActor @Test func pairLinkedFromAnotherStripMergesExistingStrips() async {
    let m = DeviceModel.scarlett18i8
    let s = DeviceSession(model: m, state: .defaults(for: m), stateURL: nil)
    s.update { $0.mixes[0][0] = MixStrip(level: -10, pan: -100); $0.mixes[0][1] = MixStrip(level: -20, pan: 100) }
    let pcmStrip = s.state.mixes[0][16]
    s.update { st in                           // the strip menu on the PCM 1-2 strip picks Analog 1-2
        st.mixerInputs[16] = .analog(1); st.mixerInputs[17] = .analog(2); st.ports.linked.insert(.analog(1))
    }
    #expect(s.state.linkedMixerInput(0))
    #expect(s.state.mixes[0][0] == MixerState.strip(left: -10, right: -20))
    #expect(s.state.mixes[0][16] == pcmStrip)  // the strip that was already stereo keeps its settings
}

@MainActor @Test func replacingTheSetupKeepsItsLinkedStrips() async {
    let m = DeviceModel.scarlett18i8
    let s = DeviceSession(model: m, state: .defaults(for: m), stateURL: nil)
    s.update { $0.setLinked(.pcm(1), false) }
    s.update { $0.mixes[0][16] = MixStrip(level: -30, pan: -100); $0.mixes[0][17] = MixStrip(level: -40, pan: 100) }
    var preset = MixerState.defaults(for: m)   // PCM 1-2 linked
    preset.mixes[0][16] = MixStrip(level: -3, pan: 0)
    s.replace(with: preset)
    #expect(s.state == preset)
}

@MainActor @Test func flushWritesTheStateFileBeforeWaitingForTheDevice() async throws {
    let m = DeviceModel.scarlett18i8
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
    let s = DeviceSession(model: m, state: .defaults(for: m), stateURL: url)
    s.connect(FakeTransport(delay: .milliseconds(300)))
    s.update { $0.outputs[0].volume = -20 }
    let flushing = Task { await s.flush() }
    try await Task.sleep(for: .milliseconds(100))   // the write to the device is still running
    #expect(try StateStore.load(from: url).outputs[0].volume == -20)
    await flushing.value
}
