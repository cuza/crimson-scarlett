import Foundation
import Observation

public enum DeviceStatus: Equatable, Sendable {
    /// No device. Edits are kept and saved to disk.
    case disconnected
    /// Device attached. The app has written nothing yet, so the device may differ from the app.
    case justConnected
    /// The app has changed the device since it last stored a setup, so a power cycle loses those changes.
    case unsaved
    /// The device matches the app and has stored it.
    case inSync
}

/// Holds the state, turns edits into USB writes, and tracks whether the device matches.
/// Writes go through a queue keyed by control, so a newer value replaces a pending one.
@MainActor @Observable
public final class DeviceSession {
    public let model: DeviceModel
    public private(set) var state: MixerState
    public private(set) var status: DeviceStatus = .disconnected
    public var lastError: String?
    /// Called when a request fails and the session drops, with whether the device had changes not
    /// saved to it, and the error to show. When set, `lastError` is left for the owner to decide, since
    /// a device that was just turned off fails the same way.
    @ObservationIgnored public var onConnectionLost: ((_ wasUnsaved: Bool, _ message: String) -> Void)?

    private let stateURL: URL?
    private var transport: (any ControlTransport)?
    /// Changes on every connect and disconnect, so a late failure from an old connection is ignored.
    private var connection = 0
    /// Counts edits, so a save can tell whether something changed while it ran.
    private var edits = 0
    /// A write is coalesced by key. A read waits for its answer and is never merged.
    private enum Item {
        case write(ControlRequest)
        case read(ControlRequest, CheckedContinuation<[UInt8], any Error>)

        var request: ControlRequest {
            switch self {
            case .write(let r), .read(let r, _): r
            }
        }
    }

    private var queue: [Item] = []
    private var worker: Task<Void, Never>?
    /// Pending state file write. Edits within 0.5 s share one write.
    private var saveTask: Task<Void, Never>?

    public init(model: DeviceModel, state: MixerState, stateURL: URL?) {
        self.model = model
        self.state = state
        self.stateURL = stateURL
    }

    public var isConnected: Bool { transport != nil }

    /// Starts using the device. Sends nothing.
    public func connect(_ transport: any ControlTransport) {
        self.transport = transport
        connection += 1
        dropQueue()
        status = .justConnected
    }

    public func disconnect() {
        transport = nil
        connection += 1
        dropQueue()
        status = .disconnected
    }

    public func update(_ edit: (inout MixerState) -> Void) {
        var next = state
        edit(&next)
        next.mergeNewlyLinkedPairs(from: state)
        replace(with: next)
    }

    /// Takes a whole setup as it is, such as a preset, and sends what differs from the current one.
    public func replace(with next: MixerState) {
        guard next != state else { return }
        let old = Dictionary(state.allRequests(for: model).map { ($0.key, $0.data) }, uniquingKeysWith: { _, b in b })
        adopt(next)
        guard transport != nil else { return }
        let changed = next.allRequests(for: model).filter { old[$0.key] != $0.data }
        guard !changed.isEmpty else { return }   // names, links that sound the same, hidden ports: app only
        enqueue(changed)
        status = .unsaved   // connected, and the device now differs from what it stores
    }

