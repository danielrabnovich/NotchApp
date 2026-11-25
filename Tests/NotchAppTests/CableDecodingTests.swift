import Foundation
import Testing
@testable import NotchApp

/// The cable test's decoding of a USB-C e-marker (SOP' Discover Identity, USB PD 3.x), checked
/// against cables measured on a real Mac (see the cable notes): ID header, cert stat, product, cable VDO.
@MainActor
struct CableDecodingTests {
    /// A cable VDO from its fields: speed 2:0, current 6:5 (1 = 3 A, 2 = 5 A), max voltage 10:9
    /// (0 = 20 V … 3 = 50 V), latency 16:13, EPR 17.
    private func cableVDO(speed: UInt32, current: UInt32, volts: UInt32, latency: UInt32, epr: Bool) -> UInt32 {
        speed | current << 5 | volts << 9 | latency << 13 | (epr ? 1 << 17 : 0)
    }

    /// The ID header: product type 29:27 (3 passive, 4 active), vendor ID 15:0.
    private func header(active: Bool, vendor: UInt32) -> UInt32 { (active ? 4 : 3) << 27 | vendor }

    @Test func eprCableIs240Watts() throws {
        // Insignia 240 W: passive, 5 A, 50 V, EPR, USB 2 data, latency 3.
        let vdos = [header(active: false, vendor: 0x1234), 0x0000_1A2B, 0, cableVDO(speed: 0, current: 2, volts: 3, latency: 3, epr: true)]
        let cable = try #require(CableMonitor.cable([:], vdos))
        #expect(!cable.active)
        #expect(cable.amps == 5)
        #expect(cable.maxVolts == 50)
        #expect(cable.epr)
        #expect(cable.watts == 240)
        #expect(cable.speed == 0)
        #expect(cable.length == 3)
        #expect(cable.headline == "240 W · USB 2")
        #expect(cable.certified)
    }

    @Test func appleBasicCableIs100Watts() throws {
        // Apple's basic cable: VID 05AC, passive, 5 A, 20 V, USB 2, latency 1.
        let vdos = [header(active: false, vendor: 0x05AC), 1, 0, cableVDO(speed: 0, current: 2, volts: 0, latency: 1, epr: false)]
        let cable = try #require(CableMonitor.cable(["Vendor ID": 0x05AC, "Product ID": 0x1689], vdos))
        #expect(cable.watts == 100)
        #expect(cable.maker == "Apple")
        #expect(cable.productID == 0x1689)
    }

    @Test func uncertifiedUSB4Cable() throws {
        // The AliExpress "240W/40G" cable: XID 0, 5 A / 50 V / EPR, USB4 Gen3 (40 Gb/s).
        let vdos = [header(active: false, vendor: 0x315C), 0, 0, cableVDO(speed: 3, current: 2, volts: 3, latency: 1, epr: true)]
        let cable = try #require(CableMonitor.cable([:], vdos))
        #expect(!cable.certified)
        #expect(cable.speedLabel == "40 Gb/s")
        #expect(cable.watts == 240)
        #expect(cable.vendorID == 0x315C) // from the header when the metadata has none
    }

    @Test func threeAmpCableAndActiveCablesHaveNoLength() throws {
        let vdos = [header(active: true, vendor: 0x2109), 1, 0, cableVDO(speed: 2, current: 1, volts: 0, latency: 5, epr: false)]
        let cable = try #require(CableMonitor.cable([:], vdos))
        #expect(cable.active)
        #expect(cable.amps == 3)
        #expect(cable.watts == 60)
        #expect(cable.length == nil)
    }

    @Test func tooFewVDOsIsNoCable() {
        #expect(CableMonitor.cable([:], [1, 2, 3]) == nil)
    }

    @Test func vdoBytesAreLittleEndian() {
        let meta: [String: Any] = ["VDOs": [Data([0x78, 0x56, 0x34, 0x12]), Data([1, 0, 0, 0]), Data([0xFF])]]
        #expect(CableMonitor.vdos(meta) == [0x1234_5678, 1, 0])
        #expect(CableMonitor.vdos([:]) == nil)
    }

    // MARK: - The verdict

    private func port(cableSpeed: Int, partnerSpeed: Int?, link: CableMonitor.Link?, usb4Failed: Bool = false) -> CableMonitor.Port {
        var port = CableMonitor.Port(id: "p", number: 1)
        let vdos = [header(active: false, vendor: 1), 1, 0, cableVDO(speed: UInt32(cableSpeed), current: 2, volts: 0, latency: 1, epr: false)]
        port.cable = CableMonitor.cable([:], vdos)
        port.partner = CableMonitor.Partner(name: "iPad", vendorID: nil, speed: partnerSpeed, isCharger: false)
        port.link = link
        port.usb4Failed = usb4Failed
        return port
    }

    @Test func linkCodesFollowTheRate() {
        #expect(CableMonitor.Link.usb2.code == 0)
        #expect(CableMonitor.Link.usb3(bitsPerSecond: 5e9).code == 1)
        #expect(CableMonitor.Link.usb3(bitsPerSecond: 10e9).code == 2)
        #expect(CableMonitor.Link.usb4(bitsPerSecond: 40e9).code == 3)
        #expect(CableMonitor.Link.usb4(bitsPerSecond: 80e9).code == 4)
        #expect(CableMonitor.Link.usb4(bitsPerSecond: 20e9).code == 2)
    }

    @Test func slowLinkIsTheSlowerEndNotTheCable() {
        // A 40 Gb/s cable to a 10 Gb/s phone at 10 Gb/s: as fast as it can go.
        let phone = port(cableSpeed: 3, partnerSpeed: 2, link: .usb3(bitsPerSecond: 10e9))
        #expect(phone.expectedLinkCode == 2)
        #expect(!phone.slowLink)
        #expect(CableMonitor.verdict(phone) == "iPad at 10 Gb/s, its top speed")
        // The same at 480 Mb/s: short.
        let short = port(cableSpeed: 3, partnerSpeed: 2, link: .usb2)
        #expect(short.slowLink)
        #expect(CableMonitor.verdict(short) == "iPad at 480 Mb/s · both ends can do 20 Gb/s")
    }

    @Test func failedUSB4IsCalledOut() {
        // The iPad over the uncertified cable: USB4 provisioned, never active, left at USB 2.
        let ipad = port(cableSpeed: 3, partnerSpeed: 3, link: .usb2, usb4Failed: true)
        #expect(ipad.slowLink)
        #expect(CableMonitor.verdict(ipad) == "iPad at 480 Mb/s · USB4 didn't come up")
    }
}
