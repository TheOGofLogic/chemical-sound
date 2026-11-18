import Foundation

/// Packages and SHA-256-verifies an immutable CSRD-P1 directory bundle for Python ingestion.
public struct ExportManager: Sendable {
    private let verifier = SHA256Verifier()

    public init() {}

    public func exportSessionBundle(
        studyID: String,
        sessionID: String,
        sessionValidityState: String,
        protocolConfiguration: ResearchProtocol,
        baselineProfile: AudioRuntimeProfile?,
        sessionDirectoryURL: URL,
        auditLogURL: URL,
        waveformRepository: WaveformRepository,
        records: [AcquisitionRecord],
        exportRootURL: URL
    ) throws -> URL {
        let fm = FileManager.default
        let bundleName = "CSRD_P1_\(sessionID)"
        let bundleURL = exportRootURL.appendingPathComponent(bundleName, isDirectory: true)

        if fm.fileExists(atPath: bundleURL.path) {
            try fm.removeItem(at: bundleURL)
        }
        try fm.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        // 1. Copy scans.jsonl and raw WAV recordings while verifying each recording SHA-256
        let scansSource = sessionDirectoryURL.appendingPathComponent("scans.jsonl")
        guard fm.fileExists(atPath: scansSource.path) else {
            throw AcquisitionFailure.fileWriteFailure("Missing scans.jsonl in session directory.")
        }
        let scansDest = bundleURL.appendingPathComponent("scans.jsonl")
        try fm.copyItem(at: scansSource, to: scansDest)

        for rec in records {
            guard let wavName = rec.rawAudioFilename else { continue }
            let srcWav = sessionDirectoryURL.appendingPathComponent(wavName)
            guard fm.fileExists(atPath: srcWav.path) else {
                throw AcquisitionFailure.fileWriteFailure("Missing raw recording \(wavName) during export.")
            }
            let dstWav = bundleURL.appendingPathComponent(wavName)
            if !fm.fileExists(atPath: dstWav.path) {
                try fm.copyItem(at: srcWav, to: dstWav)
            }
            if let expectedSHA = rec.rawAudioSHA256 {
                let actualSHA = try verifier.sha256Hex(of: dstWav)
                guard actualSHA == expectedSHA.lowercased() else {
                    throw AcquisitionFailure.integrityFailure("Recording SHA-256 mismatch on export: \(wavName)")
                }
            }
        }

        // 2. Copy transition audit log if present
        if fm.fileExists(atPath: auditLogURL.path) {
            let auditDest = bundleURL.appendingPathComponent("transitions.jsonl")
            try fm.copyItem(at: auditLogURL, to: auditDest)
        }

        // 3. Copy verified excitation waveforms, inverse filter, and waveform_manifest.json
        let wfSubdir = bundleURL.appendingPathComponent("reference_waveforms", isDirectory: true)
        try fm.createDirectory(at: wfSubdir, withIntermediateDirectories: true)
        let wfManifest = try waveformRepository.verifyAllAssets()
        try fm.copyItem(
            at: waveformRepository.manifestURL(),
            to: wfSubdir.appendingPathComponent("waveform_manifest.json")
        )
        for asset in wfManifest.assets {
            let assetSrc = try waveformRepository.assetURL(assetID: asset.assetID)
            try fm.copyItem(at: assetSrc, to: wfSubdir.appendingPathComponent(asset.filename))
        }

        // 4. Compute SHA-256 checksums for every exported file and write bundle_manifest.json
        var checksums: [String: String] = [:]
        if let enumerator = fm.enumerator(at: bundleURL, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let isFile = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                if isFile {
                    let relPath = fileURL.path.replacingOccurrences(of: bundleURL.path + "/", with: "")
                    checksums[relPath] = try verifier.sha256Hex(of: fileURL)
                }
            }
        }

        let provCount = records.filter { $0.qualityStatus == "PROVISIONALLY_ACCEPTED" }.count
        let iso = ISO8601DateFormatter().string(from: Date())
        let manifest = BundleManifest(
            bundleVersion: "1.2.0",
            createdAtISO: iso,
            datasetVersion: protocolConfiguration.datasetVersion,
            specVersion: protocolConfiguration.specVersion,
            protocolConfiguration: protocolConfiguration,
            studyID: studyID,
            sessionID: sessionID,
            sessionValidityState: sessionValidityState,
            appVersion: baselineProfile?.appVersion ?? "0.3.0",
            operatingSystemVersion: baselineProfile?.iosVersion ?? ProcessInfo.processInfo.operatingSystemVersionString,
            baselineRuntimeProfile: baselineProfile,
            totalRecordedScans: records.count,
            provisionallyAcceptedScans: provCount,
            rejectedOrInvalidScans: records.count - provCount,
            fileChecksumsSHA256: checksums
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let manifestData = try encoder.encode(manifest)
        let manifestURL = bundleURL.appendingPathComponent("bundle_manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        return bundleURL
    }
}
