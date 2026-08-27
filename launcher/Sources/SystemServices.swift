import CryptoKit
import Darwin
import Foundation

enum SystemServices {
    static func loadManifest(from url: URL) throws -> ReleaseManifest {
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(ReleaseManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    static func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw LauncherError.integrity("Could not open \(url.lastPathComponent)")
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw stream.streamError ?? LauncherError.integrity("Could not read \(url.lastPathComponent)")
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0 ..< count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        captureOutput: Bool = true,
        log: URL? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let outputPipe = Pipe()
        if captureOutput {
            process.standardOutput = outputPipe
            process.standardError = outputPipe
        } else if let log {
            let handle = try appendHandle(for: log)
            process.standardOutput = handle
            process.standardError = handle
        }
        try process.run()
        process.waitUntilExit()
        let output: String
        if captureOutput {
            output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        } else {
            output = ""
        }
        guard process.terminationStatus == 0 else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw LauncherError.process(detail.isEmpty
                ? "Command \(executable.lastPathComponent) exited with status \(process.terminationStatus)"
                : detail)
        }
        return output
    }

    static func appendHandle(for url: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    static func appendLog(_ message: String, to url: URL) {
        do {
            let handle = try appendHandle(for: url)
            defer { try? handle.close() }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            try handle.write(
                contentsOf: Data(
                    "[\(timestamp)] [\(MacticianIdentity.loggingSubsystem)] \(message)\n".utf8
                )
            )
        } catch {
            // Logging must never block launch or expose guest output elsewhere.
        }
    }

    static func loadState(from url: URL) -> InstallState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder.launcher.decode(InstallState.self, from: data),
              state.schemaVersion == 1 else {
            return InstallState()
        }
        return state
    }

    static func saveState(_ state: InstallState, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var updated = state
        updated.updatedAt = Date()
        let data = try JSONEncoder.launcher.encode(updated)
        try data.write(to: url, options: .atomic)
    }

    static func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func checkHost(minimumFreeBytes: Int64, root: URL) throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 12 else {
            throw LauncherError.preflight("macOS 12 or newer is required")
        }
        let architecture = try run(URL(fileURLWithPath: "/usr/bin/uname"), ["-m"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard architecture == "arm64" else {
            throw LauncherError.preflight("This launcher supports Apple Silicon Macs only")
        }
        guard ProcessInfo.processInfo.physicalMemory >= 7 * 1024 * 1024 * 1024 else {
            throw LauncherError.preflight("Mactician requires a Mac with at least 8 GB of memory")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let freeBytes = try availableBytes(at: root)
        guard freeBytes >= minimumFreeBytes else {
            let required = ByteCountFormatter.string(fromByteCount: minimumFreeBytes, countStyle: .file)
            let available = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            throw LauncherError.preflight("Not enough disk space: \(required) required, \(available) available")
        }
        let hypervisor = try run(URL(fileURLWithPath: "/usr/sbin/sysctl"), ["-n", "kern.hv_support"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard hypervisor == "1" else {
            throw LauncherError.preflight("Hypervisor Framework is unavailable")
        }
    }
}

extension JSONEncoder {
    fileprivate static var launcher: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    fileprivate static var launcher: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
