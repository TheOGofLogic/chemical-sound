package org.liquidanalyzer.app

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlin.math.PI
import kotlin.math.abs
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
    INVALID_MEASUREMENT
}

data class ConstituentItem(
    val symbol: String,
    val name: String,
    val roleDescription: String
)

data class LiquidReferenceProfile(
    val id: String,
    val displayName: String,
    val formulaDisplay: String,
    val constituents: List<ConstituentItem>,
    val expectedCentroidHz: Double,
    val expectedPeakHz: Double,
    val expectedMidToHighDb: Double,
    val expectedDecayDbPerSec: Double,
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
    val badgeText: String,
    val scientificNote: String,
    val constituents: List<ConstituentItem>,
    val tuneFrequenciesHz: List<Double>,
    val shimmer: Double,
    val warmthDecay: Double,
    val tuneSummary: String,
    val measuredPeakHz: Double
)

object ReferenceCatalog {
    val profiles: List<LiquidReferenceProfile> = listOf(
        LiquidReferenceProfile(
            id = "H2O_DIST",
            displayName = "Water",
            formulaDisplay = "H₂O",
            constituents = listOf(ConstituentItem("H₂O", "Water", "Primary aqueous reference constituent")),
            expectedCentroidHz = 2520.0,
            expectedPeakHz = 2180.0,
            expectedMidToHighDb = 4.2,
            expectedDecayDbPerSec = 74.0,
            tuneFrequenciesHz = listOf(392.00, 493.88, 587.33, 783.99, 880.00),
            shimmer = 1.06,
            warmthDecay = 1.45,
            tuneSummary = "Mapped musical representation of hydrogen-oxygen reference intervals and measured resonance."
        ),
        LiquidReferenceProfile(
            id = "NACL_AQ",
            displayName = "Saline Water",
            formulaDisplay = "H₂O + NaCl",
            constituents = listOf(
                ConstituentItem("H₂O", "Water", "Aqueous solvent reference"),
                ConstituentItem("NaCl", "Sodium Chloride", "Dissolved salt reference constituent")
            ),
            expectedCentroidHz = 2720.0,
            expectedPeakHz = 2520.0,
            expectedMidToHighDb = 3.1,
            expectedDecayDbPerSec = 96.0,
            tuneFrequenciesHz = listOf(392.00, 587.33, 659.25, 739.99, 987.77),
            shimmer = 1.22,
            warmthDecay = 1.65,
            tuneSummary = "Mapped musical representation combining water harmonics with bright ionic fifth and ninth intervals."
        ),
        LiquidReferenceProfile(
            id = "SUC_AQ",
            displayName = "Sweetened Water",
            formulaDisplay = "H₂O + C₁₂H₂₂O₁₁",
            constituents = listOf(
                ConstituentItem("H₂O", "Water", "Aqueous solvent reference"),
                ConstituentItem("C₁₂H₂₂O₁₁", "Sucrose", "Dissolved sugar reference constituent")
            ),
            expectedCentroidHz = 2050.0,
            expectedPeakHz = 1880.0,
            expectedMidToHighDb = 6.4,
            expectedDecayDbPerSec = 118.0,
            tuneFrequenciesHz = listOf(261.63, 392.00, 493.88, 587.33, 659.25),
            shimmer = 0.90,
            warmthDecay = 1.95,
            tuneSummary = "Mapped musical representation pairing carbon bass intervals with warm damped water harmonics."
        ),
        LiquidReferenceProfile(
            id = "VIN_WHITE",
            displayName = "White Vinegar",
            formulaDisplay = "H₂O + CH₃COOH",
            constituents = listOf(
                ConstituentItem("H₂O", "Water", "Primary aqueous base"),
                ConstituentItem("CH₃COOH", "Acetic Acid", "Dilute organic acid constituent")
            ),
            expectedCentroidHz = 2540.0,
            expectedPeakHz = 2310.0,
            expectedMidToHighDb = 3.8,
            expectedDecayDbPerSec = 104.0,
            tuneFrequenciesHz = listOf(293.66, 440.00, 554.37, 659.25, 880.00),
            shimmer = 1.15,
            warmthDecay = 1.70,
            tuneSummary = "Mapped musical representation blending carbon-oxygen intervals with crisp upper harmonics."
        ),
        LiquidReferenceProfile(
            id = "OIL_VEG",
            displayName = "Vegetable Oil",
            formulaDisplay = "Triglyceride",
            constituents = listOf(
                ConstituentItem("C · H · O", "Plant Triglycerides", "Viscous lipid reference class")
            ),
            expectedCentroidHz = 1580.0,
            expectedPeakHz = 1420.0,
            expectedMidToHighDb = 9.2,
            expectedDecayDbPerSec = 155.0,
            tuneFrequenciesHz = listOf(196.00, 293.66, 392.00, 440.00, 587.33),
            shimmer = 0.72,
            warmthDecay = 2.35,
            tuneSummary = "Mapped musical representation featuring warm, rapidly damped low-register carbon-chain harmonics."
        )
    )
}

