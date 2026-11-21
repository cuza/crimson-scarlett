import Foundation
import IOKit
import IOKit.usb

/// Reports when a supported device of one vendor appears or goes away, with its product ID.
/// Runs on the main run loop and reports a device that is already attached at start.
public final class DeviceWatcher {
    private let onChange: @Sendable (_ productID: UInt16, _ attached: Bool) -> Void
    private let port: IONotificationPortRef
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0

    public init(vendorID: UInt16, onChange: @escaping @Sendable (_ productID: UInt16, _ attached: Bool) -> Void) {
        self.onChange = onChange
        port = IONotificationPortCreate(kIOMainPortDefault)
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .commonModes)

        let me = Unmanaged.passUnretained(self).toOpaque()
        func matching() -> CFDictionary {
            let d = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            // USB matching ignores a vendor ID on its own. A zero product mask matches every product.
            d[kUSBVendorID] = Int(vendorID)
            d[kUSBProductID] = 0
            d["idProductMask"] = 0
            return d
        }
        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, matching(), { ref, it in
            Unmanaged<DeviceWatcher>.fromOpaque(ref!).takeUnretainedValue().drain(it, attached: true)
        }, me, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, matching(), { ref, it in
            Unmanaged<DeviceWatcher>.fromOpaque(ref!).takeUnretainedValue().drain(it, attached: false)
        }, me, &removed)
        drain(added, attached: true)
        drain(removed, attached: false)
    }

    deinit {
        IOObjectRelease(added)
        IOObjectRelease(removed)
        IONotificationPortDestroy(port)
    }

    private func drain(_ iterator: io_iterator_t, attached: Bool) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let product = IORegistryEntryCreateCFProperty(service, kUSBProductID as CFString, nil, 0)?
                .takeRetainedValue() as? Int
            guard let product, DeviceModel.model(productID: UInt16(product)) != nil else { continue }
            onChange(UInt16(product), attached)
        }
    }
}
