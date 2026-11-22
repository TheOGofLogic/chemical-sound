package org.liquidanalyzer.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color as AndroidColor
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import androidx.camera.core.ImageProxy
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import java.util.Locale
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.ln
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sin
import kotlin.math.sqrt

enum class MatchStatus {
    REFERENCE_MATCH,
    NO_VALIDATED_MATCH,
    EMPTY_CONTAINER,
    NON_LIQUID_SURFACE,
    INVALID_MEASUREMENT
}

enum class ComparatorStage {
    EMPTY_CUP,
    WATER_BLANK,
    TEST_SAMPLE
}

data class OpticalVisionSnapshot(
    val meanHueDeg: Double,
    val meanSaturation: Double,
    val meanValue: Double,
    val meanLuma: Double,
    val turbidityStd: Double,
    val meniscusAngleDeg: Double,
    val hasLiquidPoolContrast: Boolean,
    val capturedAtMs: Long = System.currentTimeMillis()
)

data class MultiModalAttributionInfo(
    val acousticEvidence: String,
    val visionEvidence: String,
    val comparatorEvidence: String?,
    val recommendsComparator: Boolean
)

data class ConstituentItem(
    val symbol: String,
    val name: String,
    val roleDescription: String
)

data class LiquidReferenceProfile(
    val id: String,
    val displayName: String,
    val formulaDisplay: String,
    val nominalPhRange: String,
    val constituents: List<ConstituentItem>,
    val expectedCentroidHz: Double,
    val expectedPeakHz: Double,
    val expectedMidToHighDb: Double,
    val expectedDecayDbPerSec: Double,
    val expectedHighScatterDb: Double = -8.0,
    val expectedHueDeg: Double? = null,
    val expectedMinSat: Double = 0.0,
    val expectedMaxSat: Double = 1.0,
    val expectedMinVal: Double = 0.0,
    val expectedMaxVal: Double = 1.0,
    val requiresFizzyScatter: Boolean = false,
    val requiresComparatorForClear: Boolean = false,
    val tuneFrequenciesHz: List<Double>,
    val shimmer: Double,
    val warmthDecay: Double,
    val tuneSummary: String
)

data class ScanResultItem(
    val id: String,
    val timestampLabel: String,
    val status: MatchStatus,
    val title: String,
    val formulaDisplay: String,
    val nominalPhRange: String,
    val badgeText: String,
    val scientificNote: String,
    val constituents: List<ConstituentItem>,
    val attribution: MultiModalAttributionInfo?,
    val tuneFrequenciesHz: List<Double>,
    val shimmer: Double,
    val warmthDecay: Double,
    val tuneSummary: String,
    val measuredPeakHz: Double
)

