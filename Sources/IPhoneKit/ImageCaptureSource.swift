import Foundation
import ImageCaptureCore

/// Reaches a connected iPhone or iPad through **ImageCaptureCore**, the same
/// framework Image Capture and Photos use.
///
/// This is what macOS actually offers a third party: the device's camera
/// roll — DCIM and whatever else the device publishes as media. There is no
/// general file system access to an iPhone without libimobiledevice and a
/// USB muxd conversation, which is a dependency and a maintenance burden a
/// sample should not carry. So the plugin is honest about its scope: photos
/// and videos, browsable and copyable, and nothing it cannot deliver.
public actor ImageCaptureSource: NSObject, DeviceSource {
    private var browser: ICDeviceBrowser?
    private var opened: [String: ICCameraDevice] = [:]

    public override init() {
        super.init()
    }

    /// Starts the browser and lets devices arrive. ImageCaptureCore reports
    /// asynchronously, so a short settle beats an empty first answer.
    public func devices() async -> [String] {
        let browser = self.browser ?? ICDeviceBrowser()
        self.browser = browser
        if !browser.isBrowsing {
            browser.browsedDeviceTypeMask = ICDeviceTypeMask(
                rawValue: ICDeviceTypeMask.camera.rawValue
                    | ICDeviceLocationTypeMask.local.rawValue)!
            browser.start()
            try? await Task.sleep(for: .seconds(2))
        }
        return (browser.devices ?? []).compactMap(\.name)
    }

    public func items(onDevice device: String, at path: String) async throws -> [DeviceItem] {
        guard let camera = try await open(device) else { throw DeviceError.notConnected(device) }
        let media = camera.mediaFiles ?? []
        // A camera reports a flat list; the folder each file belongs to is
        // the shape the panel wants, so it is derived here.
        if path.isEmpty {
            let folders = Set(media.compactMap { ($0 as? ICCameraFile)?.parentFolder?.name })
            return folders.sorted().map { DeviceItem(name: $0, isFolder: true, handle: $0) }
        }
        return media.compactMap { item in
            guard let file = item as? ICCameraFile,
                  file.parentFolder?.name == path else { return nil }
            return DeviceItem(
                name: file.name ?? "?", isFolder: false,
                size: Int64(file.fileSize), created: file.creationDate,
                handle: file.name ?? "")
        }.sorted { $0.name < $1.name }
    }

    public func data(onDevice device: String, at path: String) async throws -> Data {
        guard let camera = try await open(device) else { throw DeviceError.notConnected(device) }
        let name = (path as NSString).lastPathComponent
        guard let file = (camera.mediaFiles ?? []).compactMap({ $0 as? ICCameraFile })
            .first(where: { $0.name == name }) else {
            throw DeviceError.notFound(path)
        }
        // ImageCaptureCore hands the bytes to a callback; the continuation
        // is what turns that into something the plugin can await.
        return try await withCheckedThrowingContinuation { continuation in
            file.requestReadData(atOffset: 0, length: Int64(file.fileSize)) { data, error in
                if let data {
                    continuation.resume(returning: data)
                    return
                }
                continuation.resume(throwing: error ?? DeviceError.notFound(path))
            }
        }
    }

    private func open(_ name: String) async throws -> ICCameraDevice? {
        if let already = opened[name] { return already }
        guard let camera = (browser?.devices ?? [])
            .compactMap({ $0 as? ICCameraDevice })
            .first(where: { $0.name == name }) else { return nil }
        // Opening is a real handshake with the device, not a flag.
        try await camera.requestOpenSession()
        opened[name] = camera
        return camera
    }

    public enum DeviceError: Error {
        case notConnected(String)
        case notFound(String)
    }
}