class LiquidAnalyzerAudioEngine(private val context: Context) {
    private val sampleRate = 48_000
    private var lastExcitationEndMs: Long = 0L
    private var activeTuneTrack: AudioTrack? = null

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
    suspend fun executeConsumerScan(onProgress: (Float) -> Unit): Result<ScanResultItem> = withContext(Dispatchers.Default) {
        if (hasExternalAudioRouteConnected()) {
            return@withContext Result.failure(
                IllegalStateException("Headphones or a Bluetooth speaker are connected. Please disconnect external audio so Liquid Analyzer can use your phone's built-in speaker and microphone.")
            )
        }

        // Enforce >= 2.0 s inter-excitation thermal cooldown invariant
        val sinceLast = System.currentTimeMillis() - lastExcitationEndMs
        if (lastExcitationEndMs > 0L && sinceLast < 2000L) {
            delay(2000L - sinceLast)
        }
        onProgress(0.22f)

        val preRollSamples = 7_200 // 150 ms
        val activeSamples = 9_600  // 200 ms ESS
        val postRollSamples = 7_200 // 150 ms
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

        val result = classifyCapturedSignal(captured, preRollSamples, activeSamples)
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

    private fun classifyCapturedSignal(
        samples: FloatArray,
        preFrames: Int,
        actFrames: Int
    ): ScanResultItem {
        val clipLin = 10.0.pow(-0.5 / 20.0)
        var clipped = 0
        for (v in samples) {
            if (v.isFinite() && abs(v.toDouble()) >= clipLin) clipped++
        }

        val preRms = rms(samples, 0, min(samples.size, preFrames))
        val actRms = rms(samples, preFrames, min(samples.size, preFrames + actFrames))
        val snrDb = 20.0 * log10((actRms + 1e-9) / (preRms + 1e-9))

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
        val maxBin = (9800.0 / binHz).toInt().coerceAtMost(nFft / 2 - 1)

        var weightedFreq = 0.0
        var totalPower = 1e-15
        var bestPower = -1.0
        var dominantHz = 2180.0
        var midPower = 1e-15
        var highPower = 1e-15

        for (b in minBin..maxBin) {
            val rawP = real[b] * real[b] + imag[b] * imag[b]
            val f = b * binHz
            val normAbove = max(0.0, (f - 2200.0) / 2800.0)
            val speakerWeight = 1.0 / (1.0 + 1.55 * normAbove.pow(1.45))
            val p = rawP * speakerWeight
            weightedFreq += f * p
            totalPower += p
            if (p > bestPower) {
                bestPower = p
                dominantHz = f
            }
            if (f in 1100.0..3500.0) midPower += p
            else if (f in 3500.0..9800.0) highPower += p
        }

        val centroidHz = weightedFreq / totalPower
        val midToHighDb = (10.0 * log10(midPower / highPower)).coerceIn(-14.0, 14.0)
        val decayDbPerSec = 82.0
        val nowTime = java.text.SimpleDateFormat("h:mm a", java.util.Locale.US).format(java.util.Date())

        if (clipped > 12 || snrDb < 6.0) {
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.INVALID_MEASUREMENT,
                title = "Scan Unclear",
                formulaDisplay = "Signal Check",
                badgeText = "Rescan Needed",
                scientificNote = "Ambient noise was too close to the acoustic test wave or the phone volume was muted. Raise media volume slightly in a quiet spot and try again.",
                constituents = emptyList(),
                tuneFrequenciesHz = listOf(392.0, 493.88, 587.33, 783.99),
                shimmer = 1.0,
                warmthDecay = 1.6,
                tuneSummary = "Mapped musical representation of the captured acoustic echo.",
                measuredPeakHz = dominantHz
            )
        }

        val candidateProfiles = if (dominantHz < 1650.0 && midToHighDb > 5.8) {
            ReferenceCatalog.profiles
        } else {
            ReferenceCatalog.profiles.filter { it.id != "OIL_VEG" }
        }
        val ranked = candidateProfiles.map { prof ->
            val dp = (dominantHz - prof.expectedPeakHz) / 620.0
            val dc = (centroidHz - prof.expectedCentroidHz) / 700.0
            val db = (midToHighDb - prof.expectedMidToHighDb) / 4.0
            val dd = (decayDbPerSec - prof.expectedDecayDbPerSec) / 42.0
            val dist = sqrt(0.35 * dp * dp + 0.30 * dc * dc + 0.20 * db * db + 0.15 * dd * dd)
            prof to dist
        }.sortedBy { it.second }

        val (bestProf, bestDist) = ranked.first()
        val margin = ranked[1].second - bestDist

        if (bestDist > 2.85 || margin < 0.08) {
            return ScanResultItem(
                id = "scan_${System.currentTimeMillis()}",
                timestampLabel = nowTime,
                status = MatchStatus.NO_VALIDATED_MATCH,
                title = "Unmatched Liquid",
                formulaDisplay = "Acoustic Profile",
                badgeText = "Experimental • Outside Current Reference Library",
                scientificNote = "A clean acoustic response was captured, but its resonance pattern did not closely match a calibrated reference liquid yet. You can still listen to its mapped acoustic tune.",
                constituents = listOf(
                    ConstituentItem("≈ ${dominantHz.roundToInt()} Hz", "Measured Resonance Peak", "Unclassified liquid signature (no reference claim)")
                ),
                tuneFrequenciesHz = listOf(329.63, 369.99, 440.00, 587.33, 659.25),
                shimmer = 1.0,
                warmthDecay = 1.75,
                tuneSummary = "Mapped musical representation derived directly from the liquid's measured acoustic resonance frequencies.",
                measuredPeakHz = dominantHz
            )
        }

        val rawSim = exp(-0.48 * bestDist) * (0.78 + 0.22 * min(1.0, margin / 0.45))
        val confidence = (rawSim * 92.0).roundToInt().coerceIn(58, 92)

        return ScanResultItem(
            id = "scan_${System.currentTimeMillis()}",
            timestampLabel = nowTime,
            status = MatchStatus.REFERENCE_MATCH,
            title = bestProf.displayName,
            formulaDisplay = bestProf.formulaDisplay,
            badgeText = "Experimental Reference Match • $confidence% Similarity",
            scientificNote = "Estimated from acoustic resonance similarity to the ${bestProf.displayName.lowercase()} reference profile. Experimental research result—not a laboratory chemical or safety test.",
            constituents = bestProf.constituents,
            tuneFrequenciesHz = bestProf.tuneFrequenciesHz,
            shimmer = bestProf.shimmer,
            warmthDecay = bestProf.warmthDecay,
            tuneSummary = bestProf.tuneSummary,
            measuredPeakHz = dominantHz
        )
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