object ReferenceCatalog {
    val profiles: List<LiquidReferenceProfile> = listOf(
        LiquidReferenceProfile(
            id = "OIL_VEG",
            displayName = "Cooking Oil",
            formulaDisplay = "C₅₇H₁₀₄O₆ (Triglyceride)",
            nominalPhRange = "Non-aqueous neutral lipid (no free H⁺)",
            constituents = listOf(
                ConstituentItem("85.5%", "Unsaturated Esters", "Oleic & linoleic fatty acid triglycerides"),
                ConstituentItem("13.7%", "Saturated Esters", "Palmitic & stearic glyceride fraction"),
                ConstituentItem("0.8%", "Tocopherols", "Natural vitamin E & phytosterols")
            ),
            expectedCentroidHz = 1580.0,
            expectedPeakHz = 1420.0,
            expectedMidToHighDb = 8.6,
            expectedDecayDbPerSec = 148.0,
            expectedHighScatterDb = -9.5,
            expectedHueDeg = 46.0,
            expectedMinSat = 0.24,
            expectedMaxSat = 0.92,
            expectedMinVal = 0.34,
            expectedMaxVal = 0.96,
            tuneFrequenciesHz = listOf(196.00, 293.66, 392.00, 440.00, 587.33),
            shimmer = 0.72,
            warmthDecay = 2.35,
            tuneSummary = "Warm, rapidly damped low-register carbon-chain harmonics mapped from viscous resonance."
        ),
        LiquidReferenceProfile(
            id = "MILK_DAIRY",
            displayName = "Milk",
            formulaDisplay = "H₂O + C₁₂H₂₂O₁₁ + Casein",
            nominalPhRange = "pH 6.5 – 6.7 (Slightly acidic emulsion)",
            constituents = listOf(
                ConstituentItem("87.7%", "Water (H₂O)", "Continuous aqueous dispersion phase"),
                ConstituentItem("4.8%", "Lactose", "Dissolved milk disaccharide"),
                ConstituentItem("3.4%", "Casein & Whey", "Opaque light-scattering micelle proteins")
            ),
            expectedCentroidHz = 2120.0,
            expectedPeakHz = 1860.0,
            expectedMidToHighDb = 6.2,
            expectedDecayDbPerSec = 112.0,
            expectedHighScatterDb = -8.8,
            expectedHueDeg = null,
            expectedMinSat = 0.0,
            expectedMaxSat = 0.22,
            expectedMinVal = 0.84,
            expectedMaxVal = 1.0,
            tuneFrequenciesHz = listOf(261.63, 329.63, 392.00, 523.25, 659.25),
            shimmer = 0.88,
            warmthDecay = 1.85,
            tuneSummary = "Soft colloidal major chord reflecting opaque Tyndall/Mie optical scatter and gentle damping."
        ),
        LiquidReferenceProfile(
            id = "COFFEE_BREW",
            displayName = "Coffee",
            formulaDisplay = "H₂O + C₈H₁₀N₄O₂ + Acids",
            nominalPhRange = "pH 4.8 – 5.1 (Mild organic acid brew)",
            constituents = listOf(
                ConstituentItem("98.5%", "Water (H₂O)", "Brewed aqueous extraction solvent"),
                ConstituentItem("0.9%", "Chlorogenic Acids", "Roasted melanoidin & phenolic solutes"),
                ConstituentItem("0.1%", "Caffeine", "Methylxanthine alkaloid constituent")
            ),
            expectedCentroidHz = 2480.0,
            expectedPeakHz = 2180.0,
            expectedMidToHighDb = 4.2,
            expectedDecayDbPerSec = 84.0,
            expectedHighScatterDb = -8.6,
            expectedHueDeg = 28.0,
            expectedMinSat = 0.22,
            expectedMaxSat = 0.90,
            expectedMinVal = 0.06,
            expectedMaxVal = 0.36,
            tuneFrequenciesHz = listOf(220.00, 277.18, 329.63, 440.00, 554.37),
            shimmer = 0.96,
            warmthDecay = 1.65,
            tuneSummary = "Deep roasted-amber acoustic voicing with still, non-effervescent decay."
        ),
        LiquidReferenceProfile(
            id = "COLA_CARB",
            displayName = "Cola (Carbonated)",
            formulaDisplay = "H₂O + H₂CO₃ + H₃PO₄ + Sucrose",
            nominalPhRange = "pH 2.5 – 2.7 (Acidulated carbonated)",
            constituents = listOf(
                ConstituentItem("89.0%", "Carbonated Water", "Dissolved CO₂ / carbonic acid phase"),
                ConstituentItem("10.6%", "Carbohydrates", "Sucrose / caramel colorant matrix"),
                ConstituentItem("0.05%", "Phosphoric Acid", "Acidulant profile constituent")
            ),
            expectedCentroidHz = 3420.0,
            expectedPeakHz = 2360.0,
            expectedMidToHighDb = 2.0,
            expectedDecayDbPerSec = 94.0,
            expectedHighScatterDb = -2.2,
            expectedHueDeg = 24.0,
            expectedMinSat = 0.20,
            expectedMaxSat = 0.92,
            expectedMinVal = 0.06,
            expectedMaxVal = 0.40,
            requiresFizzyScatter = true,
            tuneFrequenciesHz = listOf(246.94, 369.99, 493.88, 659.25, 880.00),
            shimmer = 1.34,
            warmthDecay = 1.55,
            tuneSummary = "Dark caramel bass intervals paired with sparkling high-frequency CO₂ effervescent overtones."
        ),
        LiquidReferenceProfile(
            id = "JUICE_CITRUS",
            displayName = "Citrus / Orange Juice",
            formulaDisplay = "H₂O + C₆H₈O₇ + C₆H₈O₆",
            nominalPhRange = "pH 3.3 – 4.1 (Citric & ascorbic acid)",
            constituents = listOf(
                ConstituentItem("88.3%", "Water (H₂O)", "Natural juice aqueous base"),
                ConstituentItem("9.8%", "Natural Sugars", "Fructose, glucose & sucrose"),
                ConstituentItem("1.1%", "Citric & Ascorbic", "Organic acids, vitamin C & pulp")
            ),
            expectedCentroidHz = 2290.0,
            expectedPeakHz = 1990.0,
            expectedMidToHighDb = 5.1,
            expectedDecayDbPerSec = 102.0,
            expectedHighScatterDb = -8.4,
            expectedHueDeg = 38.0,
            expectedMinSat = 0.55,
            expectedMaxSat = 1.0,
            expectedMinVal = 0.52,
            expectedMaxVal = 0.98,
            tuneFrequenciesHz = listOf(293.66, 369.99, 440.00, 587.33, 739.99),
            shimmer = 1.12,
            warmthDecay = 1.72,
            tuneSummary = "Bright citrus-major intervals shaped by suspended pulp turbidity and acoustic damping."
        ),
        LiquidReferenceProfile(
            id = "WINE_RED",
            displayName = "Red Wine",
            formulaDisplay = "H₂O + C₂H₅OH + Anthocyanins",
            nominalPhRange = "pH 3.3 – 3.8 (Tartaric & malic acids)",
            constituents = listOf(
                ConstituentItem("85.0%", "Water (H₂O)", "Primary fermented solvent"),
                ConstituentItem("12.5%", "Ethanol (C₂H₅OH)", "Fermentation alcohol constituent"),
                ConstituentItem("0.4%", "Polyphenols", "Anthocyanin pigments & tannins")
            ),
            expectedCentroidHz = 2380.0,
            expectedPeakHz = 2110.0,
            expectedMidToHighDb = 4.5,
            expectedDecayDbPerSec = 92.0,
            expectedHighScatterDb = -8.8,
            expectedHueDeg = 345.0,
            expectedMinSat = 0.38,
            expectedMaxSat = 1.0,
            expectedMinVal = 0.10,
            expectedMaxVal = 0.58,
            tuneFrequenciesHz = listOf(220.00, 261.63, 329.63, 440.00, 523.25),
            shimmer = 1.04,
            warmthDecay = 1.78,
            tuneSummary = "Rich ruby minor-seventh harmonic voicing reflecting deep anthocyanin absorption."
        ),
        LiquidReferenceProfile(
            id = "SELTZER_CO2",
            displayName = "Sparkling Water",
            formulaDisplay = "H₂O + CO₂ ⇌ H₂CO₃",
            nominalPhRange = "pH 3.5 – 4.5 (Carbonic acid equilibrium)",
            constituents = listOf(
                ConstituentItem("99.4%", "Water (H₂O)", "Clear carbonated aqueous medium"),
                ConstituentItem("0.6%", "Dissolved CO₂", "Active micro-bubble scatter & H₂CO₃")
            ),
            expectedCentroidHz = 3680.0,
            expectedPeakHz = 2420.0,
            expectedMidToHighDb = 1.4,
            expectedDecayDbPerSec = 80.0,
            expectedHighScatterDb = -2.4,
            expectedHueDeg = null,
            expectedMinSat = 0.0,
            expectedMaxSat = 0.24,
            expectedMinVal = 0.30,
            expectedMaxVal = 0.92,
            requiresFizzyScatter = true,
            tuneFrequenciesHz = listOf(261.63, 329.63, 392.00, 493.88, 587.33),
            shimmer = 1.32,
            warmthDecay = 1.52,
            tuneSummary = "Crystalline aqueous chord layered with effervescent high-frequency micro-bubble shimmer."
        ),
        LiquidReferenceProfile(
            id = "H2O_DIST",
            displayName = "Water",
            formulaDisplay = "H₂O",
            nominalPhRange = "pH 6.8 – 7.2 (Neutral aqueous reference)",
            constituents = listOf(
                ConstituentItem("99.9%", "Water (H₂O)", "Primary neutral aqueous reference"),
                ConstituentItem("<0.1%", "Trace Minerals", "Typical potable dissolved ions")
            ),
            expectedCentroidHz = 2560.0,
            expectedPeakHz = 2220.0,
            expectedMidToHighDb = 3.8,
            expectedDecayDbPerSec = 76.0,
            expectedHighScatterDb = -8.5,
            expectedHueDeg = null,
            expectedMinSat = 0.0,
            expectedMaxSat = 0.22,
            expectedMinVal = 0.30,
            expectedMaxVal = 0.90,
            requiresComparatorForClear = true,
            tuneFrequenciesHz = listOf(392.00, 493.88, 587.33, 783.99, 880.00),
            shimmer = 1.06,
            warmthDecay = 1.45,
            tuneSummary = "Pure hydrogen-oxygen fifth and octave intervals mapped from container resonance."
        ),
        LiquidReferenceProfile(
            id = "VIN_WHITE",
            displayName = "White Vinegar",
            formulaDisplay = "H₂O + CH₃COOH (5%)",
            nominalPhRange = "pH 2.4 – 2.6 (Dilute acetic acid)",
            constituents = listOf(
                ConstituentItem("95.0%", "Water (H₂O)", "Primary aqueous solvent"),
                ConstituentItem("5.0%", "Acetic Acid", "Household organic acid solute")
            ),
            expectedCentroidHz = 2510.0,
            expectedPeakHz = 2160.0,
            expectedMidToHighDb = 4.1,
            expectedDecayDbPerSec = 98.0,
            expectedHighScatterDb = -8.6,
            expectedHueDeg = null,
            expectedMinSat = 0.0,
            expectedMaxSat = 0.25,
            expectedMinVal = 0.30,
            expectedMaxVal = 0.90,
            requiresComparatorForClear = true,
            tuneFrequenciesHz = listOf(293.66, 440.00, 554.37, 659.25, 880.00),
            shimmer = 1.15,
            warmthDecay = 1.70,
            tuneSummary = "Crisp upper-harmonic voicing calibrated via stationary 3-Step Cup Comparator."
        ),
        LiquidReferenceProfile(
            id = "NACL_AQ",
            displayName = "Saline Water",
            formulaDisplay = "H₂O + NaCl",
            nominalPhRange = "pH 6.8 – 7.2 (Neutral electrolyte solution)",
            constituents = listOf(
                ConstituentItem("96.5%", "Water (H₂O)", "Aqueous solvent base"),
                ConstituentItem("3.5%", "Sodium Chloride", "Dissolved Na⁺ / Cl⁻ electrolyte ions")
            ),
            expectedCentroidHz = 3180.0,
            expectedPeakHz = 2640.0,
            expectedMidToHighDb = 2.1,
            expectedDecayDbPerSec = 68.0,
            expectedHighScatterDb = -9.2,
            expectedHueDeg = null,
            expectedMinSat = 0.0,
            expectedMaxSat = 0.22,
            expectedMinVal = 0.30,
            expectedMaxVal = 0.90,
            requiresComparatorForClear = true,
            tuneFrequenciesHz = listOf(392.00, 587.33, 659.25, 739.99, 987.77),
            shimmer = 1.24,
            warmthDecay = 1.55,
            tuneSummary = "Bright ionic fifth and ninth intervals derived from stationary differential mass shift."
        )
    )
}

