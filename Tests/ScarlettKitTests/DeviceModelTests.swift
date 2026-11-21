import Testing
@testable import ScarlettKit

@Test func sourceValues18i8() {
    let m = DeviceModel.scarlett18i8
    #expect(m.value(of: .off) == -1)
    #expect(m.value(of: .pcm(1)) == 0)
    #expect(m.value(of: .analog(1)) == 8)
    #expect(m.value(of: .spdif(2)) == 17)
    #expect(m.value(of: .adat(1)) == 18)
    #expect(m.value(of: .mix(0)) == 26)
    #expect(m.value(of: .mix(7)) == 33)
    #expect(m.allSources.count == 35)
    for s in m.allSources { #expect(m.source(forValue: m.value(of: s)) == s) }
}

@Test func defaultMixerInputsMatchLinuxInit() {
    let m = DeviceModel.scarlett18i8
    #expect(m.defaultMixerInputs.map { m.value(of: $0) } ==
        [8, 9, 10, 11, 12, 13, 14, 15, 18, 19, 20, 21, 22, 23, 16, 17, 0, 1])
}

@Test func lookupByProductID() {
    #expect(DeviceModel.model(productID: 0x8014)?.name == "Scarlett 18i8")
    #expect(DeviceModel.model(productID: 0x8204) == nil)
}

@Test func sourceNames() {
    #expect(Source.off.name == "Off")
    #expect(Source.spdif(2).name == "S/PDIF 2")
    #expect(Source.mix(0).name == "Mix A")
}
