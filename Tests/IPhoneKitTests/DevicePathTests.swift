import Foundation
@testable import IPhoneKit
import Testing

@Suite("Device paths")
struct DevicePathTests {
    @Test("the first component names the device, the rest is the path inside")
    func splitting() {
        let root = DevicePath.split("/")
        #expect(root.device == nil)

        let device = DevicePath.split("/Thierry's iPhone")
        #expect(device.device == "Thierry's iPhone")
        #expect(device.inner.isEmpty)

        let file = DevicePath.split("/Thierry's iPhone/DCIM/IMG_0001.HEIC")
        #expect(file.device == "Thierry's iPhone")
        #expect(file.inner == "DCIM/IMG_0001.HEIC")
    }

    @Test("a path cannot climb out of the device it names")
    func traversal() {
        #expect(DevicePath.isSafe("/iPhone/DCIM/IMG_0001.HEIC"))
        #expect(!DevicePath.isSafe("/iPhone/../../etc/passwd"))
        #expect(!DevicePath.isSafe("/../secret"))
    }
}
