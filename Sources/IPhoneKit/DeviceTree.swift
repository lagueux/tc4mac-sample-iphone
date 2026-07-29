import Foundation

/// The shape of what a connected device offers, independent of how it is
/// reached. Keeping it separate is what makes the interesting parts testable
/// without an iPhone plugged in.
public struct DeviceItem: Sendable, Equatable {
    public var name: String
    public var isFolder: Bool
    public var size: Int64?
    public var created: Date?
    /// Identifies the item to the transport that produced it.
    public var handle: String

    public init(
        name: String, isFolder: Bool, size: Int64? = nil, created: Date? = nil,
        handle: String = ""
    ) {
        self.name = name
        self.isFolder = isFolder
        self.size = size
        self.created = created
        self.handle = handle
    }
}

/// What a device source must answer. `ImageCaptureSource` is the real one;
/// tests use a fixture, which is the only way to exercise the path layout
/// without hardware.
public protocol DeviceSource: Sendable {
    /// Connected devices, by display name.
    func devices() async -> [String]
    /// Items directly inside `path` on `device` ("" is the device's root).
    func items(onDevice device: String, at path: String) async throws -> [DeviceItem]
    /// The bytes of one item.
    func data(onDevice device: String, at path: String) async throws -> Data
}

/// Turns the plugin's flat paths into device-and-path pairs. An iPhone's
/// photos arrive as one namespace per device, so the first component names
/// the device and the rest is a path inside it.
public enum DevicePath {
    /// "/iPhone/DCIM/IMG_0001.HEIC" → ("iPhone", "DCIM/IMG_0001.HEIC")
    public static func split(_ path: String) -> (device: String?, inner: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard let device = parts.first else { return (nil, "") }
        return (device, parts.dropFirst().joined(separator: "/"))
    }

    /// Rejects anything that would climb out of a device's namespace.
    public static func isSafe(_ path: String) -> Bool {
        !path.split(separator: "/").contains("..")
    }
}
