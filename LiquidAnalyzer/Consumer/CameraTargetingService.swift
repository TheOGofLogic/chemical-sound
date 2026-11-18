import Combine
import Foundation
import SwiftUI

#if os(iOS)
import AVFoundation
import UIKit

public final class CameraPreviewUIView: UIView {
    public override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    public var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        // swiftlint:disable:next force_cast
        layer as! AVCaptureVideoPreviewLayer
    }
}

private final class CameraSessionWorker: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "org.liquidanalyzer.camera.session")
    private var isConfigured = false
    private var pendingPhotoContinuation: CheckedContinuation<Data?, Never>?

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
        queue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                    if self.session.canAddOutput(self.photoOutput) {
                        self.session.addOutput(self.photoOutput)
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
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func captureSnapshot() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, self.isConfigured, self.session.isRunning else {
                    continuation.resume(returning: nil)
                    return
                }
                if let previous = self.pendingPhotoContinuation {
                    self.pendingPhotoContinuation = nil
                    previous.resume(returning: nil)
                }
                self.pendingPhotoContinuation = continuation
                let settings = AVCapturePhotoSettings()
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let rawData = (error == nil) ? photo.fileDataRepresentation() : nil
        let compressed: Data?
        if let rawData, let image = UIImage(data: rawData) {
            compressed = Self.downsampledJPEGData(from: image, maxDimension: 360)
        } else {
            compressed = nil
        }

        queue.async { [weak self] in
            guard let self, let cont = self.pendingPhotoContinuation else { return }
            self.pendingPhotoContinuation = nil
            cont.resume(returning: compressed)
        }
    }

    private static func downsampledJPEGData(from image: UIImage, maxDimension: CGFloat) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image.jpegData(compressionQuality: 0.72) }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let targetSize = CGSize(width: round(size.width * scale), height: round(size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return scaled.jpegData(compressionQuality: 0.75)
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
/// Acoustic measurements—not the camera image—provide the analysis signal.
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

    public func captureTargetingThumbnail() async -> Data? {
        #if os(iOS)
        guard isCameraLive else { return nil }
        return await worker.captureSnapshot()
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
