import Combine
import Foundation
import SwiftUI

#if os(iOS)
import AVFoundation
import CoreImage
import UIKit

public final class CameraPreviewUIView: UIView {
    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    public var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = videoPreviewLayer.connection {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) {
                    connection.videoRotationAngle = 90
                }
            }
        }
    }
}

private final class CameraSessionWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "org.liquidanalyzer.camera.session")
    private let sampleQueue = DispatchQueue(label: "org.liquidanalyzer.camera.frames")
    private let ciContext = CIContext()
    private let frameLock = NSLock()

    private var cachedThumbnailJPEG: Data?
    private var cachedSceneContextJPEG: Data?
    private var videoDevice: AVCaptureDevice?
    private var opticsLocked: Bool = false
    private var lastThumbnailUptime: TimeInterval = 0
    private var lastAnalysisUptime: TimeInterval = 0
    private var previousLumaGrid: [Double]?
    private var steadyScore: Double = 0.0
    private var autoLockEnabledAfterUptime: TimeInterval = 0
    private var didFireLockForCurrentSession = false
    private var isConfigured = false

    var onTargetProgress: (@Sendable (Double, Bool) -> Void)?

    func start(
        graceDelaySeconds: Double,
        onStatusUpdate: @escaping @Sendable (Bool) -> Void
    ) {
        frameLock.lock()
        previousLumaGrid = nil
        steadyScore = 0.0
        didFireLockForCurrentSession = false
        autoLockEnabledAfterUptime = ProcessInfo.processInfo.systemUptime + graceDelaySeconds
        frameLock.unlock()

        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        switch authStatus {
        case .authorized:
            configureAndRun(onStatusUpdate: onStatusUpdate)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    self?.configureAndRun(onStatusUpdate: onStatusUpdate)
                } else {
                    onStatusUpdate(false)
                }
            }
        default:
            onStatusUpdate(false)
        }
    }

    private func configureAndRun(onStatusUpdate: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.session.beginConfiguration()
                // Critical: prevent AVCaptureSession from touching or interrupting AVAudioSession!
                self.session.automaticallyConfiguresApplicationAudioSession = false
                self.session.sessionPreset = .high

                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.videoDevice = device
                    self.session.addInput(input)

                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
                    self.videoOutput.videoSettings = [
                        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
                    ]
                    self.videoOutput.setSampleBufferDelegate(self, queue: self.sampleQueue)
                    if self.session.canAddOutput(self.videoOutput) {
                        self.session.addOutput(self.videoOutput)
                    }
                    self.isConfigured = true
                }
                self.session.commitConfiguration()
            }

            guard self.isConfigured else {
                onStatusUpdate(false)
                return
            }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            onStatusUpdate(true)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func latestThumbnailJPEG() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return cachedThumbnailJPEG
    }

    func latestSceneContextJPEG() -> Data? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return cachedSceneContextJPEG
    }

    func setOpticsLocked(_ locked: Bool, completion: @escaping @Sendable (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else {
                completion(false)
                return
            }
            do {
                try device.lockForConfiguration()
                if locked {
                    if device.isFocusModeSupported(.locked) {
                        device.focusMode = .locked
                    }
                    if device.isExposureModeSupported(.locked) {
                        device.exposureMode = .locked
                    }
                    if device.isWhiteBalanceModeSupported(.locked) {
                        device.whiteBalanceMode = .locked
                    }
                    self.opticsLocked = true
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    self.opticsLocked = false
                }
                device.unlockForConfiguration()
                completion(self.opticsLocked)
            } catch {
                completion(self.opticsLocked)
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - lastAnalysisUptime) >= 0.16,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        lastAnalysisUptime = now

        // 1. Fast 16x16 center-reticle steadiness & multi-quadrant container contrast check
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let basePtr = CVPixelBufferGetBaseAddress(pixelBuffer)

        var currentGrid = [Double](repeating: 0.0, count: 256)
        var meanLuma = 0.0

        if let basePtr, width >= 64, height >= 64 {
            let bytes = basePtr.assumingMemoryBound(to: UInt8.self)
            let roiX0 = width / 4
            let roiY0 = height / 4
            let roiW = width / 2
            let roiH = height / 2

            for gy in 0..<16 {
                let py = roiY0 + (gy * roiH) / 16
                let rowOffset = py * bytesPerRow
                for gx in 0..<16 {
                    let px = roiX0 + (gx * roiW) / 16
                    let offset = rowOffset + px * 4
                    let b = Double(bytes[offset]) / 255.0
                    let g = Double(bytes[offset + 1]) / 255.0
                    let r = Double(bytes[offset + 2]) / 255.0
                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    currentGrid[gy * 16 + gx] = luma
                    meanLuma += luma
                }
            }
            meanLuma /= 256.0
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)

        // Require multi-quadrant 2D container structure for auto-lock so aiming at a bare wall does not auto-fire
        var gradientSum = 0.0
        var quadrantContrast = [Double](repeating: 0.0, count: 4)
        for gy in 0..<15 {
            for gx in 0..<15 {
                let c = currentGrid[gy * 16 + gx]
                let dx = abs(currentGrid[gy * 16 + (gx + 1)] - c)
                let dy = abs(currentGrid[(gy + 1) * 16 + gx] - c)
                let g = dx + dy
                gradientSum += g
                let qIdx = (gy >= 8 ? 2 : 0) + (gx >= 8 ? 1 : 0)
                quadrantContrast[qIdx] += g
            }
        }
        let spatialContrast = gradientSum / (2.0 * 225.0)
        let activeQuadrants = quadrantContrast.filter { ($0 / 112.0) >= 0.018 }.count

        frameLock.lock()
        let prev = previousLumaGrid
        previousLumaGrid = currentGrid
        let armed = now >= autoLockEnabledAfterUptime
        let alreadyFired = didFireLockForCurrentSession

        var motionDiff = 1.0
        if let prev, prev.count == 256 {
            var diffSum = 0.0
            for i in 0..<256 {
                diffSum += abs(currentGrid[i] - prev[i])
            }
            motionDiff = diffSum / 256.0
        }

        // Steady hand + multi-quadrant container contrast (prevents auto-triggering on blank walls)
        let isSteadyOnTarget = armed && meanLuma > 0.06 && spatialContrast > 0.022 && activeQuadrants >= 3 && motionDiff < 0.044
        if isSteadyOnTarget {
            steadyScore = min(1.0, steadyScore + 0.22)
        } else {
            steadyScore = max(0.0, steadyScore - 0.30)
        }

        let currentScore = steadyScore
        var fireNow = false
        if currentScore >= 1.0 && !alreadyFired {
            didFireLockForCurrentSession = true
            fireNow = true
        }
        let callback = onTargetProgress
        frameLock.unlock()

        callback?(currentScore, fireNow)

        // 2. Refresh both center reticle thumbnail AND full wide-angle scene context (~every 0.38 s)
        guard (now - lastThumbnailUptime) >= 0.38 else { return }
        lastThumbnailUptime = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        // A) Center square reticle crop (320x320) for UI thumbnail & inner meniscus colorimetry
        let side = min(extent.width, extent.height)
        let cropRect = CGRect(
            x: extent.midX - side * 0.5,
            y: extent.midY - side * 0.5,
            width: side,
            height: side
        )
        let thumbScale = min(1.0, 320.0 / side)
        let scaledThumb = ciImage.cropped(to: cropRect).transformed(by: CGAffineTransform(scaleX: thumbScale, y: thumbScale))

        // B) Full uncropped wide-angle frame (max dimension 640px) so Vision sees entire cup/mug/bowl rim or wall
        let maxDim = max(extent.width, extent.height)
        let fullScale = min(1.0, 640.0 / maxDim)
        let scaledFull = ciImage.transformed(by: CGAffineTransform(scaleX: fullScale, y: fullScale))

        let thumbJPEG = ciContext.createCGImage(scaledThumb, from: scaledThumb.extent)
            .flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.76) }
        let fullJPEG = ciContext.createCGImage(scaledFull, from: scaledFull.extent)
            .flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.72) }

        frameLock.lock()
        if let thumbJPEG { cachedThumbnailJPEG = thumbJPEG }
        if let fullJPEG { cachedSceneContextJPEG = fullJPEG }
        frameLock.unlock()
    }
}

