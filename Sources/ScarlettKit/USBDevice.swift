import CUSB

/// Sends control requests to the device. Implementations block until the device answers.
public protocol ControlTransport: Sendable {
    /// Returns the bytes read for a read request, or an empty array for a write.
    func send(_ r: ControlRequest) throws -> [UInt8]
}

public enum USBError: Error, Equatable {
    case ioReturn(Int32)
    /// The session has no device, or dropped it while the request waited.
    case disconnected
    /// A request the device is known to choke on. Never sent.
    case unsafeRequest
}

/// A Scarlett reached through IOUSBLib. Callers send one request at a time.
public final class USBDevice: ControlTransport, @unchecked Sendable {
    private let handle: OpaquePointer

    public init?(vendorID: UInt16, productID: UInt16) {
        guard let h = cusb_open(vendorID, productID) else { return nil }
        handle = h
    }

    deinit { cusb_close(handle) }

    public func send(_ r: ControlRequest) throws -> [UInt8] {
        guard Gen1Protocol.isSafe(r) else { throw USBError.unsafeRequest }
        var buf = r.isRead ? [UInt8](repeating: 0, count: Int(r.length)) : r.data
        var done: UInt16 = 0
        let kr = buf.withUnsafeMutableBufferPointer {
            cusb_request(handle, r.requestType, r.request, r.value, r.index, $0.baseAddress, r.length, &done)
        }
        guard kr == 0 else { throw USBError.ioReturn(kr) }
        return r.isRead ? Array(buf.prefix(Int(done))) : []
    }
}
