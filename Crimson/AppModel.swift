import AppKit
import Foundation
import UniformTypeIdentifiers
import Observation
import ScarlettKit

/// Owns the session for the attached model, watches for devices, and keeps one state file per model.
@MainActor @Observable
final class AppModel {
    static let vendorID: UInt16 = 0x1235

    /// Alerts about another model's setup are dropped when the session changes, so their setups can't
    /// be loaded into the wrong model.
    private(set) var session: DeviceSession {
        didSet { pendingRead = nil; connectNotice = nil }
    }
    private var lastSync: Bool?
    /// The last clock lock reading, or nil while not connected.
    var syncLocked: Bool? { session.isConnected ? lastSync : nil }
    /// The attached supported device, as IOKit reports it. Set even when the session dropped after an error.
    private(set) var presentProductID: UInt16?
    @ObservationIgnored private var watcher: DeviceWatcher?

    private static let lastModelKey = "lastProductID"

    init() {
        let last = UInt16(truncatingIfNeeded: UserDefaults.standard.integer(forKey: Self.lastModelKey))
        session = Self.makeSession(for: DeviceModel.model(productID: last) ?? .scarlett18i8)
        watchConnection(of: session)
        watcher = DeviceWatcher(vendorID: Self.vendorID) { [weak self] productID, attached in
            Task { @MainActor in self?.deviceChanged(productID, attached: attached) }
        }
    }

    /// A session for `model` with its saved setup, or defaults when there is none or it can't be used.
    private static func makeSession(for model: DeviceModel) -> DeviceSession {
        let url = stateURL(for: model)
        var state = MixerState.defaults(for: model)
        var loadError: String?
        if let url, FileManager.default.fileExists(atPath: url.path) {
            do {
                let loaded = try StateStore.load(from: url)
                if loaded.matches(model) { state = loaded } else {
                    loadError = "The saved setup doesn't fit the \(model.name), so the app started with defaults."
                }
            } catch {
                loadError = "Could not read the saved setup, so the app started with defaults. (\(error))"
            }
        }
        let session = DeviceSession(model: model, state: state, stateURL: url)
        session.lastError = loadError
        return session
    }

