import Foundation
import OSLog

public actor AppTelemetry {
    public static let shared = AppTelemetry()
    public static let subsystem = "com.woni.KNUSwimWatcher"

    private let fileManager: FileManager
    private let directoryURL: URL
    private let activeLogURL: URL
    private let maximumBytes = 1_000_000
    private let retainedFiles = 3
    private var prepared = false

    public init(
        fileManager: FileManager = .default,
        directoryURL: URL = AppTelemetry.defaultLogDirectory
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
        activeLogURL = directoryURL.appending(path: "watcher.log")
    }

    public static var defaultLogDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/KNUSwimWatcher", directoryHint: .isDirectory)
    }

    public func info(
        _ category: String,
        _ event: String,
        fields: [String: String] = [:]
    ) {
        record(level: "INFO", category: category, event: event, fields: fields)
    }

    public func error(
        _ category: String,
        _ event: String,
        fields: [String: String] = [:]
    ) {
        record(level: "ERROR", category: category, event: event, fields: fields)
    }

    public func debug(
        _ category: String,
        _ event: String,
        fields: [String: String] = [:]
    ) {
        record(level: "DEBUG", category: category, event: event, fields: fields)
    }

    private func record(
        level: String,
        category: String,
        event: String,
        fields: [String: String]
    ) {
        let safeCategory = sanitize(category)
        let safeEvent = sanitize(event)
        let safeFields = fields
            .sorted { $0.key < $1.key }
            .map { "\(sanitize($0.key))=\(sanitize($0.value))" }
            .joined(separator: " ")
        let message = safeFields.isEmpty ? safeEvent : "\(safeEvent) \(safeFields)"
        let logger = Logger(subsystem: Self.subsystem, category: safeCategory)

        switch level {
        case "ERROR":
            logger.error("\(message, privacy: .public)")
        case "DEBUG":
            logger.debug("\(message, privacy: .public)")
        default:
            logger.info("\(message, privacy: .public)")
        }

        let timestamp = Self.timestampFormatter.string(from: Date())
        append("\(timestamp) \(level) [\(safeCategory)] \(message)\n")
    }

    private func append(_ line: String) {
        do {
            try prepareIfNeeded()
            try rotateIfNeeded(adding: line.utf8.count)
            guard let data = line.data(using: .utf8) else { return }
            let handle = try FileHandle(forWritingTo: activeLogURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            Logger(subsystem: Self.subsystem, category: "Telemetry")
                .error("file_log_write_failed type=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func prepareIfNeeded() throws {
        guard !prepared else { return }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !fileManager.fileExists(atPath: activeLogURL.path) {
            fileManager.createFile(
                atPath: activeLogURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        prepared = true
    }

    private func rotateIfNeeded(adding byteCount: Int) throws {
        let attributes = try? fileManager.attributesOfItem(atPath: activeLogURL.path)
        let currentSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize + byteCount > maximumBytes else { return }

        let oldest = directoryURL.appending(path: "watcher.log.\(retainedFiles)")
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        if retainedFiles > 1 {
            for index in stride(from: retainedFiles - 1, through: 1, by: -1) {
                let source = directoryURL.appending(path: "watcher.log.\(index)")
                let destination = directoryURL.appending(path: "watcher.log.\(index + 1)")
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.moveItem(at: source, to: destination)
                }
            }
        }
        try fileManager.moveItem(
            at: activeLogURL,
            to: directoryURL.appending(path: "watcher.log.1")
        )
        fileManager.createFile(
            atPath: activeLogURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
    }

    private func sanitize(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .prefix(240)
            .description
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