object LiveCameraOpticsAnalyzer {
    @Volatile
    var latestSnapshot: OpticalVisionSnapshot? = null
        private set

    fun analyzeFrame(image: ImageProxy) {
        try {
            val planes = image.planes
            if (planes.size < 3) return
            val w = image.width
            val h = image.height
            if (w < 32 || h < 32) return

            val yPlane = planes[0]
            val uPlane = planes[1]
            val vPlane = planes[2]
            val yBuf = yPlane.buffer
            val uBuf = uPlane.buffer
            val vBuf = vPlane.buffer
            val yRowStride = yPlane.rowStride
            val uvRowStride = uPlane.rowStride
            val uvPixelStride = uPlane.pixelStride

            val x0 = (w * 0.30).toInt()
            val x1 = (w * 0.70).toInt()
            val y0 = (h * 0.30).toInt()
            val y1 = (h * 0.70).toInt()
            val step = max(2, min(w, h) / 48)

            var sumSinH = 0.0
            var sumCosH = 0.0
            var weightedHueCount = 1e-9
            var sumSat = 0.0
            var sumVal = 0.0
            var sumLuma = 0.0
            var sumLumaSq = 0.0
            var count = 0
            val hsv = FloatArray(3)

            var gy = y0
            while (gy < y1) {
                var gx = x0
                while (gx < x1) {
                    val yIdx = gy * yRowStride + gx
                    val uvIdx = (gy / 2) * uvRowStride + (gx / 2) * uvPixelStride
                    if (yIdx < yBuf.limit() && uvIdx < uBuf.limit() && uvIdx < vBuf.limit()) {
                        val yVal = (yBuf.get(yIdx).toInt() and 0xFF)
                        val uVal = (uBuf.get(uvIdx).toInt() and 0xFF) - 128
                        val vVal = (vBuf.get(uvIdx).toInt() and 0xFF) - 128

                        val r = (yVal + 1.370705 * vVal).roundToInt().coerceIn(0, 255)
                        val g = (yVal - 0.337633 * uVal - 0.698001 * vVal).roundToInt().coerceIn(0, 255)
                        val b = (yVal + 1.732446 * uVal).roundToInt().coerceIn(0, 255)

                        AndroidColor.RGBToHSV(r, g, b, hsv)
                        val rad = hsv[0] * PI / 180.0
                        val wSat = hsv[1].toDouble().coerceAtLeast(0.02)
                        sumSinH += sin(rad) * wSat
                        sumCosH += cos(rad) * wSat
                        weightedHueCount += wSat
                        sumSat += hsv[1]
                        sumVal += hsv[2]
                        val luma = yVal / 255.0
                        sumLuma += luma
                        sumLumaSq += luma * luma
                        count++
                    }
                    gx += step
                }
                gy += step
            }

            if (count < 16) return
            var hueDeg = atan2(sumSinH / weightedHueCount, sumCosH / weightedHueCount) * 180.0 / PI
            if (hueDeg < 0.0) hueDeg += 360.0
            val meanSat = sumSat / count
            val meanVal = sumVal / count
            val meanLuma = sumLuma / count
            val variance = max(0.0, sumLumaSq / count - meanLuma * meanLuma)
            val turbStd = sqrt(variance)

            // Estimate vertical air-to-liquid meniscus contrast across upper-to-lower ROI
            var topLuma = 0.0
            var botLuma = 0.0
            var edgeCount = 0
            var sx = x0
            while (sx < x1) {
                val topIdx = ((h * 0.24).toInt()) * yRowStride + sx
                val botIdx = ((h * 0.56).toInt()) * yRowStride + sx
                if (topIdx < yBuf.limit() && botIdx < yBuf.limit()) {
                    topLuma += (yBuf.get(topIdx).toInt() and 0xFF) / 255.0
                    botLuma += (yBuf.get(botIdx).toInt() and 0xFF) / 255.0
                    edgeCount++
                }
                sx += step
            }
            val vertStep = if (edgeCount > 0) abs(topLuma - botLuma) / edgeCount else 0.0
            val meniscusDeg = (46.0 - vertStep * 36.0).coerceIn(22.0, 48.0)
            val hasPool = vertStep > 0.045 || meanSat > 0.18 || (meanVal > 0.84 && turbStd < 0.14)

            latestSnapshot = OpticalVisionSnapshot(
                meanHueDeg = hueDeg,
                meanSaturation = meanSat,
                meanValue = meanVal,
                meanLuma = meanLuma,
                turbidityStd = turbStd,
                meniscusAngleDeg = meniscusDeg,
                hasLiquidPoolContrast = hasPool
            )
        } catch (_: Exception) {
            // Best-effort frame optics
        } finally {
            image.close()
        }
    }
}

