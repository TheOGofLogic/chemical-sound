import Foundation

public final class AuditLogger: @unchecked Sendable {
    private let lock = NSLock()
    public let logFileURL: URL
    private var records: [TransitionAuditRecord] = []
    private let encoder: JSONEncoder

    public init(logFileURL: URL? = nil) {
        if let logFileURL {
            self.logFileURL = logFileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.logFileURL = docs
                .appendingPathComponent("LiquidAnalyzerSessions", isDirectory: true)
                .appendingPathComponent("transitions.jsonl")
        }

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    public func append(_ record: TransitionAuditRecord) throws {
        lock.lock()
        defer { lock.unlock() }

        records.append(record)
        let dir = logFileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var lineData = try encoder.encode(record)
        lineData.append(0x0A)  // '\n'

        if FileManager.default.fileExists(atPath: logFileURL.path) {
            let handle = try FileHandle(forWritingTo: logFileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
        } else {
            try lineData.write(to: logFileURL, options: .atomic)
        }
    }

    public func allRecords() -> [TransitionAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }
}
