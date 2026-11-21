/// One USB Audio Class 2.0 control request on endpoint 0.
public struct ControlRequest: Equatable, Hashable, Sendable {
    public var requestType: UInt8
    public var request: UInt8
    public var value: UInt16
    public var index: UInt16
    /// Bytes to send. Empty for reads.
    public var data: [UInt8]
    /// Bytes to send or to read back.
    public var length: UInt16

    public init(requestType: UInt8, request: UInt8, value: UInt16, index: UInt16, data: [UInt8], length: UInt16) {
        self.requestType = requestType
        self.request = request
        self.value = value
        self.index = index
        self.data = data
        self.length = length
    }

    public struct Key: Hashable, Sendable {
        let requestType: UInt8, request: UInt8, index: UInt16, value: UInt16
    }

    /// Identifies the control, so a newer write can replace a pending one.
    public var key: Key { Key(requestType: requestType, request: request, index: index, value: value) }

    public var isRead: Bool { requestType & 0x80 != 0 }
}