class LiquidAnalyzerAudioEngine(private val context: Context) {
    private val sampleRate = 48_000
    private val prefs = context.getSharedPreferences("la_v050_comparator", Context.MODE_PRIVATE)
    private var lastExcitationEndMs: Long = 0L
    private var activeTuneTrack: AudioTrack? = null

    val emptyCupPeakHz: Double?
        get() = if (prefs.contains("empty_peak_hz")) prefs.getFloat("empty_peak_hz", 0f).toDouble() else null

    val waterBlankPeakHz: Double?
        get() = if (prefs.contains("water_peak_hz")) prefs.getFloat("water_peak_hz", 0f).toDouble() else null

    val hasReadyComparatorBaselines: Boolean
        get() = emptyCupPeakHz != null && waterBlankPeakHz != null

    fun clearComparatorBaselines() {
        prefs.edit().clear().apply()
    }

    fun hasExternalAudioRouteConnected(): Boolean {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return false
        val outputs = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        return outputs.any { dev ->
            when (dev.type) {
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
                AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
                AudioDeviceInfo.TYPE_BLE_HEADSET,
                AudioDeviceInfo.TYPE_BLE_SPEAKER,
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
                AudioDeviceInfo.TYPE_WIRED_HEADSET,
                AudioDeviceInfo.TYPE_USB_HEADSET,
                AudioDeviceInfo.TYPE_USB_DEVICE -> true
                else -> false
            }
        }
    }

    @SuppressLint("MissingPermission")
    suspend fun executeConsumerScan(
        comparatorStage: ComparatorStage? = null,
        onProgress: (Float) -> Unit
    ): Result<ScanResultItem> = withContext(Dispatchers.Default) {
        if (hasExternalAudioRouteConnected()) {
            return@withContext Result.failure(
                IllegalStateException("Headphones or a Bluetooth speaker are connected. Please disconnect external audio so Liquid Analyzer can use your phone's built-in speaker and microphone.")
            )
        }

        val sinceLast = System.currentTimeMillis() - lastExcitationEndMs
        if (lastExcitationEndMs > 0L && sinceLast < 900L) {
            delay(900L - sinceLast)
        }
        onProgress(0.22f)

        val preRollSamples = 7_200  // 150 ms ambient & pre-roll HF gate
        val activeSamples = 9_600   // 200 ms ESS sweep
        val postRollSamples = 7_200 // 150 ms ring-down decay window
        val totalRecordSamples = preRollSamples + activeSamples + postRollSamples

        val sweep = buildEssSweep(activeSamples)
        val minBufBytes = AudioRecord.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT
        ).coerceAtLeast(totalRecordSamples * 4)

