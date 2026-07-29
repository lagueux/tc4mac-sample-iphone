import Foundation
import IPhoneKit
import TCPluginSDK

/// The plugin process: a file-system plugin whose namespace is the connected
/// devices. The top level lists devices, one level in lists the folders a
/// device publishes, and below that are its files.
struct Runner {
    private let source = ImageCaptureSource()
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private var buffer = Data()

    mutating func run() async {
        while let frame = nextFrame() {
            guard let request = try? JSONDecoder().decode(PluginWire.Request.self, from: frame)
            else { continue }
            await handle(request)
        }
    }

    private mutating func nextFrame() -> Data? {
        guard let header = read(4), let length = try? PluginWire.frameLength(header) else {
            return nil
        }
        return read(length)
    }

    private mutating func read(_ count: Int) -> Data? {
        while buffer.count < count {
            let chunk = input.availableData
            if chunk.isEmpty { return nil }
            buffer.append(chunk)
        }
        defer { buffer.removeFirst(count) }
        return Data(buffer.prefix(count))
    }

    private func handle(_ request: PluginWire.Request) async {
        do {
            switch request.method {
            case PluginWire.Method.hello:
                // Read-only, and it says so: the camera protocol offers no
                // way to write, and declaring otherwise would put commands
                // in front of the user that cannot work.
                try reply(request.id, PluginWire.Hello(
                    id: "com.tc4mac.sample.iphone",
                    displayName: "iPhone photos (sample)",
                    fileSystemCapabilities: 0))

            case PluginWire.Method.list:
                let ask: PluginPayload.Path = try decode(request)
                try reply(request.id, PluginPayload.Entries(entries: try await list(ask.path)))

            case PluginWire.Method.stat:
                let ask: PluginPayload.Path = try decode(request)
                let (device, inner) = DevicePath.split(ask.path)
                guard let device, !inner.isEmpty else {
                    try reply(request.id, PluginPayload.Entry(
                        name: (ask.path as NSString).lastPathComponent, isDirectory: true))
                    return
                }
                let parent = (inner as NSString).deletingLastPathComponent
                let name = (inner as NSString).lastPathComponent
                let items = try await source.items(onDevice: device, at: parent)
                guard let item = items.first(where: { $0.name == name }) else {
                    throw PluginError.notFound(ask.path)
                }
                try reply(request.id, PluginPayload.Entry(
                    name: item.name, isDirectory: item.isFolder,
                    size: item.size, modified: item.created))

            case PluginWire.Method.read:
                let ask: PluginPayload.Path = try decode(request)
                let (device, inner) = DevicePath.split(ask.path)
                guard let device, DevicePath.isSafe(ask.path) else {
                    throw PluginError.notFound(ask.path)
                }
                let data = try await source.data(onDevice: device, at: inner)
                // Chunked, so a large video does not become one enormous frame.
                let chunk = 256 * 1024
                var offset = 0
                repeat {
                    let end = min(offset + chunk, data.count)
                    try reply(
                        request.id, PluginPayload.Chunk(data: data.subdata(in: offset..<end)),
                        isFinal: end >= data.count)
                    offset = end
                } while offset < data.count

            default:
                try fail(request.id, .notSupported(request.method))
            }
        } catch let error as PluginError {
            try? fail(request.id, error)
        } catch {
            try? fail(request.id, .failed("\(error)"))
        }
    }

    private func list(_ path: String) async throws -> [PluginPayload.Entry] {
        guard DevicePath.isSafe(path) else { throw PluginError.notFound(path) }
        let (device, inner) = DevicePath.split(path)
        guard let device else {
            // The root of the plugin's namespace: the devices themselves.
            return await source.devices().map {
                PluginPayload.Entry(name: $0, isDirectory: true)
            }
        }
        return try await source.items(onDevice: device, at: inner).map {
            PluginPayload.Entry(
                name: $0.name, isDirectory: $0.isFolder, size: $0.size, modified: $0.created)
        }
    }

    private func decode<T: Decodable>(_ request: PluginWire.Request) throws -> T {
        try JSONDecoder().decode(T.self, from: request.payload)
    }

    private func reply<T: Encodable>(_ id: Int, _ value: T, isFinal: Bool = true) throws {
        try send(PluginWire.Response(
            id: id, payload: try JSONEncoder().encode(value), isFinal: isFinal))
    }

    private func fail(_ id: Int, _ error: PluginError) throws {
        try send(PluginWire.Response(id: id, error: PluginWire.ErrorPayload(error)))
    }

    private func send(_ response: PluginWire.Response) throws {
        try output.write(contentsOf: PluginWire.frame(try JSONEncoder().encode(response)))
    }
}

await Task {
    var runner = Runner()
    await runner.run()
}.value
