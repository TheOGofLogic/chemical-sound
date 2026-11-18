import Foundation

/// Atomic persistence store for raw WAV files and CSRD-P1 `scans.jsonl` records.
public actor AcquisitionStore {
    public let rootDirectoryURL: URL
    private let shaVerifier = SHA256Verifier()
    private var recordsBySession: [String: [AcquisitionRecord]] = [:]

    public init(rootDirectoryURL: URL? = nil) {
        if let rootDirectoryURL {
            self.rootDirectoryURL = rootDirectoryURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootDirectoryURL = docs.appendingPathComponent("LiquidAnalyzerSessions", isDirectory: true)
        }
    }

    public func sessionDirectory(sessionID: String) throws -> URL {
        let safeID = Self.sanitizeFilename(sessionID)
        let url = rootDirectoryURL.appendingPathComponent(safeID, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public func verifySufficientStorage(minimumFreeBytes: Int64 = 50 * 1_024 * 1_024) throws {
        try FileManager.default.createDirectory(at: rootDirectoryURL, withIntermediateDirectories: true)
        if let values = try? rootDirectoryURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage,
           available < minimumFreeBytes {
            throw AcquisitionFailure.insufficientStorage
        }
    }

    public func recoverInterruptedTemporaryFiles(sessionID: String) throws -> Int {
        let dir = try sessionDirectory(sessionID: sessionID)
        let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        var removed = 0
        for item in items where item.lastPathComponent.hasSuffix(".tmp.wav") {
            try? FileManager.default.removeItem(at: item)
            removed += 1
        }
        return removed
    }

    public func temporaryRecordingURL(
        sessionID: String,
        sampleID: String,
        repetition: Int
    ) throws -> URL {
        let dir = try sessionDirectory(sessionID: sessionID)
        let base = "\(Self.sanitizeFilename(sampleID))_rep\(String(format: "%02d", repetition))"
        return dir.appendingPathComponent("\(base).tmp.wav")
    }

    /// Atomically promotes `.tmp.wav` to immutable `.wav` and returns `(filename, sha256)`.
    public func commitRecordingFile(
        temporaryURL: URL,
        sessionID: String,
        sampleID: String,
        repetition: Int
    ) throws -> (filename: String, sha256: String, finalURL: URL) {
        let dir = try sessionDirectory(sessionID: sessionID)
        let filename = "\(Self.sanitizeFilename(sampleID))_rep\(String(format: "%02d", repetition)).wav"
        let finalURL = dir.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            let digest = try shaVerifier.sha256Hex(of: finalURL)
            return (filename, digest, finalURL)
        } catch {
            throw AcquisitionFailure.fileWriteFailure("Atomic WAV commit failed: \(error)")
        }
    }

    public func appendScanRecord(_ record: AcquisitionRecord, sessionID: String) throws {
        var list = recordsBySession[sessionID] ?? []
        list.append(record)
        recordsBySession[sessionID] = list
        try writeScansJSONL(records: list, sessionID: sessionID)
    }

    public func updateSessionValidity(sessionID: String, sessionValidityState: String) throws {
        guard var list = recordsBySession[sessionID] else { return }
        for idx in list.indices {
            list[idx].sessionValidityState = sessionValidityState
            if list[idx].qualityStatus == "PROVISIONALLY_ACCEPTED" {
                switch sessionValidityState {
                case "SESSION_VALID":
                    list[idx].finalScanValidity = "FINAL_ACCEPTED"
                case "SESSION_DRIFT_INVALIDATED":
                    list[idx].finalScanValidity = "INVALID_MEASUREMENT"
                    if !list[idx].qualityFlags.contains(QualityFlag.calibrationDrift.rawValue) {
                        list[idx].qualityFlags.append(QualityFlag.calibrationDrift.rawValue)
                    }
                default:
                    list[idx].finalScanValidity = "PROVISIONALLY_ACCEPTED"
                }
            } else {
                list[idx].finalScanValidity = "INVALID_MEASUREMENT"
            }
        }
        recordsBySession[sessionID] = list
        try writeScansJSONL(records: list, sessionID: sessionID)
    }

    public func records(forSession sessionID: String) -> [AcquisitionRecord] {
        recordsBySession[sessionID] ?? []
    }

    private func writeScansJSONL(records: [AcquisitionRecord], sessionID: String) throws {
        let dir = try sessionDirectory(sessionID: sessionID)
        let jsonlURL = dir.appendingPathComponent("scans.jsonl")
        let encoder = JSONEncoder()

        var output = Data()
        for rec in records {
            let line = try encoder.encode(rec)
            output.append(line)
            output.append(0x0A)
        }
        do {
            try output.write(to: jsonlURL, options: .atomic)
        } catch {
            throw AcquisitionFailure.fileWriteFailure("Failed writing scans.jsonl: \(error)")
        }
    }

    private static func sanitizeFilename(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(cleaned)
        return result.isEmpty ? "UNNAMED" : result
    }
}