    /// Takes a setup that already matches the device, such as one read from it. Writes nothing.
    public func adopt(_ next: MixerState) {
        guard next != state else { return }
        state = next
        edits += 1
        if stateURL != nil, saveTask == nil {
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(500))
                if !Task.isCancelled { saveStateFile() }
            }
        }
    }

    /// Writes the whole state to the device.
    public func sendAll() async {
        guard transport != nil else { return }
        let conn = connection
        enqueue(state.allRequests(for: model))
        await flush()
        if conn == connection { status = .unsaved }
    }

    /// Sends the whole setup, then tells the device to store it, so the device keeps exactly what the
    /// app shows after a power cycle. Claims `.inSync` only if nothing changed while it ran.
    public func saveToDevice() async {
        guard transport != nil else { return }
        let (conn, edited) = (connection, edits)
        enqueue(state.allRequests(for: model) + [Gen1Protocol.saveToDevice()])
        await flush()
        if conn == connection, edited == edits { status = .inSync }
    }

    /// Writes the state file if a write is pending, then returns when every queued write has been
    /// sent or dropped. The file goes first, so a device that stopped answering can't cost the edits.
    public func flush() async {
        if let pending = saveTask {
            pending.cancel()
            saveStateFile()
        }
        while let w = worker { await w.value }
    }

    private func saveStateFile() {
        saveTask = nil
        guard let stateURL else { return }
        do { try StateStore.save(state, to: stateURL) } catch {
            lastError = "Could not save settings: \(error.localizedDescription)"
        }
    }

    /// Sends a read after every write queued before it. Throws when disconnected or when the read fails.
    public func read(_ r: ControlRequest) async throws -> [UInt8] {
        guard transport != nil else { throw USBError.disconnected }
        return try await withCheckedThrowingContinuation { continuation in
            queue.append(.read(r, continuation))
            startWorker()
        }
    }

    /// Reads every setting the device reports: clock, input switches, output volumes and mutes, and
    /// mixer input sources. Sends only reads. Nil when disconnected or a read fails.
    public func readDevice() async -> DeviceReadback? {
        typealias P = Gen1Protocol
        do {
            func get(_ write: ControlRequest, _ length: UInt16) async throws -> [UInt8] {
                try await read(P.reading(write, length: length))
            }
            let clock = ClockSource(rawValue: try await get(P.clock(.internal), 1).first ?? 0)
            var instrument: [Int: Bool] = [:], pad: [Int: Bool] = [:], hiGain: [Int: Bool] = [:]
            for n in model.impedanceInputs { instrument[n] = DeviceReadback.flag(try await get(P.impedance(input: n, instrument: false), 1)) }
            for n in model.padInputs { pad[n] = DeviceReadback.flag(try await get(P.pad(input: n, on: false), 1)) }
            for n in model.gainInputs { hiGain[n] = DeviceReadback.flag(try await get(P.hiGain(input: n, on: false), 1)) }
            var volume: [Int] = [], muted: [Bool] = []
            for p in model.outputPairs.indices {
                volume.append(DeviceReadback.volume(try await get(P.outputVolume(pair: p, channel: 0, dB: 0), 2)) ?? 0)
                muted.append(DeviceReadback.flag(try await get(P.outputMute(pair: p, channel: 0, muted: false), 1)) ?? false)
            }
            var inputs: [Source] = []
            for i in 0..<model.matrixInputs {
                inputs.append(DeviceReadback.source(try await get(P.mixerInputSource(input: i, value: 0), 1), model: model) ?? .off)
            }
            return DeviceReadback(clock: clock, instrument: instrument, pad: pad, hiGain: hiGain,
                                  outputVolume: volume, outputMuted: muted, mixerInputs: inputs)
        } catch {
            return nil
        }
    }

    /// Sends writes through the queue without changing the state. Only for measuring the device,
    /// which must put back everything it changes.
    public func sendUntracked(_ requests: [ControlRequest]) async {
        guard transport != nil else { return }
        enqueue(requests)
        await flush()
    }

    /// Reads the clock lock state. Nil when disconnected or the read fails.
    public func readSyncLocked() async -> Bool? {
        guard let bytes = try? await read(Gen1Protocol.syncStatus()) else { return nil }
        return bytes.first.map { $0 == 1 }
    }

    /// Reads every meter bank. Nil when disconnected or a read fails.
    public func readMeters() async -> MeterLevels? {
        do {
            func bank(_ b: MeterBank) async throws -> [Double] {
                MeterLevels.decode(try await read(Gen1Protocol.meters(b, count: model.meterCount(b))),
                                   fullScale: model.meterFullScale)
            }
            return MeterLevels(inputs: try await bank(.inputs), mixes: try await bank(.mixes), pcm: try await bank(.pcm))
        } catch {
            return nil
        }
    }

    private func enqueue(_ requests: [ControlRequest]) {
        for r in requests {
            let i = queue.firstIndex { if case .write(let w) = $0 { w.key == r.key } else { false } }
            if let i { queue[i] = .write(r) } else { queue.append(.write(r)) }
        }
        startWorker()
    }

    private func startWorker() {
        if worker == nil, !queue.isEmpty { worker = Task { await drain() } }
    }

    /// Empties the queue. Waiting reads get an error.
    private func dropQueue() {
        let dropped = queue
        queue.removeAll()
        for case .read(_, let c) in dropped { c.resume(throwing: USBError.disconnected) }
    }

    private func drain() async {
        while let t = transport, !queue.isEmpty {
            let item = queue.removeFirst()
            let r = item.request
            let conn = connection
            do {
                let bytes = try await Task.detached { try t.send(r) }.value
                if case .read(_, let c) = item { c.resume(returning: bytes) }
            } catch {
                if case .read(_, let c) = item { c.resume(throwing: error) }
                if conn == connection {
                    let wasUnsaved = status == .unsaved
                    disconnect()
                    let message = "The device stopped answering (\(error)). Reconnect it. If that fails, power-cycle the device."
                    if let onConnectionLost { onConnectionLost(wasUnsaved, message) } else { lastError = message }
                }
            }
        }
        worker = nil
    }
}
