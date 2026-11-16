import CryptoKit
import Foundation

public enum AssetVerificationError: Error, Equatable, LocalizedError {
    case placeholderDigest(assetID: String)
    case unreadableAsset(String)
    case digestMismatch(assetID: String, expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .placeholderDigest(let id):
            return "Placeholder SHA-256 digest detected for asset '\(id)'."
        case .unreadableAsset(let name):
            return "Unable to open waveform asset '\(name)'."
        case .digestMismatch(let id, let expected, let actual):
            return "SHA-256 mismatch for '\(id)' (expected \(expected), actual \(actual))."
        }
    }
}

public struct SHA256Verifier: Sendable {
    public init() {}

    public func sha256Hex(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw AssetVerificationError.unreadableAsset(url.lastPathComponent)
        }

        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while stream.hasBytesAvailable {
            let count = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return stream.read(base, maxLength: ptr.count)
            }
            if count < 0 {
                throw AssetVerificationError.unreadableAsset(url.lastPathComponent)
            }
            if count == 0 {
                break
            }
            hasher.update(data: Data(buffer[0..<count]))
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public func verify(asset: WaveformAsset, at url: URL) throws {
        let normalizedExpected = asset.sha256.lowercased()
        let validHexChars = CharacterSet(charactersIn: "0123456789abcdef")

        guard normalizedExpected.count == 64,
              !normalizedExpected.contains("replace"),
              normalizedExpected.unicodeScalars.allSatisfy({ validHexChars.contains($0) }) else {
            throw AssetVerificationError.placeholderDigest(assetID: asset.assetID)
        }

        let actual = try sha256Hex(of: url)
        guard actual == normalizedExpected else {
            throw AssetVerificationError.digestMismatch(
                assetID: asset.assetID,
                expected: normalizedExpected,
                actual: actual
            )
        }
    }
}
