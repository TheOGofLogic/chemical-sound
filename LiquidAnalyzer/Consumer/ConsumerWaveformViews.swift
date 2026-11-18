import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Brand Color Palette (Blue = Scan, Green = Result, Orange = Composition, Purple/Rainbow = Tune)

public enum LiquidAnalyzerPalette {
    public static let headerNavy = Color(red: 0.04, green: 0.09, blue: 0.18)
    public static let deepSpaceStart = Color(red: 0.03, green: 0.06, blue: 0.13)
    public static let deepSpaceEnd = Color(red: 0.06, green: 0.12, blue: 0.24)

    public static let scanBlue = Color(red: 0.08, green: 0.52, blue: 0.98)
    public static let scanCyan = Color(red: 0.18, green: 0.78, blue: 1.00)

    public static let resultGreenStart = Color(red: 0.09, green: 0.65, blue: 0.31)
    public static let resultGreenEnd = Color(red: 0.16, green: 0.76, blue: 0.40)

    public static let compositionOrange = Color(red: 0.95, green: 0.45, blue: 0.09)
    public static let compositionWarmBg = Color(red: 1.00, green: 0.97, blue: 0.93)

    public static let tunePurple = Color(red: 0.52, green: 0.23, blue: 0.95)
    public static let tuneMagenta = Color(red: 0.88, green: 0.18, blue: 0.62)
}

// MARK: - Brand Droplet + Acoustic Waveform Emblem (Matches Poster Header Logo)

public struct WaterDropSoundLogoView: View {
    public let size: CGFloat

    public init(size: CGFloat = 58) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            WaterDropletShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.16, green: 0.84, blue: 1.00),
                            Color(red: 0.05, green: 0.48, blue: 0.96)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.82, height: size)
                .shadow(color: LiquidAnalyzerPalette.scanBlue.opacity(0.32), radius: 10, y: 5)

            // Five crisp white vertical acoustic bars inside droplet
            HStack(alignment: .center, spacing: size * 0.055) {
                ForEach([0.16, 0.30, 0.44, 0.28, 0.15], id: \.self) { ratio in
                    Capsule(style: .continuous)
                        .fill(Color.white)
                        .frame(width: max(2.5, size * 0.06), height: size * CGFloat(ratio))
                }
            }
            .offset(y: size * 0.11)
        }
        .frame(width: size, height: size)
    }
}

