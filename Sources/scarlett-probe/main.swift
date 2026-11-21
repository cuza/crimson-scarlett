import Foundation
import ScarlettKit

// Command-line checks against a real device.
// Usage: scarlett-probe status | meters | pad <n> <on|off> | send-all [state.json] | save

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let (model, device) = DeviceModel.all.lazy
    .compactMap({ m in USBDevice(vendorID: 0x1235, productID: m.productID).map { (m, $0) } }).first
else { fail("No supported device found") }

do {
    switch args.first {
    case "status":
        let sync = try device.send(Gen1Protocol.syncStatus())
        print(model.name)
        print("sync:", sync.map { String(format: "%02x", $0) }.joined(separator: " "))
    case "meters":
        for bank in MeterBank.allCases {
            let bytes = try device.send(Gen1Protocol.meters(bank, count: model.meterCount(bank)))
            let raw = stride(from: 0, to: bytes.count - 1, by: 2).map { Int(bytes[$0]) | Int(bytes[$0 + 1]) << 8 }
            let db = MeterLevels.decode(bytes, fullScale: model.meterFullScale)
            print("\(bank):", zip(raw, db).map { String(format: "%d (%.1f)", $0, $1) }.joined(separator: " "))
        }
    case "pad" where args.count == 3:
        guard let n = Int(args[1]), model.padInputs.contains(n), ["on", "off"].contains(args[2])
        else { fail("usage: pad <input> <on|off>") }
        _ = try device.send(Gen1Protocol.pad(input: n, on: args[2] == "on"))
        print("pad \(n) \(args[2])")
    case "send-all":
        let state = try args.count > 1
            ? StateStore.load(from: URL(fileURLWithPath: args[1])) : MixerState.defaults(for: model)
        guard state.matches(model) else { fail("That file is not a setup for the \(model.name).") }
        let requests = state.allRequests(for: model)
        for r in requests { _ = try device.send(r) }
        print("\(requests.count) requests sent")
    case "save":
        _ = try device.send(Gen1Protocol.saveToDevice())
        print("saved to device")
    default:
        fail("usage: scarlett-probe status | meters | pad <n> <on|off> | send-all [state.json] | save")
    }
} catch {
    fail("error: \(error)")
}
