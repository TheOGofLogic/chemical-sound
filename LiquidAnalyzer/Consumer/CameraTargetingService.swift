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
    private var lastFrameCaptureUptime: TimeInterval = 0
    private var isConfigured = false

    func start(onStatusUpdate: @escaping @Sendable (Bool) -> Void) {
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
                    self.session.addInput(input)

                    self.videoOutput.alwaysDiscardsLateVideoFrames = true
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

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - lastFrameCaptureUptime) >= 0.45,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        lastFrameCaptureUptime = now

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
        let extent = ciImage.extent
        guard extent.width > 0, extent.height > 0 else { return }

        let side = min(extent.width, extent.height)
        let cropRect = CGRect(
            x: extent.midX - side * 0.5,
            y: extent.midY - side * 0.5,
            width: side,
            height: side
        )
        let scale = min(1.0, 320.0 / side)
        let scaled = ciImage.cropped(to: cropRect).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }

        let jpeg = UIImage(cgImage: cgImg).jpegData(compressionQuality: 0.72)
        if let jpeg {
            frameLock.lock()
            cachedThumbnailJPEG = jpeg
            frameLock.unlock()
        }
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

/// Manages camera preview for visual targeting on the AIM screen.
/// Uses silent video-frame caching (zero shutter sound, zero blocking continuations) and never touches AVAudioSession.
@MainActor
public final class CameraTargetingService: ObservableObject {
    @Published public private(set) var isCameraLive: Bool = false

    #if os(iOS)
    private let worker = CameraSessionWorker()
    #endif

    public init() {}

    public func startCamera() {
        #if os(iOS)
        worker.start { [weak self] live in
            Task { @MainActor [weak self] in
                self?.isCameraLive = live
            }
        }
        #else
        isCameraLive = false
        #endif
    }

    public func stopCamera() {
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