private struct WaterDropletShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var p = Path()
        p.move(to: CGPoint(x: w * 0.5, y: 0))
        p.addCurve(
            to: CGPoint(x: w, y: h * 0.64),
            control1: CGPoint(x: w * 0.72, y: h * 0.25),
            control2: CGPoint(x: w, y: h * 0.45)
        )
        p.addArc(
            center: CGPoint(x: w * 0.5, y: h * 0.64),
            radius: w * 0.5,
            startAngle: .degrees(0),
            endAngle: .degrees(180),
            clockwise: false
        )
        p.addCurve(
            to: CGPoint(x: w * 0.5, y: 0),
            control1: CGPoint(x: 0, y: h * 0.45),
            control2: CGPoint(x: w * 0.28, y: h * 0.25)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - 1. AIM Screen Targeting Frame (`[   ]`) with Live Target-Lock Glow

public struct TargetingReticleView: View {
    public let lockProgress: Double
    @State private var pulse = false

    public init(lockProgress: Double = 0.0) {
        self.lockProgress = lockProgress
    }

    public var body: some View {
        let isLocking = lockProgress >= 0.25
        let primaryColor = isLocking ? LiquidAnalyzerPalette.resultGreenEnd : LiquidAnalyzerPalette.scanCyan
        let secondaryColor = isLocking ? LiquidAnalyzerPalette.scanCyan : LiquidAnalyzerPalette.scanBlue

        ZStack {
            // Subtle inner glow guide
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(primaryColor.opacity(isLocking ? 0.55 : (pulse ? 0.28 : 0.12)), lineWidth: isLocking ? 2.2 : 1.5)
                .scaleEffect(isLocking ? (1.0 - CGFloat(lockProgress) * 0.03) : (pulse ? 1.015 : 0.99))
                .animation(.easeOut(duration: 0.16), value: lockProgress)

            // Four clean rounded corner brackets matching the mockup
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let arm: CGFloat = 38
                let r: CGFloat = 16

                Path { path in
                    // Top-left
                    path.move(to: CGPoint(x: 0, y: arm))
                    path.addLine(to: CGPoint(x: 0, y: r))
                    path.addQuadCurve(to: CGPoint(x: r, y: 0), control: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: arm, y: 0))

                    // Top-right
                    path.move(to: CGPoint(x: w - arm, y: 0))
                    path.addLine(to: CGPoint(x: w - r, y: 0))
                    path.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0))
                    path.addLine(to: CGPoint(x: w, y: arm))

                    // Bottom-left
                    path.move(to: CGPoint(x: 0, y: h - arm))
                    path.addLine(to: CGPoint(x: 0, y: h - r))
                    path.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h))
                    path.addLine(to: CGPoint(x: arm, y: h))

                    // Bottom-right
                    path.move(to: CGPoint(x: w - arm, y: h))
                    path.addLine(to: CGPoint(x: w - r, y: h))
                    path.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h))
                    path.addLine(to: CGPoint(x: w, y: h - arm))
                }
                .stroke(
                    LinearGradient(
                        colors: [primaryColor, secondaryColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: primaryColor.opacity(0.65), radius: 9)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

// MARK: - 2. SCANNING Screen Concentric Neon-Blue Acoustic Sonar & Waveform

public struct BlueScanningSonarView: View {
    public init() {}

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                // Outer radial blue bloom
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                LiquidAnalyzerPalette.scanBlue.opacity(0.32),
                                LiquidAnalyzerPalette.scanCyan.opacity(0.10),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 135
                        )
                    )
                    .frame(width: 270, height: 270)

                // Expanding sonar rings
                ForEach(0..<3, id: \.self) { ring in
                    let phase = (t * 0.65 + Double(ring) * 0.33).truncatingRemainder(dividingBy: 1.0)
                    Circle()
                        .stroke(
                            LiquidAnalyzerPalette.scanCyan.opacity((1.0 - phase) * 0.55),
                            lineWidth: 2.0
                        )
                        .frame(width: 145 + CGFloat(phase) * 95, height: 145 + CGFloat(phase) * 95)
                }

                // Glowing main acoustic circle
                Circle()
                    .stroke(
                        LinearGradient(
                            colors: [LiquidAnalyzerPalette.scanCyan, LiquidAnalyzerPalette.scanBlue],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 3.5
                    )
                    .frame(width: 176, height: 176)
                    .shadow(color: LiquidAnalyzerPalette.scanCyan.opacity(0.7), radius: 14)

                // Animated 13-bar acoustic waveform inside circle
                HStack(alignment: .center, spacing: 6) {
                    ForEach(0..<13, id: \.self) { idx in
                        let centerDist = abs(Double(idx) - 6.0) / 6.0
                        let envelope = max(0.18, 1.0 - centerDist * centerDist * 0.82)
                        let wave = 0.55 + 0.45 * sin(t * 6.2 + Double(idx) * 0.65)
                        let barHeight = CGFloat(14.0 + 74.0 * envelope * wave)

                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.white, LiquidAnalyzerPalette.scanCyan],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 5.0, height: barHeight)
                            .shadow(color: LiquidAnalyzerPalette.scanCyan.opacity(0.85), radius: 6)
                    }
                }
            }
        }
    }
}

// MARK: - 3. CHEMICAL TUNE Rainbow Spectrum Waveform

public struct RainbowChemicalTuneWaveformView: View {
    public let isPlaying: Bool
    public let seedFrequencyHz: Double

