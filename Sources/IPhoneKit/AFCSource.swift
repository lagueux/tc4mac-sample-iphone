import Foundation

/// Reaches a connected iPhone or iPad over **AFC** — the file protocol the
/// device actually speaks on the cable — by driving the libimobiledevice
/// tools as subprocesses, the same pattern tc4mac's SFTP backend uses with
/// the system's OpenSSH.
///
/// This replaced ImageCaptureCore (2026-08-01). ICC is a camera-IMPORT API:
/// it must enumerate the whole 31k-item roll before anything browses, which
/// took minutes per launch and read as broken. AFC is a real filesystem —
/// per-directory listing on demand (~0.2 s), file reads at cable speed, the
/// whole media tree (DCIM, Downloads, Books, recordings), and it works with
/// the phone LOCKED, because it rides the pairing the user already granted
/// to this Mac in Finder ("Trust This Computer").
public final class AFCSource: DeviceSource, @unchecked Sendable {
    /// Display name → udid, learned by `devices()`. Lock-guarded — requests
    /// run concurrently.
    private let lock = NSLock()
    private var udids: [String: String] = [:]

    public init() {}

    // MARK: - Tools

    /// A libimobiledevice tool: bundled beside the plugin executable when
    /// shipped, or the Homebrew/local install during development.
    static func tool(_ name: String) -> String? {
        var candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)"
        ]
        if let bundled = Bundle.main.executableURL?
            .deletingLastPathComponent().appendingPathComponent(name).path {
            candidates.insert(bundled, at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// One tool invocation. AFC operations are short (a listing ~0.2 s); a
    /// tool that hangs is killed rather than wedging the panel.
    static func run(
        _ toolName: String, _ arguments: [String], timeout: TimeInterval = 60
    ) async throws -> (output: Data, errorText: String) {
        guard let path = tool(toolName) else {
            throw AFCError.toolMissing(toolName)
        }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Drain concurrently with the run — a pipe filling up would deadlock.
        async let outData = out.fileHandleForReading.readToEndAsync()
        async let errData = err.fileHandleForReading.readToEndAsync()
        let output = await outData
        let errorText = String(data: await errData, encoding: .utf8) ?? ""
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            throw AFCError.failed(errorText.isEmpty
                ? "\(toolName) failed (\(process.terminationStatus))" : errorText)
        }
        return (output, errorText)
    }

    // MARK: - DeviceSource

    public func devices() async -> [String] {
        guard let listed = try? await Self.run("idevice_id", ["-l"], timeout: 15) else {
            return []
        }
        let ids = String(data: listed.output, encoding: .utf8)?
            .split(separator: "\n").map(String.init) ?? []
        var names: [String] = []
        for udid in ids {
            let name = (try? await Self.run(
                "ideviceinfo", ["-u", udid, "-k", "DeviceName"], timeout: 15))
                .flatMap { String(data: $0.output, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let display = (name?.isEmpty == false ? name! : udid)
            names.append(display)
            remember(display, udid: udid)
        }
        return names
    }

    public func items(onDevice device: String, at path: String) async throws -> [DeviceItem] {
        let udid = try await udid(for: device)
        let listing = try await Self.run(
            "afcclient", ["-u", udid, "--", "ls", "-l", Self.remote(path)])
        guard let text = String(data: listing.output, encoding: .utf8) else { return [] }
        return text.split(separator: "\n")
            .compactMap { AFCListing.parse(String($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func data(onDevice device: String, at path: String) async throws -> Data {
        let udid = try await udid(for: device)
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("afc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        _ = try await Self.run(
            "afcclient", ["-u", udid, "--", "get", Self.remote(path), local.path],
            timeout: 600)
        return try Data(contentsOf: local)
    }

    // MARK: - Helpers

    private func udid(for device: String) async throws -> String {
        if let known = cachedUDID(device) { return known }
        _ = await devices()
        guard let found = cachedUDID(device) else { throw AFCError.notConnected(device) }
        return found
    }

    private func cachedUDID(_ device: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return udids[device]
    }

    private func remember(_ device: String, udid: String) {
        lock.lock()
        defer { lock.unlock() }
        udids[device] = udid
    }

    private static func remote(_ path: String) -> String {
        path.isEmpty ? "/" : "/" + path
    }

    public enum AFCError: Error, LocalizedError {
        case toolMissing(String)
        case notConnected(String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing(let tool):
                return "The helper \(tool) is not installed — "
                    + "install libimobiledevice (brew install libimobiledevice)."
            case .notConnected(let name): return "\(name) is not connected."
            case .failed(let text):
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }
}

/// One `ls -l` line, e.g.
/// `-rw-r--r--    1 mobile mobile    2094466 12 Jul 2021 13:28:13 IMG_0028.HEIC`
/// Pure, so the odd cases (names with spaces, directories, links) are pinned
/// by tests without a phone.
public enum AFCListing {
    public static func parse(_ line: String) -> DeviceItem? {
        // [0] mode, [1] links, [2] user, [3] group, [4] size,
        // [5] day, [6] month, [7] year, [8] time, [9…] name.
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 10, let size = Int64(fields[4]) else { return nil }
        // The name is everything from field 9 on — rejoined, because names
        // may contain spaces.
        let name = fields[9...].joined(separator: " ")
        guard name != ".", name != ".." else { return nil }
        let isFolder = fields[0].hasPrefix("d")
        let stamp = dateFormatter.date(
            from: "\(fields[5]) \(fields[6]) \(fields[7]) \(fields[8])")
        return DeviceItem(
            name: name, isFolder: isFolder,
            size: isFolder ? nil : size, created: stamp, handle: name)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy HH:mm:ss"
        return formatter
    }()
}

private extension FileHandle {
    func readToEndAsync() async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? self.readToEnd()) ?? Data())
            }
        }
    }
}
