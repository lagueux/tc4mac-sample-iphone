import Foundation
import IPhoneKit
import TCPluginSDK

/// The plugin process: a file-system plugin whose namespace is the connected
/// devices. The top level lists devices, one level in lists the folders a
/// device publishes, and below that are its files.
///
/// Requests are served CONCURRENTLY: a streamed listing runs for as long as
/// the catalog builds, and the panel's stats must not queue behind it (they
/// timed out at 30 s each when they did — UAT 2026-08-01). Each request gets
/// its own task; frame WRITES are serialized by a lock so concurrent replies
/// interleave only at frame boundaries, which the host demultiplexes by id.
final class Runner: @unchecked Sendable {
    let source: any DeviceSource

    init(source: any DeviceSource) {
        self.source = source
    }

    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput
    private let writeLock = NSLock()
    private var buffer = Data()

    /// SDK 2 open reads: the downloaded temp file per handle. Requests run
    /// concurrently, so the table is lock-guarded.
    private let readersLock = NSLock()
    private var readers: [Int: (file: FileHandle, url: URL)] = [:]
    private var nextHandle = 0

    func run() {
        while let frame = nextFrame() {
            guard let request = try? JSONDecoder().decode(PluginWire.Request.self, from: frame)
            else { continue }
            Task { await self.handle(request) }
        }
    }

    private func nextFrame() -> Data? {
        guard let header = read(4), let length = try? PluginWire.frameLength(header) else {
            return nil
        }
        return read(length)
    }

    private func read(_ count: Int) -> Data? {
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
                // Read-only for now — AFC can write, and a later revision
                // may declare it; until then the UI must not offer commands
                // the plugin will refuse.
                try reply(request.id, PluginWire.Hello(
                    id: "com.tc4mac.sample.iphone",
                    displayName: "iPhone",
                    fileSystemCapabilities: 0))

            case PluginWire.Method.list:
                let ask: PluginPayload.Path = try decode(request)
                try await streamList(ask.path, id: request.id)

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

            // SDK 2: the host PULLS bytes a chunk at a time. The file is
            // downloaded once to a temp file and served from disk, so neither
            // this process nor tc4mac ever holds a large video in memory.
            case PluginWire.Method.openRead:
                let ask: PluginPayload.OpenRead = try decode(request)
                let (device, inner) = DevicePath.split(ask.path)
                guard let device, DevicePath.isSafe(ask.path) else {
                    throw PluginError.notFound(ask.path)
                }
                let local = try await source.download(onDevice: device, at: inner)
                let file: FileHandle
                do {
                    file = try FileHandle(forReadingFrom: local)
                    if ask.offset > 0 { try file.seek(toOffset: ask.offset) }
                } catch {
                    try? FileManager.default.removeItem(at: local)
                    throw error
                }
                try reply(request.id, PluginPayload.Handle(handle: register(file, local)))

            case PluginWire.Method.readChunk:
                let ask: PluginPayload.ReadChunk = try decode(request)
                guard let reader = reader(ask.handle) else { throw PluginError.notFound("handle") }
                let size = max(1, min(ask.maxBytes, PluginWire.maxChunkBytes))
                let bytes = try reader.file.read(upToCount: size) ?? Data()
                try reply(request.id, PluginPayload.Chunk(data: bytes))  // empty = end of file

            case PluginWire.Method.closeRead:
                let ask: PluginPayload.Handle = try decode(request)
                close(ask.handle)
                try send(PluginWire.Response(id: request.id))  // empty acknowledgement

            default:
                try fail(request.id, .notSupported(request.method))
            }
        } catch let error as PluginError {
            try? fail(request.id, error)
        } catch {
            // localizedDescription, not "\(error)": the panel footer shows
            // this text verbatim, and enum debug dumps belong in no UI.
            try? fail(request.id, .failed(error.localizedDescription))
        }
    }

    /// AFC answers a directory in ~0.2 s, so a listing is ONE reply — no
    /// streaming, no spinner. Deep paths are real directories now: the
    /// whole media tree (DCIM, Downloads, Books, recordings) browses.
    private func streamList(_ path: String, id: Int) async throws {
        guard DevicePath.isSafe(path) else { throw PluginError.notFound(path) }
        let (device, inner) = DevicePath.split(path)
        guard let device else {
            // The root of the plugin's namespace: the devices themselves.
            let found = await source.devices()
            guard !found.isEmpty else {
                throw PluginError.failed(
                    "No iPhone is reachable. Connect it with a cable "
                        + "and trust this Mac on the phone, then open this again.")
            }
            try reply(id, PluginPayload.Entries(entries: found.map {
                PluginPayload.Entry(name: $0, isDirectory: true)
            }))
            return
        }
        let items = try await source.items(onDevice: device, at: inner)
        try reply(id, PluginPayload.Entries(entries: items.map {
            PluginPayload.Entry(
                name: $0.name, isDirectory: $0.isFolder,
                size: $0.size, modified: $0.created)
        }))
    }

    private func register(_ file: FileHandle, _ url: URL) -> Int {
        readersLock.lock()
        defer { readersLock.unlock() }
        nextHandle += 1
        readers[nextHandle] = (file, url)
        return nextHandle
    }

    private func reader(_ handle: Int) -> (file: FileHandle, url: URL)? {
        readersLock.lock()
        defer { readersLock.unlock() }
        return readers[handle]
    }

    /// Closes the handle and deletes its temp file.
    private func close(_ handle: Int) {
        readersLock.lock()
        let reader = readers.removeValue(forKey: handle)
        readersLock.unlock()
        guard let reader else { return }
        try? reader.file.close()
        try? FileManager.default.removeItem(at: reader.url)
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

    /// Whole frames only, under the lock: concurrent handlers may interleave
    /// FRAMES on the pipe, never bytes within one.
    private func send(_ response: PluginWire.Response) throws {
        let frame = PluginWire.frame(try JSONEncoder().encode(response))
        writeLock.lock()
        defer { writeLock.unlock() }
        try output.write(contentsOf: frame)
    }
}

// AFC needs no run loop — every operation is a short tool invocation — but
// the main thread still parks in one so the frame loop owns its own thread.
let runner = Runner(source: AFCSource())
Task.detached {
    runner.run()
    exit(0)
}
RunLoop.main.run()
