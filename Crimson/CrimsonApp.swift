import AppKit
import ScarlettKit
import SwiftUI

@main
struct CrimsonApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var app = AppModel()

    var body: some Scene {
        Window("Crimson", id: "main") {
            ContentView()
                .environment(app)
                .onAppear { delegate.app = app }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Preset…") { app.openPreset() }.keyboardShortcut("o").disabled(app.readProgress != nil)
                Button("Save Preset…") { app.savePreset() }.keyboardShortcut("s")
            }
            CommandMenu("Device") {
                Button("Read from Device") { Task { await app.readFromDevice() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!app.session.isConnected || app.readProgress != nil
                              || app.connectNotice != nil || app.pendingRead != nil)
                Button("Save to Device") { Task { await app.saveToDevice() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!app.session.isConnected || app.readProgress != nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Lets a running Read from Device finish, so it puts back the mutes and mixer inputs it changed,
    /// then sends pending writes before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let app else { return .terminateNow }
        Task { @MainActor in
            while app.readProgress != nil { try? await Task.sleep(for: .milliseconds(100)) }
            await app.session.flush()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum Screen: String, Hashable { case overview, routing, mixer }

struct ContentView: View {
    @Environment(AppModel.self) private var app
    /// The window reopens on the screen used last.
    @AppStorage("screen") private var lastScreen = Screen.overview.rawValue
    private var screen: Binding<Screen> {
        Binding(get: { Screen(rawValue: lastScreen) ?? .overview }, set: { lastScreen = $0.rawValue })
    }

    /// Status dot, model and connection state. With nothing connected it names the setup being shown.
    @ViewBuilder private var deviceChip: some View {
        let session = app.session
        HStack(spacing: 8) {
            Circle().fill(session.isConnected ? Theme.green : Theme.tertiaryText).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 0) {
                // With nothing attached, the app shows the last model's setup; say so instead of naming it.
                Text(session.isConnected || app.presentProductID != nil ? session.model.name : "No Scarlett connected")
                    .font(.system(size: 13, weight: .semibold))
                Text(session.isConnected ? "Connected · 1st Gen"
                     : app.presentProductID != nil ? "Not responding" : "Showing the \(session.model.name)'s setup")
                    .font(.system(size: 10))
                    .foregroundStyle(!session.isConnected && app.presentProductID != nil ? Theme.orange : Theme.secondaryText)
            }
            if !session.isConnected, app.presentProductID != nil {
                Button("Reconnect", action: app.reconnect)
                    .controlSize(.small)
                    .help("The device is plugged in but stopped answering. Reconnect it; if that fails, power-cycle it.")
            }
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        let session = app.session
        VStack(spacing: 0) {
            switch screen.wrappedValue {
            case .routing: RoutingView()
            case .mixer: MixerView()
            case .overview: OverviewView()
            }
        }
        // A new model has different channel counts; rebuild the screen so no row reads past the new arrays.
        .id(session.model.productID)
        .disabled(app.readProgress != nil)   // Read from Device restores mutes and inputs; edits would be lost
        .background(Theme.window)
        .task(id: session.isConnected) {
            while session.isConnected, !Task.isCancelled {
                await app.refreshSync()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        // Opens at the size that fits the widest console (18 mono strips); smaller windows scroll.
        .frame(minWidth: 1000, idealWidth: 1264, minHeight: 560, idealHeight: 700)
        .preferredColorScheme(.dark)
        .tint(Theme.blue)
        .background(HiddenWindowTitle())
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if app.presentProductID == nil {
                    Menu {
                        Section("Edit a setup offline") {
                            ForEach(DeviceModel.all, id: \.productID) { model in
                                Toggle(model.name, isOn: Binding(get: { session.model.productID == model.productID },
                                                                 set: { if $0 { app.showOffline(model) } }))
                            }
                        }
                    } label: { deviceChip }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Pick which Scarlett's setup to edit while none is connected")
                } else {
                    deviceChip
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("Screen", selection: screen) {
                    Text("Overview").tag(Screen.overview)
                    Text("Routing").tag(Screen.routing)
                    Text("Mixer").tag(Screen.mixer)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if app.syncLocked == false {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                        Text("No clock lock, no sound").font(.caption).foregroundStyle(Theme.red)
                        Button("Fix") { Task { await session.sendAll() } }.controlSize(.small)
                            .disabled(app.readProgress != nil)
                    }
                    .help("The clock source has no signal, so the device plays nothing. Fix sends the app's setup, including the clock chosen on Overview.")
                }
                if session.status == .unsaved {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.yellow).frame(width: 6, height: 6)
                        Text("Not saved").font(.caption).foregroundStyle(Theme.yellow)
                    }
                    .padding(.horizontal, 8)
                    .help("Changes are live on the \(session.model.name) but not saved to it. After a power cycle it starts with its old setup.")
                }
                if let progress = app.readProgress {
                    HStack(spacing: 6) {
                        ProgressView(value: progress).frame(width: 80)
                        Text("Reading, outputs muted").font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                } else if !app.deviceDifferences.isEmpty {
                    DeviceDiffersButton()
                }
                Button("Save to device") { Task { await app.saveToDevice() } }
                    .buttonStyle(.borderedProminent)
                    .help("Send this setup to the \(session.model.name) and store it there, so it starts this way after a power cycle")
                    .disabled(!session.isConnected || app.readProgress != nil)
            }
        }
        .alert("The \(session.model.name) has a different setup", isPresented: Binding(
            get: { app.pendingRead != nil }, set: { if !$0 { app.pendingRead = nil } })
        ) {
            Button("Replace Mine with the Device's") { app.useDeviceSetup() }
            Button("Keep Mine", role: .cancel) { app.pendingRead = nil }
        } message: {
            Text((app.pendingRead?.differences ?? []).joined(separator: "\n")
                 + "\n\nReplace Mine loads what the device has now into the app, and your setup in the app is gone. Keep Mine changes nothing. Save to device then puts your setup on the device. Routing can't be read, so it stays as the app has it.")
        }
        .alert(app.connectNotice?.cameBackUnsaved == true
               ? "The \(session.model.name) came back without your changes"
               : "The \(session.model.name) has a different setup",
               isPresented: Binding(get: { app.connectNotice != nil }, set: { if !$0 { app.connectNotice = nil } })
        ) {
            Button("Save My Setup to Device") { app.connectNotice = nil; Task { await app.saveToDevice() } }
            Button("Not Now", role: .cancel) { app.connectNotice = nil }
        } message: {
            let notice = app.connectNotice
            Text((notice?.cameBackUnsaved == true
                  ? "It was turned off or unplugged before your changes were saved to it, so it started with the setup saved on it. Your setup is still in the app.\n\n"
                  : "It started with the setup saved on it, which differs from the app's.\n\n")
                 + (notice?.differences ?? []).map { $0 + "\n" }.joined()
                 + "\nSave My Setup to Device sends the app's setup and stores it, so it survives the next power cycle.")
        }
        .alert("Problem", isPresented: Binding(get: { session.lastError != nil }, set: { if !$0 { session.lastError = nil } })) {
            Button("OK") { session.lastError = nil }
        } message: { Text(session.lastError ?? "") }
    }
}

/// Hides the window title so the screen switcher sits alone in the title bar (macOS 14 has no SwiftUI call for it).
private struct HiddenWindowTitle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.titleVisibility = .hidden }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Says the device's readable settings differ from the app's, lists them, and offers both ways to match.
private struct DeviceDiffersButton: View {
    @Environment(AppModel.self) private var app
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Label("Device differs", systemImage: "arrow.left.arrow.right").labelStyle(.titleAndIcon).font(.caption)
        }
        .foregroundStyle(Theme.yellow)
        .help("The device reports settings that differ from this app")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("The \(app.session.model.name) differs from this app").font(.headline)
                ForEach(app.deviceDifferences, id: \.self) { Text($0).font(.callout) }
                Text("Mix levels and routing can't be read without measuring, so they may differ too.")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
                HStack {
                    Button("Read from device") { open = false; Task { await app.readFromDevice() } }
                        .help("Load the device's settings into the app. Measuring the mixes mutes the outputs for about 10 seconds.")
                    Button("Save app setup to device") { open = false; Task { await app.saveToDevice() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 380)
        }
    }
}
