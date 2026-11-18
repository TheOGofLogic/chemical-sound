import SwiftUI

/// Screen 4: Dedicated Chemical Tune player with rainbow animated waveform and Play / Pause controls.
public struct ChemicalTuneView: View {
    public let item: ConsumerScanItem
    @ObservedObject var tunePlayer: ChemicalTunePlayer
    public let onBack: () -> Void

    public init(
        item: ConsumerScanItem,
        tunePlayer: ChemicalTunePlayer,
        onBack: @escaping () -> Void
    ) {
        self.item = item
        self.tunePlayer = tunePlayer
        self.onBack = onBack
    }

    public var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.04, blue: 0.11),
                    Color(red: 0.05, green: 0.06, blue: 0.19),
                    Color(red: 0.03, green: 0.04, blue: 0.12)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Header Bar
                HStack {
                    Button(action: {
                        tunePlayer.stop()
                        onBack()
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Result")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Text("Chemical Tune")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    // Balancing spacer for centered title
                    Color.clear.frame(width: 58, height: 24)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Spacer(minLength: 16)

                // Rainbow Animated Waveform
                RainbowChemicalTuneWaveformView(
                    isPlaying: tunePlayer.isPlaying,
                    seedFrequencyHz: item.measuredPeakHz
                )
                .frame(height: 185)
                .padding(.horizontal, 8)

                Spacer(minLength: 20)

                // Formula & Explanation
                VStack(spacing: 8) {
                    Text(item.tuneProfile.formulaDisplay)
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(item.tuneProfile.subtitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    LiquidAnalyzerPalette.scanCyan,
                                    Color(red: 0.72, green: 0.52, blue: 1.0),
                                    Color(red: 1.0, green: 0.48, blue: 0.82)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(item.tuneProfile.mappingSummary)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.74))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                        .padding(.top, 2)
                }

                Spacer(minLength: 26)

                // Large Play / Pause Button
                Button(action: {
                    tunePlayer.togglePlayPause(for: item)
                }) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.24, blue: 0.52),
                                        Color(red: 0.26, green: 0.14, blue: 0.54)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 78, height: 78)
                            .overlay(
                                Circle()
                                    .stroke(
                                        LinearGradient(
                                            colors: [
                                                LiquidAnalyzerPalette.scanCyan.opacity(0.85),
                                                LiquidAnalyzerPalette.tunePurple.opacity(0.85),
                                                LiquidAnalyzerPalette.tuneMagenta.opacity(0.85)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 2.5
                                    )
                            )
                            .shadow(color: LiquidAnalyzerPalette.tunePurple.opacity(0.55), radius: 16)

                        Image(systemName: tunePlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: tunePlayer.isPlaying ? 0 : 2)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tunePlayer.isPlaying ? "Pause Chemical Tune" : "Play Chemical Tune")

                Text(tunePlayer.isPlaying ? "Pause" : "Play")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.80))
                    .padding(.top, 8)

                // Interactive Progress Scrubber
                VStack(spacing: 6) {
                    Slider(
                        value: Binding(
                            get: { tunePlayer.progress },
                            set: { newVal in tunePlayer.seek(to: newVal, for: item) }
                        ),
                        in: 0.0...1.0
                    )
                    .tint(LiquidAnalyzerPalette.scanCyan)

                    HStack {
                        Text(Self.formatSeconds(tunePlayer.progress * tunePlayer.durationSeconds))
                        Spacer()
                        Text(Self.formatSeconds(tunePlayer.durationSeconds))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.60))
                }
                .padding(.horizontal, 32)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
        }
        .onAppear {
            tunePlayer.prepareIfNeeded(for: item)
        }
        .onDisappear {
            tunePlayer.stop()
        }
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        let clamped = max(0, Int(round(seconds)))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
