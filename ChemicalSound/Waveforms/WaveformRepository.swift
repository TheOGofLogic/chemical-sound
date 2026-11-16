import AVFAudio
import Foundation

public final class WaveformRepository: @unchecked Sendable {
    public let assetsDirectoryURL: URL
    private let verifier: SHA256Verifier
    private let lock = NSLock()
    private var cachedManifest: WaveformManifest?

    public init(
        assetsDirectoryURL: URL? = nil,
        verifier: SHA256Verifier = SHA256Verifier()
    ) {
        if let assetsDirectoryURL {
            self.assetsDirectoryURL = assetsDirectoryURL
        } else if let bundleResourceURL = Bundle.main.resourceURL {
            let nested = bundleResourceURL.appendingPathComponent("Assets", isDirectory: true)
            self.assetsDirectoryURL = FileManager.default.fileExists(atPath: nested.path)
                ? nested
                : bundleResourceURL
        } else {
            self.assetsDirectoryURL = URL(fileURLWithPath: "Assets", isDirectory: true)
        }
        self.verifier = verifier
    }

    public func manifestURL() -> URL {
        assetsDirectoryURL.appendingPathComponent("waveform_manifest.json")
    }

    public func loadManifest() throws -> WaveformManifest {
        lock.lock()
        if let cachedManifest {
            lock.unlock()
            return cachedManifest
        }
        lock.unlock()

        let url = manifestURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AcquisitionFailure.manifestInvalid("waveform_manifest.json not found at \(url.path)")
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AcquisitionFailure.manifestInvalid("Unable to read waveform_manifest.json: \(error)")
        }

        let manifest: WaveformManifest
        do {
            manifest = try JSONDecoder().decode(WaveformManifest.self, from: data)
        } catch {
            throw AcquisitionFailure.manifestInvalid("Invalid JSON structure: \(error)")
        }

        guard !manifest.assets.isEmpty else {
            throw AcquisitionFailure.manifestInvalid("Manifest contains zero waveform assets.")
        }

        lock.lock()
        cachedManifest = manifest
        lock.unlock()
        return manifest
    }

    @discardableResult
    public func verifyAllAssets() throws -> WaveformManifest {
        let manifest = try loadManifest()
        for asset in manifest.assets {
            let fileURL = assetsDirectoryURL.appendingPathComponent(asset.filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw AcquisitionFailure.waveformMissing(asset.filename)
            }
            do {
                try verifier.verify(asset: asset, at: fileURL)
            } catch let AssetVerificationError.placeholderDigest(id) {
                throw AcquisitionFailure.manifestInvalid("Placeholder SHA-256 on \(id)")
            } catch AssetVerificationError.digestMismatch {
                throw AcquisitionFailure.checksumMismatch(assetID: asset.assetID)
            } catch {
                throw AcquisitionFailure.waveformMissing(asset.filename)
            }
        }
        return manifest
    }

    public func assetMetadata(assetID: String) throws -> WaveformAsset {
        let manifest = try loadManifest()
        guard let asset = manifest.asset(withID: assetID) else {
            throw AcquisitionFailure.waveformMissing(assetID)
        }
        return asset
    }

    public func assetURL(assetID: String) throws -> URL {
        let asset = try assetMetadata(assetID: assetID)
        let url = assetsDirectoryURL.appendingPathComponent(asset.filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AcquisitionFailure.waveformMissing(asset.filename)
        }
        try verifier.verify(asset: asset, at: url)
        return url
    }

    public func audioFile(assetID: String) throws -> AVAudioFile {
        let url = try assetURL(assetID: assetID)
        do {
            return try AVAudioFile(forReading: url)
        } catch {
            throw AcquisitionFailure.audioEngineFailure("Failed opening \(url.lastPathComponent): \(error)")
        }
    }
}