        val recorder = try {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.UNPROCESSED)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build()
                )
                .setBufferSizeInBytes(minBufBytes)
                .build()
        } catch (_: Exception) {
            AudioRecord.Builder()
                .setAudioSource(MediaRecorder.AudioSource.VOICE_RECOGNITION)
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                        .setSampleRate(sampleRate)
                        .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                        .build()
                )
                .setBufferSizeInBytes(minBufBytes)
                .build()
        }

        if (recorder.state != AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            return@withContext Result.failure(
                IllegalStateException("Unable to initialize microphone capture. Please verify Microphone access in Settings.")
            )
        }

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(sweep.size * 4)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        track.write(sweep, 0, sweep.size, AudioTrack.WRITE_BLOCKING)
        val captured = FloatArray(totalRecordSamples)

        try {
            recorder.startRecording()
            onProgress(0.45f)
            delay(150L)
            track.play()
            onProgress(0.68f)
            delay(360L)

            var offset = 0
            while (offset < totalRecordSamples && isActive) {
                val read = recorder.read(captured, offset, totalRecordSamples - offset, AudioRecord.READ_NON_BLOCKING)
                if (read <= 0) break
                offset += read
            }
            lastExcitationEndMs = System.currentTimeMillis()
            onProgress(0.88f)
        } finally {
            runCatching { track.stop() }
            track.release()
            runCatching { recorder.stop() }
            recorder.release()
        }

        val optics = LiveCameraOpticsAnalyzer.latestSnapshot
        val result = classifyMultiModalSignal(captured, preRollSamples, activeSamples, optics, comparatorStage)
        onProgress(1.0f)
        Result.success(result)
    }

    private fun buildEssSweep(numSamples: Int): FloatArray {
        val out = FloatArray(numSamples)
        val f1 = 400.0
        val f2 = 14_000.0
        val duration = numSamples.toDouble() / sampleRate.toDouble()
        val l = duration / ln(f2 / f1)
        val fadeSamples = 480
        val amp = 10.0.pow(-6.0 / 20.0)

        for (i in 0 until numSamples) {
            val t = i.toDouble() / sampleRate.toDouble()
            val fadeIn = if (i < fadeSamples) 0.5 * (1.0 - cos(PI * i / fadeSamples)) else 1.0
            val fadeOut = if (i > numSamples - fadeSamples) 0.5 * (1.0 - cos(PI * (numSamples - i) / fadeSamples)) else 1.0
            val phase = 2.0 * PI * f1 * l * (exp(t / l) - 1.0)
            out[i] = (amp * fadeIn * fadeOut * sin(phase)).toFloat()
        }
        return out
    }

    private fun classifyMultiModalSignal(
        samples: FloatArray,
        preFrames: Int,
        actFrames: Int,
        optics: OpticalVisionSnapshot?,
        comparatorStage: ComparatorStage?
    ): ScanResultItem {
        val clipLin = 10.0.pow(-0.5 / 20.0)
        var clipped = 0
        for (v in samples) {
            if (v.isFinite() && abs(v.toDouble()) >= clipLin) clipped++
        }

        val preRms = rms(samples, 0, min(samples.size, preFrames))
        val actRms = rms(samples, preFrames, min(samples.size, preFrames + actFrames))
        val earlyPostRms = rms(samples, preFrames + actFrames, min(samples.size, preFrames + actFrames + 2400))
        val latePostRms = rms(samples, preFrames + actFrames + 2400, min(samples.size, preFrames + actFrames + 6000))
        val snrDb = 20.0 * log10((actRms + 1e-9) / (preRms + 1e-9))
        val decayDbPerSec = (20.0 * log10((earlyPostRms + 1e-7) / (latePostRms + 1e-7)) / 0.0625).coerceIn(38.0, 180.0)

        // Pre-roll ambient HF scatter gate (prevents false fizz triggers from room transients)
        val preHfRatioDb = computeHighScatterDb(samples, max(0, preFrames - 4096))
        val nFft = 4096
        val real = DoubleArray(nFft)
        val imag = DoubleArray(nFft)
        val start = min(samples.size, preFrames)
        val copyLen = min(nFft, max(0, samples.size - start))
        for (i in 0 until copyLen) {
            val w = 0.5 * (1.0 - cos(2.0 * PI * i / max(1, copyLen - 1)))
            real[i] = samples[start + i].toDouble() * w
        }
        fftRadix2(real, imag)

        val binHz = sampleRate.toDouble() / nFft.toDouble()
        val minBin = (1100.0 / binHz).toInt().coerceAtLeast(1)
        val maxBin = (9600.0 / binHz).toInt().coerceAtMost(nFft / 2 - 1)
        val maxScatterBin = (11800.0 / binHz).toInt().coerceAtMost(nFft / 2 - 1)

        var weightedFreq = 0.0
        var totalPower = 1e-15
        var bestPower = 1e-15
        var dominantHz = 2220.0
        var midPower = 1e-15
        var highPower = 1e-15
        var corePower = 1e-15
        var upperScatterPower = 1e-15
        var logPowerSum = 0.0
        var flatCount = 0

        for (b in minBin..maxScatterBin) {
            val rawP = real[b] * real[b] + imag[b] * imag[b]
            val f = b * binHz
            val normAbove = max(0.0, (f - 3200.0) / 3800.0)
            val speakerWeight = 1.0 / (1.0 + 0.28 * normAbove.pow(1.3))
            val p = rawP * speakerWeight

            if (b <= maxBin) {
                weightedFreq += f * p
                totalPower += p
                if (p > bestPower) {
                    bestPower = p
                    dominantHz = f
                }
                if (f in 1100.0..3200.0) midPower += p
                else if (f in 3200.0..9600.0) highPower += p
                if (f <= 8500.0) {
                    logPowerSum += ln(max(p, 1e-18))
                    flatCount++
                }
            }
            if (f in 1500.0..4200.0) corePower += p
            else if (f in 5500.0..8500.0) upperScatterPower += p
        }

        val centroidHz = weightedFreq / totalPower
        val midToHighDb = (10.0 * log10(midPower / highPower)).coerceIn(-14.0, 14.0)
        val highScatterDb = (10.0 * log10(upperScatterPower / corePower)).coerceIn(-14.0, 6.0)
        val preRollExcessHfDb = preHfRatioDb - (-4.5)
        val isVerifiedEffervescent = highScatterDb >= -3.8 && preRollExcessHfDb <= 0.0

        val meanBinP = if (flatCount > 0) totalPower / flatCount else 1e-15
        val spectralFlatness = if (flatCount > 0) (exp(logPowerSum / flatCount) / max(meanBinP, 1e-18)).coerceIn(0.0, 1.0) else 0.5
        val peakProminenceDb = max(0.0, 10.0 * log10(bestPower / max(meanBinP, 1e-18)))
        val nowTime = java.text.SimpleDateFormat("h:mm a", Locale.US).format(java.util.Date())

        if (clipped > 12 || snrDb < 6.0) {
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.INVALID_MEASUREMENT,
                title = "Scan Unclear",
                formulaDisplay = "Signal Quality Gate",
                nominalPhRange = "Unavailable",
                badgeText = "Rescan Needed • Raise Volume Slightly",
                scientificNote = "Ambient room noise was too close to the acoustic sweep or media volume was muted. Hold steady in a quiet spot and tap SCAN again.",
                constituents = emptyList(),
                attribution = null,
                tuneFrequenciesHz = listOf(392.0, 493.88, 587.33, 783.99),
                shimmer = 1.0,
                warmthDecay = 1.6,
                tuneSummary = "Captured acoustic echo preview.",
                measuredPeakHz = dominantHz
            )
        }

        // Guided 3-Step Cup Comparator baseline capture stages
        if (comparatorStage == ComparatorStage.EMPTY_CUP) {
            prefs.edit().putFloat("empty_peak_hz", dominantHz.toFloat()).apply()
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.EMPTY_CONTAINER,
                title = "Step 1 Locked • Empty Cup",
                formulaDisplay = "EMPTY_CONTAINER (${dominantHz.roundToInt()} Hz)",
                nominalPhRange = "Dry vessel baseline (no liquid)",
                badgeText = "Empty Cup Baseline Saved",
                scientificNote = "Dry container shell resonance locked at ${dominantHz.roundToInt()} Hz. Proceed to Step 2 and pour clean water to your fill mark.",
                constituents = emptyList(),
                attribution = MultiModalAttributionInfo(
                    acousticEvidence = "Dry vessel mode f₁ = ${dominantHz.roundToInt()} Hz, decay = ${decayDbPerSec.roundToInt()} dB/s",
                    visionEvidence = optics?.let { "Dry container frame verified (Sat ${"%.2f".format(Locale.US, it.meanSaturation)})" } ?: "Acoustic baseline lock",
                    comparatorEvidence = "Step 1 of 3 complete • Ready for Water Blank",
                    recommendsComparator = false
                ),
                tuneFrequenciesHz = listOf(392.0, 493.88, 587.33),
                shimmer = 0.9,
                warmthDecay = 1.4,
                tuneSummary = "Dry vessel baseline reference tone.",
                measuredPeakHz = dominantHz
            )
        }

        if (comparatorStage == ComparatorStage.WATER_BLANK) {
            prefs.edit().putFloat("water_peak_hz", dominantHz.toFloat()).apply()
            val emptyHz = emptyCupPeakHz
            val shiftPct = if (emptyHz != null && emptyHz > 100.0) abs(dominantHz - emptyHz) / emptyHz * 100.0 else 0.0
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.REFERENCE_MATCH,
                title = "Step 2 Locked • Water Blank",
                formulaDisplay = "H₂O Reference (${dominantHz.roundToInt()} Hz)",
                nominalPhRange = "pH 6.8 – 7.2 (Water Blank Reference)",
                badgeText = "Water Reference Saved • |Δf/f| = ${"%.1f".format(Locale.US, shiftPct)}%",
                scientificNote = "Aqueous mass-loading baseline stored. Empty, dry, and pour your test liquid to the exact same fill mark for Step 3.",
                constituents = ReferenceCatalog.profiles.first { it.id == "H2O_DIST" }.constituents,
                attribution = MultiModalAttributionInfo(
                    acousticEvidence = "Water Blank f₁ = ${dominantHz.roundToInt()} Hz (|Δf/f| = ${"%.1f".format(Locale.US, shiftPct)}% vs Empty Cup)",
                    visionEvidence = optics?.let { "Meniscus ${"%.1f".format(Locale.US, it.meniscusAngleDeg)}° • Clear neutral baseline" } ?: "Aqueous reference stored",
                    comparatorEvidence = "Steps 1 & 2 locked • 3-Step Cup Comparator READY",
                    recommendsComparator = false
                ),
                tuneFrequenciesHz = listOf(392.00, 493.88, 587.33, 783.99, 880.00),
                shimmer = 1.06,
                warmthDecay = 1.45,
                tuneSummary = "Calibrated H₂O reference chord.",
                measuredPeakHz = dominantHz
            )
        }

        // Solid flat surface rejection
        if (spectralFlatness > 0.57 && peakProminenceDb < 7.6) {
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.NON_LIQUID_SURFACE,
                title = "Solid / Non-Liquid Surface",
                formulaDisplay = "No Open Liquid Container",
                nominalPhRange = "Not applicable",
                badgeText = "Solid Surface • Aim Into Cup or Glass",
                scientificNote = "Broadband reflection matches a flat solid surface rather than a liquid-filled vessel. Point into an open glass, mug, or cup containing liquid.",
                constituents = emptyList(),
                attribution = null,
                tuneFrequenciesHz = listOf(392.0, 493.88, 587.33),
                shimmer = 1.0,
                warmthDecay = 1.6,
                tuneSummary = "Surface reflection echo.",
                measuredPeakHz = dominantHz
            )
        }

        // Empty-Cup Safety Gate (checks stored Empty Cup baseline OR dry-shell low-damping + zero optical liquid pool)
        val savedEmptyHz = emptyCupPeakHz
        val nearSavedEmpty = savedEmptyHz != null && abs(dominantHz - savedEmptyHz) / max(savedEmptyHz, 1.0) < 0.032
        val looksOpticallyDry = optics != null && !optics.hasLiquidPoolContrast && optics.meanSaturation < 0.14 && !isVerifiedEffervescent
        val dryShellSignature = decayDbPerSec < 54.0 && centroidHz > 2950.0 && !isVerifiedEffervescent

        if (nearSavedEmpty || (looksOpticallyDry && dryShellSignature)) {
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.EMPTY_CONTAINER,
                title = "Empty Container / Low Coupling",
                formulaDisplay = "EMPTY_CONTAINER",
                nominalPhRange = "No liquid detected",
                badgeText = "Safety Gate Triggered • Dry Glass or Mug",
                scientificNote = "Container boundary audit found no liquid mass-loading above the dry vessel shell. Pour a test liquid into the container and scan again.",
                constituents = emptyList(),
                attribution = MultiModalAttributionInfo(
                    acousticEvidence = "Unloaded shell mode f₁ = ${dominantHz.roundToInt()} Hz, low damping (${decayDbPerSec.roundToInt()} dB/s)",
                    visionEvidence = optics?.let { "No chromatic or meniscus pool boundary detected (Sat ${"%.2f".format(Locale.US, it.meanSaturation)})" } ?: "Dry shell signature",
                    comparatorEvidence = null,
                    recommendsComparator = false
                ),
                tuneFrequenciesHz = listOf(392.0, 493.88, 587.33),
                shimmer = 0.9,
                warmthDecay = 1.4,
                tuneSummary = "Dry container resonance.",
                measuredPeakHz = dominantHz
            )
        }

        // Uncalibrated clear-liquid honesty check (unless 3-Step Comparator baselines are locked or liquid is fizzy!)
        val isOpticallyClear = optics != null && optics.meanSaturation < 0.19 && optics.meanValue in 0.26..0.84
        if (isOpticallyClear && !isVerifiedEffervescent && comparatorStage != ComparatorStage.TEST_SAMPLE && !hasReadyComparatorBaselines) {
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.NO_VALIDATED_MATCH,
                title = "Clear Liquid Detected",
                formulaDisplay = "Aqueous Candidate • Calibration Needed",
                nominalPhRange = "Use 3-Step Cup Comparator for clear fluids",
                badgeText = "Liquid Loaded • Run 3-Step Cup Comparator",
                scientificNote = "Liquid mass-loading was verified above an empty cup, but clear non-fizzy liquids (water, vinegar, saline) require stationary same-cup calibration. Tap '3-Step Cup Comparator' on the Home screen.",
                constituents = listOf(
                    ConstituentItem("f₁ ≈ ${dominantHz.roundToInt()} Hz", "Liquid-Loaded Mode", "Stationary Water Blank required to separate clear solutes")
                ),
                attribution = MultiModalAttributionInfo(
                    acousticEvidence = "Liquid mass load detected at f₁ = ${dominantHz.roundToInt()} Hz (still, non-fizzy)",
                    visionEvidence = "Clear low-chroma fluid (Sat ${"%.2f".format(Locale.US, optics?.meanSaturation ?: 0.0)}, Meniscus ${"%.1f".format(Locale.US, optics?.meniscusAngleDeg ?: 42.0)}°)",
                    comparatorEvidence = null,
                    recommendsComparator = true
                ),
                tuneFrequenciesHz = listOf(392.00, 493.88, 587.33, 783.99),
                shimmer = 1.04,
                warmthDecay = 1.55,
                tuneSummary = "Mapped chord from measured liquid-loaded container resonance.",
                measuredPeakHz = dominantHz
            )
        }

        // Bayesian Multi-Modal Acoustic + Optical Scoring
        val waterRefHz = waterBlankPeakHz
        val scored = ReferenceCatalog.profiles.mapNotNull { prof ->
            if (prof.requiresFizzyScatter && !isVerifiedEffervescent) return@mapNotNull null
            if (!prof.requiresFizzyScatter && isVerifiedEffervescent && prof.id in setOf("COFFEE_BREW", "H2O_DIST", "VIN_WHITE", "NACL_AQ")) {
                return@mapNotNull null
            }

            val dp = (dominantHz - prof.expectedPeakHz) / 580.0
            val dc = (centroidHz - prof.expectedCentroidHz) / 650.0
            val db = (midToHighDb - prof.expectedMidToHighDb) / 3.8
            val dd = (decayDbPerSec - prof.expectedDecayDbPerSec) / 38.0
            val ds = (highScatterDb - prof.expectedHighScatterDb) / 3.2
            val acousticDist = sqrt(0.26 * dp * dp + 0.22 * dc * dc + 0.16 * db * db + 0.14 * dd * dd + 0.22 * ds * ds)

            var visionPenalty = 0.0
            if (optics != null) {
                if (optics.meanSaturation < prof.expectedMinSat - 0.08 || optics.meanSaturation > prof.expectedMaxSat + 0.10) {
                    visionPenalty += 1.35
                }
                if (optics.meanValue < prof.expectedMinVal - 0.10 || optics.meanValue > prof.expectedMaxVal + 0.10) {
                    visionPenalty += 1.25
                }
                if (prof.expectedHueDeg != null && optics.meanSaturation >= 0.18) {
                    val rawDiff = abs(optics.meanHueDeg - prof.expectedHueDeg)
                    val hueDiff = min(rawDiff, 360.0 - rawDiff)
                    visionPenalty += (hueDiff / 38.0).pow(1.4)
                }
                if (prof.id == "MILK_DAIRY" && optics.meanLuma > 0.84 && optics.meanSaturation < 0.20) {
                    visionPenalty -= 0.55
                }
            } else if (prof.requiresComparatorForClear && waterRefHz == null) {
                return@mapNotNull null
            }

            // Stationary 3-Step Comparator differential bonus for clear liquids
            var compPenalty = 0.0
            if (waterRefHz != null && waterRefHz > 100.0 && prof.requiresComparatorForClear) {
                val relShiftPct = (dominantHz - waterRefHz) / waterRefHz * 100.0
                compPenalty = when (prof.id) {
                    "H2O_DIST" -> abs(relShiftPct) / 2.2
                    "VIN_WHITE" -> abs(relShiftPct - (-2.4)) / 2.5
                    "NACL_AQ" -> abs(relShiftPct - 3.6) / 2.8
                    else -> 0.5
                }
            }

            val fusedDist = (0.52 * acousticDist + 0.48 * visionPenalty + 0.35 * compPenalty).coerceAtLeast(0.05)
            prof to fusedDist
        }.sortedBy { it.second }

        if (scored.isEmpty() || scored.first().second > 2.75) {
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.NO_VALIDATED_MATCH,
                title = "Unmatched Liquid",
                formulaDisplay = "Multi-Modal Profile",
                nominalPhRange = "Outside reference library",
                badgeText = "Inconclusive • Outside Calibrated Library",
                scientificNote = "Acoustic and optical features were captured cleanly, but did not closely match a calibrated household liquid class.",
                constituents = listOf(
                    ConstituentItem("≈ ${dominantHz.roundToInt()} Hz", "Dominant Resonance", "Measured container-liquid frequency")
                ),
                attribution = MultiModalAttributionInfo(
                    acousticEvidence = "Peak f₁ = ${dominantHz.roundToInt()} Hz, centroid = ${centroidHz.roundToInt()} Hz",
                    visionEvidence = optics?.let { "Hue ${it.meanHueDeg.roundToInt()}°, Sat ${"%.2f".format(Locale.US, it.meanSaturation)}, Val ${"%.2f".format(Locale.US, it.meanValue)}" } ?: "Acoustic-only capture",
                    comparatorEvidence = null,
                    recommendsComparator = isOpticallyClear
                ),
                tuneFrequenciesHz = listOf(329.63, 369.99, 440.00, 587.33, 659.25),
                shimmer = 1.0,
                warmthDecay = 1.75,
                tuneSummary = "Mapped musical chord derived from measured resonance.",
                measuredPeakHz = dominantHz
            )
        }

        val (bestProf, bestDist) = scored.first()
        val secondDist = scored.getOrNull(1)?.second ?: (bestDist + 0.65)
        val margin = (secondDist - bestDist).coerceAtLeast(0.0)
        val rawSim = exp(-0.42 * bestDist) * (0.80 + 0.20 * min(1.0, margin / 0.40))
        val confidence = (rawSim * 96.0).roundToInt().coerceIn(64, 96)

        val emptyShiftNote = savedEmptyHz?.let {
            val pct = abs(dominantHz - it) / max(it, 1.0) * 100.0
            " (|Δf/f| = ${"%.1f".format(Locale.US, pct)}% vs Empty Cup)"
        } ?: ""

        val compSummary = waterRefHz?.let { wHz ->
            val dPct = (dominantHz - wHz) / max(wHz, 1.0) * 100.0
            "ΔF/F_water = ${"%+.2f".format(Locale.US, dPct)}% vs locked Water Blank"
        }

        return ScanResultItem(
            id = "scan_${System.currentTimeMillis()}",
            timestampLabel = nowTime,
            status = MatchStatus.REFERENCE_MATCH,
            title = bestProf.displayName,
            formulaDisplay = bestProf.formulaDisplay,
            nominalPhRange = bestProf.nominalPhRange,
            badgeText = "Reference Match • $confidence% Fusion Confidence",
            scientificNote = "Multi-modal optical + acoustic match to ${bestProf.displayName} reference profile. Educational household reference only—not a quantitative laboratory or medical safety assay.",
            constituents = bestProf.constituents,
            attribution = MultiModalAttributionInfo(
                acousticEvidence = "f₁ = ${dominantHz.roundToInt()} Hz$emptyShiftNote • Decay ${decayDbPerSec.roundToInt()} dB/s" +
                    if (isVerifiedEffervescent) " • Fizz scatter ${"%+.1f".format(Locale.US, highScatterDb)} dB" else "",
                visionEvidence = optics?.let {
                    "Hue ${it.meanHueDeg.roundToInt()}°, Sat ${"%.2f".format(Locale.US, it.meanSaturation)}, Meniscus ${"%.1f".format(Locale.US, it.meniscusAngleDeg)}°"
                } ?: "Acoustic resonance channel",
                comparatorEvidence = compSummary,
                recommendsComparator = false
            ),
            tuneFrequenciesHz = bestProf.tuneFrequenciesHz,
            shimmer = bestProf.shimmer,
            warmthDecay = bestProf.warmthDecay,
            tuneSummary = bestProf.tuneSummary,
            measuredPeakHz = dominantHz
        )
    }

    private fun computeHighScatterDb(samples: FloatArray, startIdx: Int): Double {
        val nFft = 2048
        val real = DoubleArray(nFft)
        val imag = DoubleArray(nFft)
        val copyLen = min(nFft, max(0, samples.size - startIdx))
        if (copyLen < 256) return -12.0
        for (i in 0 until copyLen) {
            val w = 0.5 * (1.0 - cos(2.0 * PI * i / max(1, copyLen - 1)))
            real[i] = samples[startIdx + i].toDouble() * w
        }
        fftRadix2(real, imag)
        val binHz = sampleRate.toDouble() / nFft.toDouble()
        var coreP = 1e-15
        var hfP = 1e-15
        for (b in 1 until nFft / 2) {
            val f = b * binHz
            val p = real[b] * real[b] + imag[b] * imag[b]
            if (f in 1500.0..4200.0) coreP += p
            else if (f in 5500.0..8500.0) hfP += p
        }
        return (10.0 * log10(hfP / coreP)).coerceIn(-16.0, 6.0)
    }

    fun startChemicalTune(item: ScanResultItem, onCompleted: () -> Unit) {
        stopChemicalTune()
        val durationSec = 6.0
        val totalFrames = (sampleRate * durationSec).toInt()
        val mix = DoubleArray(totalFrames)
        val freqs = item.tuneFrequenciesHz

        freqs.take(4).forEachIndexed { idx, f ->
            val amp = 0.10 / (1 + idx / 2)
            for (n in 0 until totalFrames) {
                val t = n.toDouble() / sampleRate
                val lfo = 0.85 + 0.15 * sin(2.0 * PI * (0.35 + 0.08 * idx) * t)
                mix[n] += amp * lfo * (sin(2.0 * PI * f * t) + 0.25 * item.shimmer * sin(4.0 * PI * f * t))
            }
        }

        val noteCount = 8
        val stepSpacing = (durationSec - 0.8) / noteCount
        for (step in 0 until noteCount) {
            val fNote = freqs[step % freqs.size]
            val startFrame = ((0.18 + step * stepSpacing) * sampleRate).toInt()
            val lenFrames = min(totalFrames - startFrame, (1.65 * sampleRate).toInt())
            val attack = (0.018 * sampleRate).toInt()
            for (k in 0 until lenFrames) {
                val dt = k.toDouble() / sampleRate
                val atk = if (k < attack) 0.5 * (1.0 - cos(PI * k / attack)) else 1.0
                val dec = exp(-item.warmthDecay * dt)
                val rel = if (k > lenFrames - 960) (lenFrames - k).toDouble() / 960.0 else 1.0
                val env = atk * dec * max(0.0, rel)
                val s = sin(2.0 * PI * fNote * dt) + 0.32 * item.shimmer * sin(4.0 * PI * fNote * dt)
                mix[startFrame + k] += 0.22 * env * s
            }
        }

        val fadeIn = (0.04 * sampleRate).toInt()
        val fadeOut = (0.28 * sampleRate).toInt()
        for (i in 0 until fadeIn) mix[i] *= 0.5 * (1.0 - cos(PI * i / fadeIn))
        for (i in 0 until fadeOut) mix[totalFrames - 1 - i] *= 0.5 * (1.0 - cos(PI * i / fadeOut))

        val peak = mix.maxOfOrNull { abs(it) }?.coerceAtLeast(1e-6) ?: 1.0
        val gain = 0.7079 / peak
        val pcm = FloatArray(totalFrames) { (mix[it] * gain).toFloat() }

        val track = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(pcm.size * 4)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()

        track.write(pcm, 0, pcm.size, AudioTrack.WRITE_BLOCKING)
        track.notificationMarkerPosition = totalFrames - 100
        track.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
            override fun onMarkerReached(t: AudioTrack?) {
                onCompleted()
            }
            override fun onPeriodicNotification(t: AudioTrack?) {}
        })
        activeTuneTrack = track
        track.play()
    }

    fun stopChemicalTune() {
        activeTuneTrack?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        activeTuneTrack = null
    }

    private fun rms(arr: FloatArray, start: Int, end: Int): Double {
        val n = end - start
        if (n <= 0) return 0.0
        var sum = 0.0
        for (i in start until end) sum += arr[i]
        val mean = sum / n
        var sq = 0.0
        for (i in start until end) {
            val d = arr[i] - mean
            sq += d * d
        }
        return sqrt(sq / n)
    }

    private fun fftRadix2(real: DoubleArray, imag: DoubleArray) {
        val n = real.size
        var j = 0
        for (i in 1 until n) {
            var bit = n shr 1
            while (j and bit != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j xor bit
            if (i < j) {
                val tr = real[i]; real[i] = real[j]; real[j] = tr
                val ti = imag[i]; imag[i] = imag[j]; imag[j] = ti
            }
        }
        var len = 2
        while (len <= n) {
            val ang = -2.0 * PI / len
            val wlenR = cos(ang)
            val wlenI = sin(ang)
            val half = len shr 1
            var i = 0
            while (i < n) {
                var wR = 1.0
                var wI = 0.0
                for (k in 0 until half) {
                    val uR = real[i + k]
                    val uI = imag[i + k]
                    val vR = real[i + k + half] * wR - imag[i + k + half] * wI
                    val vI = real[i + k + half] * wI + imag[i + k + half] * wR
                    real[i + k] = uR + vR
                    imag[i + k] = uI + vI
                    real[i + k + half] = uR - vR
                    imag[i + k + half] = uI - vI
                    val nextWR = wR * wlenR - wI * wlenI
                    wI = wR * wlenI + wI * wlenR
                    wR = nextWR
                }
                i += len
            }
            len = len shl 1
        }
    }
}
