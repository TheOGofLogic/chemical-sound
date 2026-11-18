import XCTest
@testable import LiquidAnalyzer

final class ManifestVerificationTests: XCTestCase {
    func testBundledAssetsPassSHA256Verification() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let assetsDir = repoRoot.appendingPathComponent("Assets", isDirectory: true)

        let repository = WaveformRepository(assetsDirectoryURL: assetsDir)
        let manifest = try repository.verifyAllAssets()
        XCTAssertEqual(manifest.protocolID, "CS-P1-v1.2")
        XCTAssertEqual(manifest.sampleRateHz, 48_000)
        XCTAssertNotNil(manifest.asset(withID: "SIG_ESS_v1"))
        XCTAssertNotNil(manifest.asset(withID: "SIG_ESS_v1_inverse"))
        XCTAssertNotNil(manifest.asset(withID: "SIG_STEP_v1"))
        XCTAssertNotNil(manifest.asset(withID: "SIG_SIL_v1"))
    }

    func testPlaceholderDigestIsRejected() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS_PlaceholderTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dummyURL = tempDir.appendingPathComponent("SIG_ESS_v1.wav")
        try Data([0x00, 0x01, 0x02]).write(to: dummyURL)

        let asset = WaveformAsset(
            assetID: "SIG_ESS_v1",
            role: "excitation",
            filename: "SIG_ESS_v1.wav",
            sha256: "REPLACE_WITH_ACTUAL_LOWERCASE_SHA256",
            durationMs: 200,
            numFrames: 9_600,
            channels: 1,
            format: "PCM_FLOAT32"
        )

        XCTAssertThrowsError(try SHA256Verifier().verify(asset: asset, at: dummyURL))
    }

    func testTamperedWaveformTriggersChecksumMismatch() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CS_TamperTest_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = tempDir.appendingPathComponent("SIG_ESS_v1.wav")
        try Data("UntamperedAudioPayload".utf8).write(to: wavURL)
        let verifier = SHA256Verifier()
        let realDigest = try verifier.sha256Hex(of: wavURL)

        // Flip 1 byte
        try Data("TamperedAudioPayload!!".utf8).write(to: wavURL)

        let asset = WaveformAsset(
            assetID: "SIG_ESS_v1",
            role: "excitation",
            filename: "SIG_ESS_v1.wav",
            sha256: realDigest,
            durationMs: 200,
            numFrames: 9_600,
            channels: 1,
            format: "PCM_FLOAT32"
        )
        XCTAssertThrowsError(try verifier.verify(asset: asset, at: wavURL))
    }
}