public struct LiveCameraPreviewRepresentable: UIViewRepresentable {
    fileprivate let session: AVCaptureSession

    public func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    public func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
    }
}
#endif

/// Manages camera preview and automatic steady-target lock on the AIM screen.
/// Uses silent video-frame analysis (zero shutter sound) and never touches AVAudioSession.
@MainActor
public final class CameraTargetingService: ObservableObject {
    @Published public private(set) var isCameraLive: Bool = false
    @Published public private(set) var targetLockProgress: Double = 0.0
    @Published public private(set) var aimInstructionText: String = "Aim at the liquid"
    @Published public private(set) var isOpticsLocked: Bool = false

    public var onAutoTargetLocked: (() -> Void)?

    #if os(iOS)
    private let worker = CameraSessionWorker()
    #endif

    public init() {
        #if os(iOS)
        worker.onTargetProgress = { [weak self] progress, didLock in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.targetLockProgress = progress
                if didLock {
                    self.aimInstructionText = "Target Steady — Scanning..."
                    self.onAutoTargetLocked?()
                } else if progress >= 0.25 {
                    self.aimInstructionText = "Hold steady — locking target..."
                } else {
                    self.aimInstructionText = "Aim at the liquid"
                }
            }
        }
        #endif
    }

    public func startCamera(graceDelaySeconds: Double = 0.8) {
        targetLockProgress = 0.0
        aimInstructionText = "Aim at the liquid"
        #if os(iOS)
        worker.start(graceDelaySeconds: graceDelaySeconds) { [weak self] live in
            Task { @MainActor [weak self] in
                self?.isCameraLive = live
            }
        }
        #else
        isCameraLive = false
        #endif
    }

    public func stopCamera() {
        targetLockProgress = 0.0
        #if os(iOS)
        worker.stop()
        #endif
    }

    public func latestTargetingThumbnail() -> Data? {
        #if os(iOS)
        guard isCameraLive else { return nil }
        return worker.latestThumbnailJPEG()
        #else
        return nil
        #endif
    }

    public func latestSceneContextJPEG() -> Data? {
        #if os(iOS)
        guard isCameraLive else { return nil }
        return worker.latestSceneContextJPEG()
        #else
        return nil
        #endif
    }

    public func toggleOpticsLock() {
        let nextState = !isOpticsLocked
        #if os(iOS)
        worker.setOpticsLocked(nextState) { [weak self] actualLocked in
            Task { @MainActor [weak self] in
                self?.isOpticsLocked = actualLocked
            }
        }
        #else
        isOpticsLocked = nextState
        #endif
    }

    @ViewBuilder
    public var previewLayerView: some View {
        #if os(iOS)
        if isCameraLive {
            LiveCameraPreviewRepresentable(session: worker.session)
        } else {
            StudioCameraFallbackBackdrop()
        }
        #else
        StudioCameraFallbackBackdrop()
        #endif
    }
}

/// Clean ambient studio glass backdrop displayed when running in Simulator or without camera access.
public struct StudioCameraFallbackBackdrop: View {
    public init() {}

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.88, green: 0.90, blue: 0.93),
                    Color(red: 0.78, green: 0.82, blue: 0.87),
                    Color(red: 0.93, green: 0.94, blue: 0.96)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.65),
                                Color(red: 0.85, green: 0.87, blue: 0.90)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: 190)
            }

            LiquidGlassPreviewArtwork(size: 185)
                .offset(y: -18)
        }
    }
}