    /// `state-8014.json` and so on. The 18i8's setup from before per-model files moves there once.
    private static func stateURL(for model: DeviceModel) -> URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true) else { return nil }
        let url = dir.appending(path: String(format: "state-%04x.json", model.productID))
        let legacy = dir.appending(path: "state.json")
        if model.productID == DeviceModel.scarlett18i8.productID,
           !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: url)
        }
        return url
    }

    /// A failed request looks the same whether the device was turned off or stopped answering. Turned
    /// off, IOKit reports it gone within a moment and no error shows. Either way, unsaved changes are
    /// remembered, so the reconnect warning can say the device came back with its saved setup.
    private func watchConnection(of session: DeviceSession) {
        session.onConnectionLost = { [weak self, weak session] wasUnsaved, message in
            guard let self, let session else { return }
            if wasUnsaved { self.lostUnsaved = session.model.productID }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                if self.presentProductID != nil, !session.isConnected, session === self.session {
                    session.lastError = message
                }
            }
        }
    }

    /// The model whose device went away while it had changes not saved to it.
    @ObservationIgnored private var lostUnsaved: UInt16?

    /// Shown when a device connects with a setup that differs from the app's, or after it went away unsaved.
    struct ConnectNotice { let cameBackUnsaved: Bool; let differences: [String] }
    var connectNotice: ConnectNotice?

    private func deviceChanged(_ product: UInt16, attached: Bool) {
        // The app works with one Scarlett at a time: it keeps the one it has and ignores the others.
        if let present = presentProductID, present != product { return }
        let productID: UInt16? = attached ? product : nil
        adatDetected = false
        adatHold = SignalHold(seconds: 10)
        deviceDifferences = []
        if productID == nil, session.status == .unsaved { lostUnsaved = session.model.productID }
        guard let productID, let model = DeviceModel.model(productID: productID) else {
            presentProductID = nil
            session.disconnect()
            return
        }
        if model.productID != session.model.productID {
            let old = session
            old.disconnect()
            Task { await old.flush() }
            session = Self.makeSession(for: model)
            watchConnection(of: session)
            UserDefaults.standard.set(Int(model.productID), forKey: Self.lastModelKey)
        }
        presentProductID = productID
        reconnect()
    }

    /// With nothing connected, opens `model`'s saved setup to edit offline. A device that connects
    /// later takes over, as it does on launch.
    func showOffline(_ model: DeviceModel) {
        guard presentProductID == nil, model.productID != session.model.productID else { return }
        let old = session
        Task { await old.flush() }
        session = Self.makeSession(for: model)
        watchConnection(of: session)
        UserDefaults.standard.set(Int(model.productID), forKey: Self.lastModelKey)
        deviceDifferences = []
    }

    /// Opens the attached device again after an error. Sends nothing.
    func reconnect() {
        guard let productID = presentProductID else { return }
        if let device = USBDevice(vendorID: Self.vendorID, productID: productID) {
            session.connect(device)
            Task { await checkDevice() }
        } else {
            session.disconnect()
            session.lastError = "Could not open the \(session.model.name). Unplug it and plug it back in."
        }
    }

    /// Saves the current setup as a preset file the owner picks.
    func savePreset() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Preset.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try StateStore.save(session.state, to: url) } catch {
            session.lastError = "Could not save the preset. (\(error.localizedDescription))"
        }
    }

    /// Replaces the setup with a preset file. On any problem the setup stays as it was.
    func openPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try StateStore.load(from: url)
            guard loaded.matches(session.model) else {
                session.lastError = "This preset is not for the \(session.model.name). Nothing changed."
                return
            }
            session.replace(with: loaded)
        } catch StateStoreError.unsupportedVersion {
            session.lastError = "This preset was made by a newer version of the app. Nothing changed."
        } catch {
            session.lastError = "Could not read the preset. Nothing changed."
        }
    }

    /// Progress from 0 to 1 while Read from Device runs, nil otherwise.
    private(set) var readProgress: Double?
    /// Where the device's readable settings differ from the app, checked on connect.
    private(set) var deviceDifferences: [String] = []

    /// Reads everything the device reports, measures its mixes, and loads both into the app.
    /// Routing, which the device can't report, stays as the app has it.
    func readFromDevice() async {
        let session = self.session
        guard session.isConnected, readProgress == nil else { return }
        readProgress = 0
        defer { readProgress = nil }
        guard var readback = await session.readDevice() else {
            session.lastError = "Could not read the \(session.model.name)."
            return
        }
        do {
            let levels = try await MixMeasurement.measure(session: session, original: readback) { [weak self] in
                self?.readProgress = $0
            }
            readback.matrix = DeviceReadback.matrix(fromMixLevels: levels)
        } catch {
            session.lastError = "Could not measure the mixes, so they stay as they were. The other settings were read."
        }
        guard session === self.session else { return }   // another device connected meanwhile
        let differences = session.state.differences(from: readback, model: session.model)
        deviceDifferences = differences
        if !differences.isEmpty {
            pendingRead = PendingRead(state: session.state.adopting(readback, model: session.model), differences: differences)
        }
    }

    /// A finished Read from Device that differs from the app, waiting for the owner to pick a side.
    struct PendingRead { let state: MixerState; let differences: [String] }
    var pendingRead: PendingRead?

    /// Loads the device's setup into the app. Writes nothing to the device.
    func useDeviceSetup() {
        guard let pendingRead else { return }
        session.adopt(pendingRead.state)
        deviceDifferences = []
        self.pendingRead = nil
    }

    /// Compares the device's readable settings with the app's. Reads only.
    func checkDevice() async {
        let session = self.session
        guard let readback = await session.readDevice(), session === self.session else { return }
        deviceDifferences = session.state.differences(from: readback, model: session.model)
        let cameBack = lostUnsaved == session.model.productID
        lostUnsaved = nil
        if cameBack || !deviceDifferences.isEmpty {
            connectNotice = ConnectNotice(cameBackUnsaved: cameBack, differences: deviceDifferences)
        }
    }

    /// Saves the app's setup on the device, after which they match.
    func saveToDevice() async {
        guard readProgress == nil else { return }   // a running read has muted the outputs; don't store that
        await session.saveToDevice()
        if session.status == .inSync { deviceDifferences = [] }
    }

    private(set) var meters: MeterLevels?
    /// True while ADAT inputs carry anything, and for 10 s after they go to digital zero (unplugged).
    /// ADAT strips then show even if hidden.
    private(set) var adatDetected = false
    @ObservationIgnored private var adatHold = SignalHold(seconds: 10)

    /// Whether a port is hidden right now: hidden in Configuration, unless it's ADAT and ADAT signal was seen.
    func isHidden(_ source: Source) -> Bool {
        guard session.state.ports.hidden.contains(source) else { return false }
        if case .adat = source, adatDetected { return false }
        return true
    }

    /// Reads meters at about 15 Hz while connected, until the calling task is cancelled.
    /// Peaks show at once and fall back at 24 dB per second.
    func pollMeters() async {
        var last = ContinuousClock.now
        while session.isConnected, !Task.isCancelled {
            if readProgress != nil {                    // measuring: its meter reads must not be shared
                try? await Task.sleep(for: .milliseconds(66))
                continue
            }
            if let read = await session.readMeters() {
                let now = ContinuousClock.now
                let dt = Double((now - last).components.attoseconds) / 1e18 + Double((now - last).components.seconds)
                meters = meters?.falling(toward: read, dBPerSecond: 24, seconds: dt) ?? read
                let adat = adatHold.update(read.hasSignal(on: Source.adat, model: session.model), at: .now)
                if adat != adatDetected { adatDetected = adat }
                last = now
            } else {
                meters = nil
            }
            try? await Task.sleep(for: .milliseconds(66))
        }
        meters = nil
    }

    func refreshSync() async {
        lastSync = await session.readSyncLocked()
    }
}
