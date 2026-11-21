import Foundation
import Testing
@testable import ScarlettKit

@Test func modelTables() {
    let byID = Dictionary(uniqueKeysWithValues: DeviceModel.all.map { ($0.productID, $0) })
    #expect(byID.keys.sorted() == [0x8002, 0x8004, 0x800C, 0x8012, 0x8014])
    #expect(DeviceModel.scarlett6i6.value(of: .analog(1)) == 12)
    #expect(DeviceModel.scarlett6i6.value(of: .mix(0)) == 18)
    #expect(DeviceModel.scarlett6i6.allSources.count == 27)
    #expect(DeviceModel.scarlett8i6.allSources.count == 25)
    #expect(DeviceModel.scarlett18i6.allSources.count == 31)
    #expect(DeviceModel.scarlett18i20.allSources.count == 47)
    #expect(DeviceModel.scarlett18i20.value(of: .spdif(1)) == 28)
    #expect(DeviceModel.scarlett18i8.mixerInputSources.count == 27)
    #expect(DeviceModel.scarlett6i6.mixerInputSources.count == 19)
    #expect(DeviceModel.scarlett6i6.defaultMixerInputs.map { DeviceModel.scarlett6i6.value(of: $0) } ==
        [12, 13, 14, 15, 16, 17, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    #expect(DeviceModel.scarlett18i6.defaultMixerInputs.map { DeviceModel.scarlett18i6.value(of: $0) } ==
        [6, 7, 8, 9, 10, 11, 12, 13, 16, 17, 18, 19, 20, 21, 14, 15, 0, 1])
    #expect(DeviceModel.scarlett18i20.defaultMixerInputs.map { DeviceModel.scarlett18i20.value(of: $0) } ==
        [20, 21, 22, 23, 24, 25, 26, 27, 30, 31, 32, 33, 34, 35, 28, 29, 0, 1])
    #expect(DeviceModel.scarlett6i6.gainInputs == [3, 4])
}

@Test func everyModelDefaultsAreValid() {
    for m in DeviceModel.all {
        let s = MixerState.defaults(for: m)
        #expect(s.matches(m), "\(m.name)")
        #expect(!s.allRequests(for: m).contains { $0.index >> 8 == 0x29 })
    }
}

@Test func hiGainRequest() {
    #expect(Gen1Protocol.hiGain(input: 3, on: true) ==
        ControlRequest(requestType: 0x21, request: 0x01, value: 0x0803, index: 0x0100, data: [1, 0], length: 2))
    let m = DeviceModel.scarlett6i6
    var s = MixerState.defaults(for: m); s.hiGain[4] = true
    #expect(s.allRequests(for: m).contains(Gen1Protocol.hiGain(input: 4, on: true)))
}

@Test func mixerInputsCannotBeMixes() {
    var s = MixerState.defaults(for: .scarlett18i8)
    s.mixerInputs[0] = .mix(0)
    #expect(!s.matches(.scarlett18i8))
}

@Test func unknownProductHasNoModel() {
    for id: UInt16 in [0x8000, 0x8201, 0x0000, 0x8203] { #expect(DeviceModel.model(productID: id) == nil) }
    for m in DeviceModel.all { #expect(DeviceModel.model(productID: m.productID)?.name == m.name) }
}