    public init(isPlaying: Bool, seedFrequencyHz: Double = 2_150.0) {
        self.isPlaying = isPlaying
        self.seedFrequencyHz = seedFrequencyHz
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying)) { timeline in
            let t = isPlaying ? timeline.date.timeIntervalSinceReferenceDate : 1.25
            let barCount = 33
            let seedPhase = (seedFrequencyHz / 400.0).truncatingRemainder(dividingBy: 6.28)

            ZStack {
                // Soft rainbow ambient glow behind waveform
                LinearGradient(
                    colors: [
                        Color(hue: 0.56, saturation: 0.90, brightness: 0.95).opacity(0.22),
                        Color(hue: 0.36, saturation: 0.85, brightness: 0.95).opacity(0.18),
                        Color(hue: 0.13, saturation: 0.92, brightness: 0.98).opacity(0.18),
                        Color(hue: 0.86, saturation: 0.88, brightness: 0.96).opacity(0.24)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blur(radius: 28)
                .frame(height: 150)

                // Horizontal center axis shimmer
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.35), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1.5)

                HStack(alignment: .center, spacing: 5) {
                    ForEach(0..<barCount, id: \.self) { idx in
                        let frac = Double(idx) / Double(barCount - 1)
                        let hue = Self.rainbowHue(for: frac)
                        let barColor = Color(hue: hue, saturation: 0.86, brightness: 1.0)

                        // Multi-lobed harmonic envelope resembling the mockup's rainbow spectrum
                        let packetA = exp(-pow((frac - 0.22) / 0.14, 2))
                        let packetB = exp(-pow((frac - 0.50) / 0.16, 2))
                        let packetC = exp(-pow((frac - 0.78) / 0.14, 2))
                        let baseShape = min(1.0, 0.20 + 0.85 * max(packetA, max(packetB * 1.08, packetC)))

                        let motion = isPlaying
                            ? (0.48 + 0.52 * abs(sin(t * 4.4 + Double(idx) * 0.48 + seedPhase)))
                            : (0.58 + 0.32 * abs(sin(Double(idx) * 0.62 + seedPhase)))

                        let height = CGFloat(max(12.0, 152.0 * baseShape * motion))

                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        barColor.opacity(0.92),
                                        .white.opacity(0.92),
                                        barColor.opacity(0.92)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 4.5, height: height)
                            .shadow(color: barColor.opacity(0.80), radius: 7)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private static func rainbowHue(for fraction: Double) -> Double {
        // Maps 0.0 -> 1.0 smoothly from Indigo/Blue (0.63) -> Cyan (0.52) -> Green (0.35) -> Gold/Orange (0.11) -> Pink/Purple (0.86)
        if fraction < 0.25 {
            let u = fraction / 0.25
            return 0.64 - u * 0.13 // Blue -> Cyan
        } else if fraction < 0.50 {
            let u = (fraction - 0.25) / 0.25
            return 0.51 - u * 0.18 // Cyan -> Green
        } else if fraction < 0.75 {
            let u = (fraction - 0.50) / 0.25
            return 0.33 - u * 0.24 // Green -> Yellow/Orange
        } else {
            let u = (fraction - 0.75) / 0.25
            let raw = 0.09 - u * 0.24
            return raw < 0.0 ? raw + 1.0 : raw // Orange -> Magenta/Violet
        }
    }
}

// MARK: - 4. Stylized Crystal Liquid Glass Illustration & Cross-Platform Photo Thumbnail

public struct LiquidGlassPreviewArtwork: View {
    public let size: CGFloat

    public init(size: CGFloat = 120) {
        self.size = size
    }

    public var body: some View {
        ZStack {
            // Subtle contact shadow
            Ellipse()
                .fill(Color.black.opacity(0.14))
                .frame(width: size * 0.66, height: size * 0.11)
                .offset(y: size * 0.45)

            // Outer tapered tumbler glass
            TaperedGlassShape(insetRatio: 0.10)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.82),
                            Color(red: 0.85, green: 0.92, blue: 0.98).opacity(0.55),
                            Color.white.opacity(0.75)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: size * 0.68, height: size * 0.86)

            // Liquid column inside glass
            TaperedGlassShape(insetRatio: 0.08)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.74, green: 0.90, blue: 1.00).opacity(0.78),
                            Color(red: 0.52, green: 0.79, blue: 0.98).opacity(0.62),
                            Color(red: 0.82, green: 0.94, blue: 1.00).opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size * 0.60, height: size * 0.58)
                .offset(y: size * 0.08)

            // Meniscus highlight
            Ellipse()
                .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
                .background(Ellipse().fill(Color(red: 0.86, green: 0.95, blue: 1.00).opacity(0.65)))
                .frame(width: size * 0.59, height: size * 0.08)
                .offset(y: -size * 0.20)

            // Glass rim & specular edge
            TaperedGlassShape(insetRatio: 0.10)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.58, green: 0.68, blue: 0.78),
                            Color.white,
                            Color(red: 0.55, green: 0.65, blue: 0.76)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.0
                )
                .frame(width: size * 0.68, height: size * 0.86)
        }
        .frame(width: size, height: size)
    }
}

private struct TaperedGlassShape: Shape {
    let insetRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let dx = rect.width * insetRatio
        var p = Path()
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: 0))
        p.addLine(to: CGPoint(x: rect.width - dx, y: rect.height))
        p.addLine(to: CGPoint(x: dx, y: rect.height))
        p.closeSubpath()
        return p
    }
}

public struct PlatformThumbnailView: View {
    public let jpegData: Data?
    public let size: CGFloat

    public init(jpegData: Data?, size: CGFloat = 112) {
        self.jpegData = jpegData
        self.size = size
    }

    public var body: some View {
        Group {
            #if canImport(UIKit)
            if let jpegData, let uiImg = UIImage(data: jpegData) {
                Image(uiImage: uiImg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
            } else {
                LiquidGlassPreviewArtwork(size: size)
            }
            #elseif canImport(AppKit)
            if let jpegData, let nsImg = NSImage(data: jpegData) {
                Image(nsImage: nsImg)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                LiquidGlassPreviewArtwork(size: size)
            }
            #else
            LiquidGlassPreviewArtwork(size: size)
            #endif
        }
    }
}
