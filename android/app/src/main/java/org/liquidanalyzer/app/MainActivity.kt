package org.liquidanalyzer.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.tts.TextToSpeech
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Checklist
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MenuBook
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.abs
import kotlin.math.roundToInt
import kotlin.math.sin

private val HeaderNavy = Color(0xFF0A172B)
private val ScanBlue = Color(0xFF1484FA)
private val ScanCyan = Color(0xFF2EC7FF)
private val ResultGreen1 = Color(0xFF16A34A)
private val ResultGreen2 = Color(0xFF22C55E)
private val CompOrange = Color(0xFFEA580C)
private val CompWarmBg = Color(0xFFFFF8F1)
private val FusionCoolBg = Color(0xFFF2F9FF)
private val TunePurple = Color(0xFF843BF2)
private val TuneMagenta = Color(0xFFE02E9E)

enum class PrimaryTab { SCAN, HISTORY, LEARN, MORE }
enum class ScanScreenState { HOME, COMPARATOR, AIM, SCANNING, RESULT, TUNE }

class MainActivity : ComponentActivity() {
    private var tts: TextToSpeech? = null
    private var ttsReady: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val audioEngine = LiquidAnalyzerAudioEngine(this)
        tts = TextToSpeech(this) { status ->
            if (status == TextToSpeech.SUCCESS) {
                tts?.language = Locale.US
                ttsReady = true
            }
        }
        setContent {
            MaterialTheme {
                LiquidAnalyzerConsumerApp(
                    audioEngine = audioEngine,
                    onSpeakText = { text ->
                        if (ttsReady) {
                            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "la_result_tts")
                        }
                    }
                )
            }
        }
    }

    override fun onDestroy() {
        tts?.stop()
        tts?.shutdown()
        super.onDestroy()
    }
}

@Composable
fun LiquidAnalyzerConsumerApp(
    audioEngine: LiquidAnalyzerAudioEngine,
    onSpeakText: (String) -> Unit
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var selectedTab by remember { mutableStateOf(PrimaryTab.SCAN) }
    var flowState by remember { mutableStateOf(ScanScreenState.HOME) }
    var armedComparatorStage by remember { mutableStateOf<ComparatorStage?>(null) }
    var comparatorRefreshTick by remember { mutableIntStateOf(0) }
    var scanProgress by remember { mutableFloatStateOf(0f) }
    var currentResult by remember { mutableStateOf<ScanResultItem?>(null) }
    var history by remember { mutableStateOf(listOf<ScanResultItem>()) }
    var isTunePlaying by remember { mutableStateOf(false) }
    var alertMessage by remember { mutableStateOf<String?>(null) }
    var showResearchConfirm by remember { mutableStateOf(false) }
    var showResearchConsole by remember { mutableStateOf(false) }
    var activeScanJob by remember { mutableStateOf<Job?>(null) }

    var hasCameraPerm by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        )
    }

    fun triggerScanWithStage(stage: ComparatorStage?) {
        activeScanJob = scope.launch {
            flowState = ScanScreenState.SCANNING
            scanProgress = 0.08f
            val outcome = audioEngine.executeConsumerScan(comparatorStage = stage) { scanProgress = it }
            outcome.fold(
                onSuccess = { item ->
                    currentResult = item
                    comparatorRefreshTick++
                    armedComparatorStage = null
                    if (item.status != MatchStatus.INVALID_MEASUREMENT) {
                        history = listOf(item) + history.take(29)
                    }
                    flowState = ScanScreenState.RESULT
                },
                onFailure = { err ->
                    flowState = ScanScreenState.AIM
                    alertMessage = err.message ?: "Unable to complete scan. Please try again in a quiet area."
                }
            )
        }
    }

    val permLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { perms ->
        hasCameraPerm = perms[Manifest.permission.CAMERA] == true
        if (perms[Manifest.permission.RECORD_AUDIO] == true && flowState == ScanScreenState.AIM) {
            triggerScanWithStage(armedComparatorStage)
        } else if (perms.containsKey(Manifest.permission.RECORD_AUDIO) && perms[Manifest.permission.RECORD_AUDIO] != true) {
            alertMessage = "Microphone access is required so Liquid Analyzer can measure sound-wave reflections."
        }
    }

    val emptyHz = remember(comparatorRefreshTick) { audioEngine.emptyCupPeakHz }
    val waterHz = remember(comparatorRefreshTick) { audioEngine.waterBlankPeakHz }
    val isComparatorReady = emptyHz != null && waterHz != null

    Scaffold(
        bottomBar = {
            NavigationBar(containerColor = Color.White) {
                NavigationBarItem(
                    selected = selectedTab == PrimaryTab.SCAN,
                    onClick = { selectedTab = PrimaryTab.SCAN },
                    icon = { Icon(Icons.Default.CameraAlt, contentDescription = "Scan") },
                    label = { Text("Scan") }
                )
                NavigationBarItem(
                    selected = selectedTab == PrimaryTab.HISTORY,
                    onClick = { audioEngine.stopChemicalTune(); isTunePlaying = false; selectedTab = PrimaryTab.HISTORY },
                    icon = { Icon(Icons.Default.History, contentDescription = "History") },
                    label = { Text("History") }
                )
                NavigationBarItem(
                    selected = selectedTab == PrimaryTab.LEARN,
                    onClick = { audioEngine.stopChemicalTune(); isTunePlaying = false; selectedTab = PrimaryTab.LEARN },
                    icon = { Icon(Icons.Default.MenuBook, contentDescription = "Learn") },
                    label = { Text("Learn") }
                )
                NavigationBarItem(
                    selected = selectedTab == PrimaryTab.MORE,
                    onClick = { audioEngine.stopChemicalTune(); isTunePlaying = false; selectedTab = PrimaryTab.MORE },
                    icon = { Icon(Icons.Default.MoreHoriz, contentDescription = "More") },
                    label = { Text("More") }
                )
            }
        }
    ) { innerPadding ->
        Box(modifier = Modifier.fillMaxSize().padding(innerPadding)) {
            when (selectedTab) {
                PrimaryTab.SCAN -> {
                    when (flowState) {
                        ScanScreenState.HOME -> HomeDashboardScreen(
                            isComparatorReady = isComparatorReady,
                            onStartScan = {
                                armedComparatorStage = null
                                if (!hasCameraPerm) {
                                    permLauncher.launch(arrayOf(Manifest.permission.CAMERA))
                                }
                                flowState = ScanScreenState.AIM
                            },
                            onOpenComparator = {
                                flowState = ScanScreenState.COMPARATOR
                            }
                        )
                        ScanScreenState.COMPARATOR -> ComparatorWizardScreen(
                            emptyCupHz = emptyHz,
                            waterBlankHz = waterHz,
                            onClose = { flowState = ScanScreenState.HOME },
                            onReset = {
                                audioEngine.clearComparatorBaselines()
                                comparatorRefreshTick++
                            },
                            onSelectStage = { stage ->
                                armedComparatorStage = stage
                                if (!hasCameraPerm) {
                                    permLauncher.launch(arrayOf(Manifest.permission.CAMERA))
                                }
                                flowState = ScanScreenState.AIM
                            }
                        )
                        ScanScreenState.AIM -> AimScreen(
                            hasCameraPerm = hasCameraPerm,
                            armedStage = armedComparatorStage,
                            onBack = {
                                armedComparatorStage = null
                                flowState = ScanScreenState.HOME
                            },
                            onGear = { selectedTab = PrimaryTab.MORE },
                            onScan = {
                                val hasMic = ContextCompat.checkSelfPermission(
                                    context, Manifest.permission.RECORD_AUDIO
                                ) == PackageManager.PERMISSION_GRANTED
                                if (!hasMic) {
                                    permLauncher.launch(arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA))
                                } else {
                                    triggerScanWithStage(armedComparatorStage)
                                }
                            }
                        )
                        ScanScreenState.SCANNING -> ScanningScreen(
                            progress = scanProgress,
                            onCancel = {
                                activeScanJob?.cancel()
                                flowState = ScanScreenState.AIM
                            }
                        )
                        ScanScreenState.RESULT -> currentResult?.let { item ->
                            ResultScreen(
                                item = item,
                                onBack = { flowState = ScanScreenState.HOME },
                                onGear = { selectedTab = PrimaryTab.MORE },
                                onSpeak = {
                                    onSpeakText("${item.title}. ${item.badgeText}. Nominal pH: ${item.nominalPhRange}.")
                                },
                                onOpenComparator = { flowState = ScanScreenState.COMPARATOR },
                                onPlayTune = {
                                    isTunePlaying = false
                                    flowState = ScanScreenState.TUNE
                                },
                                onScanAnother = {
                                    armedComparatorStage = null
                                    flowState = ScanScreenState.AIM
                                }
                            )
                        }
                        ScanScreenState.TUNE -> currentResult?.let { item ->
                            ChemicalTuneScreen(
                                item = item,
                                isPlaying = isTunePlaying,
                                onTogglePlay = {
                                    if (isTunePlaying) {
                                        audioEngine.stopChemicalTune()
                                        isTunePlaying = false
                                    } else {
                                        isTunePlaying = true
                                        audioEngine.startChemicalTune(item) {
                                            isTunePlaying = false
                                        }
                                    }
                                },
                                onBack = {
                                    audioEngine.stopChemicalTune()
                                    isTunePlaying = false
                                    flowState = ScanScreenState.RESULT
                                }
                            )
                        }
                    }
                }
                PrimaryTab.HISTORY -> HistoryScreen(
                    items = history,
                    onSelect = { item ->
                        currentResult = item
                        selectedTab = PrimaryTab.SCAN
                        flowState = ScanScreenState.RESULT
                    },
                    onClear = { history = emptyList() }
                )
                PrimaryTab.LEARN -> LearnScreen()
                PrimaryTab.MORE -> MoreScreen(
                    onOpenResearchGate = { showResearchConfirm = true }
                )
            }
        }
    }

    if (alertMessage != null) {
        AlertDialog(
            onDismissRequest = { alertMessage = null },
            confirmButton = {
                TextButton(onClick = { alertMessage = null }) { Text("OK") }
            },
            title = { Text("Scan Notice") },
            text = { Text(alertMessage ?: "") }
        )
    }

    if (showResearchConfirm) {
        AlertDialog(
            onDismissRequest = { showResearchConfirm = false },
            confirmButton = {
                Button(onClick = {
                    showResearchConfirm = false
                    showResearchConsole = true
                }) { Text("Open Research Console") }
            },
            dismissButton = {
                TextButton(onClick = { showResearchConfirm = false }) { Text("Cancel") }
            },
            title = { Text("Open Research & Developer Mode?") },
            text = {
                Text("Research Mode exposes controlled bench protocol status and raw diagnostic counters intended for validation studies.")
            }
        )
    }

    if (showResearchConsole) {
        AlertDialog(
            onDismissRequest = { showResearchConsole = false },
            confirmButton = {
                TextButton(onClick = { showResearchConsole = false }) { Text("Exit Research Mode") }
            },
            title = { Text("Research & Bench Mode (v0.5.0)") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text("Mode: MODE_AF Multi-Modal Acoustic + Optical Fusion")
                    Text("Excitation: 48 kHz ESS (400 Hz – 14 kHz) + Pre-Roll HF Gate")
                    Text("3-Step Comparator Ready: ${if (isComparatorReady) "YES" else "NO"}")
                    Text("Recorded Session Scans: ${history.size}")
                }
            }
        )
    }
}

@Composable
private fun TopHeaderBar(
    title: String,
    onBack: (() -> Unit)? = null,
    onGear: (() -> Unit)? = null
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(HeaderNavy)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        if (onBack != null) {
            IconButton(onClick = onBack, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Default.ArrowBack, contentDescription = "Back", tint = Color.White)
            }
        } else {
            Spacer(modifier = Modifier.size(32.dp))
        }

        Text(title, color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 17.sp)

        if (onGear != null) {
            IconButton(onClick = onGear, modifier = Modifier.size(32.dp)) {
                Icon(Icons.Default.Settings, contentDescription = "Settings", tint = Color.White)
            }
        } else {
            Spacer(modifier = Modifier.size(32.dp))
        }
    }
}

@Composable
private fun HomeDashboardScreen(
    isComparatorReady: Boolean,
    onStartScan: () -> Unit,
    onOpenComparator: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(Color(0xFFF2F8FF), Color.White, Color(0xFFE8F4FF))))
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)
    ) {
        Column {
            Text("Liquid Analyzer", fontSize = 30.sp, fontWeight = FontWeight.ExtraBold, color = HeaderNavy)
            Text("See the liquid. Hear the science.", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = Color(0xFF386B9E))
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                "On-device optical + acoustic screening for colored, cloudy, and fizzy household liquids, plus guided cup comparison.",
                fontSize = 14.sp,
                color = Color(0xFF334155)
            )
        }

        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            StepPill(Modifier.weight(1f), "1", "AIM", ScanBlue)
            StepPill(Modifier.weight(1f), "2", "SCAN", ResultGreen1)
            StepPill(Modifier.weight(1f), "3", "SEE", CompOrange)
            StepPill(Modifier.weight(1f), "4", "LISTEN", TunePurple)
        }

        Button(
            onClick = onStartScan,
            shape = RoundedCornerShape(18.dp),
            colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
            contentPadding = PaddingValues(),
            modifier = Modifier
                .fillMaxWidth()
                .height(58.dp)
                .background(Brush.horizontalGradient(listOf(ScanBlue, ScanCyan)), RoundedCornerShape(18.dp))
        ) {
            Icon(Icons.Default.CameraAlt, contentDescription = null, tint = Color.White)
            Spacer(modifier = Modifier.width(10.dp))
            Text("Start Liquid Scan", color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 18.sp)
        }

        // Guided 3-Step Cup Comparator Card (v0.5.0 Parity)
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .border(1.dp, ResultGreen1.copy(alpha = 0.30f), RoundedCornerShape(18.dp))
                .clickable { onOpenComparator() },
            shape = RoundedCornerShape(18.dp),
            colors = CardDefaults.cardColors(containerColor = Color.White)
        ) {
            Row(
                modifier = Modifier.padding(16.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Box(
                    modifier = Modifier
                        .size(40.dp)
                        .background(ResultGreen1.copy(alpha = 0.14f), CircleShape),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Default.Checklist, contentDescription = null, tint = ResultGreen1)
                }
                Spacer(modifier = Modifier.width(12.dp))
                Column(modifier = Modifier.weight(1f)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("3-Step Cup Comparator", fontWeight = FontWeight.Bold, fontSize = 16.sp, color = HeaderNavy)
                        if (isComparatorReady) {
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(
                                "READY",
                                color = ResultGreen1,
                                fontWeight = FontWeight.Bold,
                                fontSize = 10.sp,
                                modifier = Modifier
                                    .clip(CircleShape)
                                    .background(ResultGreen1.copy(alpha = 0.14f))
                                    .padding(horizontal = 8.dp, vertical = 2.dp)
                            )
                        }
                    }
                    Text(
                        "Stationary same-cup comparator (Empty → Water → Sample) for clear liquids.",
                        fontSize = 12.sp,
                        color = Color(0xFF475569)
                    )
                }
                Text("›", fontSize = 22.sp, color = Color.Gray)
            }
        }

        LearnCardItem("Multi-Modal Sensor Fusion", "Combines real-time camera color, turbidity & meniscus analysis with acoustic resonance.", ScanBlue)
        LearnCardItem("Smart Empty-Cup Safety", "Verifies real liquid coupling to prevent false matches on dry glassware or flat surfaces.", ResultGreen1)
        LearnCardItem("Composition & pH Reference", "Explore nominal formulas, pH ranges, and literature breakdowns offline.", CompOrange)
        LearnCardItem("Chemical Tune & Spoken Readout", "Play polyphonic chemical chords and hear instant spoken result summaries.", TunePurple)
    }
}

@Composable
private fun ComparatorWizardScreen(
    emptyCupHz: Double?,
    waterBlankHz: Double?,
    onClose: () -> Unit,
    onReset: () -> Unit,
    onSelectStage: (ComparatorStage) -> Unit
) {
    Column(modifier = Modifier.fillMaxSize().background(Color(0xFFF1F5FB))) {
        TopHeaderBar(title = "3-Step Cup Comparator", onBack = onClose)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Text("Stationary Clear-Liquid Comparator", fontSize = 22.sp, fontWeight = FontWeight.ExtraBold, color = HeaderNavy)
            Text(
                "Keep your phone and cup at a fixed position to compare clear or fizzy household liquids against your Empty Cup and Water Blank.",
                fontSize = 13.sp,
                color = Color(0xFF475569)
            )

            ComparatorStepCard(
                stepNum = "1",
                title = "Step 1 • Scan Empty Cup",
                statusLabel = if (emptyCupHz != null) "LOCKED (${emptyCupHz.roundToInt()} Hz)" else "REQUIRED",
                isComplete = emptyCupHz != null,
                description = "Place your dry empty glass in position to lock its unloaded shell resonance.",
                buttonTitle = "Scan & Lock Empty Cup",
                onAction = { onSelectStage(ComparatorStage.EMPTY_CUP) }
            )

            ComparatorStepCard(
                stepNum = "2",
                title = "Step 2 • Scan Water Blank",
                statusLabel = if (waterBlankHz != null) "LOCKED (${waterBlankHz.roundToInt()} Hz)" else "NEXT",
                isComplete = waterBlankHz != null,
                description = "Pour clean water to a repeatable fill mark and lock the aqueous mass-loading baseline.",
                buttonTitle = "Scan & Lock Water Blank",
                onAction = { onSelectStage(ComparatorStage.WATER_BLANK) }
            )

            ComparatorStepCard(
                stepNum = "3",
                title = "Step 3 • Scan Test Liquid",
                statusLabel = if (emptyCupHz != null && waterBlankHz != null) "READY" else "LOCK STEPS 1–2 FIRST",
                isComplete = false,
                description = "Empty, dry, and pour your test liquid to the same fill mark to evaluate ΔF/F_water, meniscus, and bubble scatter.",
                buttonTitle = "Scan & Identify Test Liquid",
                onAction = { onSelectStage(ComparatorStage.TEST_SAMPLE) }
            )

            if (emptyCupHz != null || waterBlankHz != null) {
                TextButton(onClick = onReset, modifier = Modifier.align(Alignment.CenterHorizontally)) {
                    Text("Reset Saved Cup Baselines", color = Color.Red)
                }
            }
        }
    }
}

@Composable
private fun ComparatorStepCard(
    stepNum: String,
    title: String,
    statusLabel: String,
    isComplete: Boolean,
    description: String,
    buttonTitle: String,
    onAction: () -> Unit
) {
    val accent = if (isComplete) ResultGreen1 else ScanBlue
    Card(
        shape = RoundedCornerShape(18.dp),
        colors = CardDefaults.cardColors(containerColor = Color.White),
        modifier = Modifier.fillMaxWidth().border(1.dp, accent.copy(alpha = 0.30f), RoundedCornerShape(18.dp))
    ) {
        Column(modifier = Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween, modifier = Modifier.fillMaxWidth()) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier.size(28.dp).background(accent, CircleShape),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(if (isComplete) "✓" else stepNum, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    }
                    Spacer(modifier = Modifier.width(10.dp))
                    Text(title, fontWeight = FontWeight.Bold, fontSize = 15.sp, color = HeaderNavy)
                }
                Text(
                    statusLabel,
                    color = accent,
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(accent.copy(alpha = 0.12f))
                        .padding(horizontal = 8.dp, vertical = 3.dp)
                )
            }
            Text(description, fontSize = 12.sp, color = Color(0xFF475569))
            Button(
                onClick = onAction,
                shape = RoundedCornerShape(12.dp),
                colors = ButtonDefaults.buttonColors(containerColor = accent),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(buttonTitle, color = Color.White, fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
private fun StepPill(modifier: Modifier, num: String, label: String, color: Color) {
    Card(modifier = modifier, shape = RoundedCornerShape(14.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Box(
                modifier = Modifier.size(30.dp).background(color, CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text(num, color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 14.sp)
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(label, fontWeight = FontWeight.Bold, fontSize = 12.sp, color = HeaderNavy)
        }
    }
}

@Composable
private fun AimScreen(
    hasCameraPerm: Boolean,
    armedStage: ComparatorStage?,
    onBack: () -> Unit,
    onGear: () -> Unit,
    onScan: () -> Unit
) {
    val scanLabel = when (armedStage) {
        ComparatorStage.EMPTY_CUP -> "SCAN EMPTY CUP"
        ComparatorStage.WATER_BLANK -> "SCAN WATER BLANK"
        ComparatorStage.TEST_SAMPLE -> "SCAN TEST LIQUID"
        null -> "SCAN 1×"
    }

    Column(modifier = Modifier.fillMaxSize()) {
        TopHeaderBar(title = "Liquid Analyzer", onBack = onBack, onGear = onGear)

        Box(modifier = Modifier.fillMaxSize().background(Color(0xFF0E1B31))) {
            if (hasCameraPerm) {
                CameraPreviewBox(modifier = Modifier.fillMaxSize())
            }

            Column(
                modifier = Modifier.fillMaxSize().padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Box(
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.65f))
                        .padding(horizontal = 16.dp, vertical = 6.dp)
                ) {
                    Text(
                        if (armedStage != null) "3-Step Comparator Active" else "MODE_AF • Optical + Acoustic Fusion",
                        color = ScanCyan,
                        fontWeight = FontWeight.Bold,
                        fontSize = 12.sp
                    )
                }

                Canvas(modifier = Modifier.size(220.dp, 240.dp)) {
                    val arm = 36.dp.toPx()
                    val stroke = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round)
                    val w = size.width
                    val h = size.height
                    drawLine(ScanCyan, Offset(0f, 0f), Offset(arm, 0f), strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(ScanCyan, Offset(0f, 0f), Offset(0f, arm), strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(ScanCyan, Offset(w - arm, 0f), Offset(w, 0f), strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(ScanCyan, Offset(w, 0f), Offset(w, arm), strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(ScanCyan, Offset(0f, h - arm), Offset(0f, h), strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(ScanCyan, Offset(0f, h), Offset(arm, h), strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(ScanCyan, Offset(w - arm, h), Offset(w, h), strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(ScanCyan, Offset(w, h - arm), Offset(w, h), strokeWidth = stroke.width, cap = StrokeCap.Round)
                }

                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Button(
                        onClick = onScan,
                        shape = CircleShape,
                        colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
                        contentPadding = PaddingValues(),
                        modifier = Modifier
                            .width(260.dp)
                            .height(54.dp)
                            .background(Brush.horizontalGradient(listOf(ScanBlue, ScanCyan)), CircleShape)
                    ) {
                        Text(scanLabel, color = Color.White, fontWeight = FontWeight.ExtraBold, fontSize = 18.sp)
                    }
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        "On-device optical chromaticity + 48 kHz acoustic resonance",
                        color = Color.White,
                        fontSize = 11.sp
                    )
                }
            }
        }
    }
}

@Composable
private fun CameraPreviewBox(modifier: Modifier = Modifier) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val analysisExecutor = remember { Executors.newSingleThreadExecutor() }

    DisposableEffect(Unit) {
        onDispose { analysisExecutor.shutdown() }
    }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val previewView = PreviewView(ctx)
            val future = ProcessCameraProvider.getInstance(ctx)
            future.addListener({
                runCatching {
                    val provider = future.get()
                    val preview = Preview.Builder().build().also {
                        it.setSurfaceProvider(previewView.surfaceProvider)
                    }
                    val imageAnalysis = ImageAnalysis.Builder()
                        .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                        .build()
                        .also { analysis ->
                            analysis.setAnalyzer(analysisExecutor) { proxy ->
                                LiveCameraOpticsAnalyzer.analyzeFrame(proxy)
                            }
                        }
                    provider.unbindAll()
                    provider.bindToLifecycle(
                        lifecycleOwner,
                        CameraSelector.DEFAULT_BACK_CAMERA,
                        preview,
                        imageAnalysis
                    )
                }
            }, ContextCompat.getMainExecutor(ctx))
            previewView
        }
    )
}

@Composable
private fun ScanningScreen(progress: Float, onCancel: () -> Unit) {
    val inf = rememberInfiniteTransition(label = "scanWave")
    val phase by inf.animateFloat(
        initialValue = 0f,
        targetValue = 6.28f,
        animationSpec = infiniteRepeatable(tween(1100, easing = LinearEasing), RepeatMode.Restart),
        label = "phase"
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(Color(0xFF050A17), Color(0xFF0B1C38), Color(0xFF050A17)))),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        TopHeaderBar(title = "Liquid Analyzer")
        Spacer(modifier = Modifier.weight(1f))

        Box(
            modifier = Modifier
                .size(180.dp)
                .border(3.5.dp, ScanCyan, CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.size(120.dp, 84.dp)) {
                val count = 13
                val barW = 5.dp.toPx()
                val gap = (size.width - count * barW) / (count - 1)
                for (i in 0 until count) {
                    val dist = abs(i - 6f) / 6f
                    val env = (1f - dist * dist * 0.8f).coerceAtLeast(0.2f)
                    val h = size.height * env * (0.45f + 0.50f * abs(sin(phase + i * 0.55f)))
                    drawRoundRect(
                        color = ScanCyan,
                        topLeft = Offset(i * (barW + gap), (size.height - h) / 2f),
                        size = Size(barW, h),
                        cornerRadius = CornerRadius(barW / 2f, barW / 2f)
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(24.dp))
        Text("Analyzing Liquid...", color = Color.White, fontSize = 23.sp, fontWeight = FontWeight.Bold)
        Spacer(modifier = Modifier.height(6.dp))
        Text("Fusing optical colorimetry & acoustic resonance", color = Color.White.copy(alpha = 0.7f), fontSize = 14.sp)

        Spacer(modifier = Modifier.height(28.dp))
        LinearProgressIndicator(
            progress = { progress.coerceIn(0.06f, 1f) },
            modifier = Modifier.fillMaxWidth(0.75f).height(10.dp).clip(CircleShape),
            color = ScanCyan,
            trackColor = Color.White.copy(alpha = 0.16f)
        )

        Spacer(modifier = Modifier.weight(1f))
        TextButton(
            onClick = onCancel,
            modifier = Modifier
                .padding(bottom = 28.dp)
                .clip(CircleShape)
                .background(Color.White.copy(alpha = 0.12f))
                .padding(horizontal = 18.dp)
        ) {
            Text("Cancel", color = Color.White, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
private fun ResultScreen(
    item: ScanResultItem,
    onBack: () -> Unit,
    onGear: () -> Unit,
    onSpeak: () -> Unit,
    onOpenComparator: () -> Unit,
    onPlayTune: () -> Unit,
    onScanAnother: () -> Unit
) {
    val isMatch = item.status == MatchStatus.REFERENCE_MATCH
    val bannerTitle = when (item.status) {
        MatchStatus.REFERENCE_MATCH -> "Reference Match"
        MatchStatus.EMPTY_CONTAINER -> "Empty Container Safety Gate"
        MatchStatus.NON_LIQUID_SURFACE -> "Surface Safety Gate"
        else -> "Multi-Modal Profile"
    }

    Column(modifier = Modifier.fillMaxSize().background(Color(0xFFF1F5FB))) {
        TopHeaderBar(title = "Liquid Analyzer", onBack = onBack, onGear = onGear)

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(16.dp)
        ) {
            Card(
                shape = RoundedCornerShape(24.dp),
                colors = CardDefaults.cardColors(containerColor = Color.White),
                elevation = CardDefaults.cardElevation(defaultElevation = 6.dp)
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(
                                Brush.horizontalGradient(
                                    if (isMatch) listOf(ResultGreen1, ResultGreen2)
                                    else listOf(CompOrange, TunePurple)
                                )
                            )
                            .padding(horizontal = 20.dp, vertical = 14.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(bannerTitle, color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                        Icon(
                            if (isMatch) Icons.Default.CheckCircle else Icons.Default.Info,
                            contentDescription = null,
                            tint = Color.White
                        )
                    }

                    Column(
                        modifier = Modifier.padding(18.dp),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(item.title, fontSize = 25.sp, fontWeight = FontWeight.ExtraBold, color = HeaderNavy)
                            Spacer(modifier = Modifier.width(8.dp))
                            IconButton(
                                onClick = onSpeak,
                                modifier = Modifier
                                    .size(34.dp)
                                    .background(ScanBlue.copy(alpha = 0.12f), CircleShape)
                            ) {
                                Icon(Icons.Default.VolumeUp, contentDescription = "Speak Result", tint = ScanBlue, modifier = Modifier.size(18.dp))
                            }
                        }
                        Text(item.formulaDisplay, fontSize = 16.sp, color = Color.DarkGray, fontWeight = FontWeight.SemiBold)

                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            item.badgeText,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = if (isMatch) ResultGreen1 else CompOrange,
                            modifier = Modifier
                                .clip(CircleShape)
                                .background((if (isMatch) ResultGreen1 else CompOrange).copy(alpha = 0.12f))
                                .padding(horizontal = 12.dp, vertical = 5.dp)
                        )

                        if (item.constituents.isNotEmpty()) {
                            Spacer(modifier = Modifier.height(16.dp))
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(CompWarmBg)
                                    .border(1.dp, CompOrange.copy(alpha = 0.3f), RoundedCornerShape(16.dp))
                                    .padding(14.dp)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Text("Reference Composition & pH", color = CompOrange, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                    Text("Literature Profile", color = CompOrange, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                                }
                                HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                                item.constituents.forEach { c ->
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp),
                                        horizontalArrangement = Arrangement.SpaceBetween
                                    ) {
                                        Text(c.symbol, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = CompOrange)
                                        Column(horizontalAlignment = Alignment.End) {
                                            Text(c.name, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = HeaderNavy)
                                            Text(c.roleDescription, fontSize = 11.sp, color = Color.Gray)
                                        }
                                    }
                                }
                                HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))
                                Text("Nominal pH: ${item.nominalPhRange}", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = HeaderNavy)
                            }
                        }

                        item.attribution?.let { attr ->
                            Spacer(modifier = Modifier.height(14.dp))
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clip(RoundedCornerShape(16.dp))
                                    .background(FusionCoolBg)
                                    .border(1.dp, ScanBlue.copy(alpha = 0.25f), RoundedCornerShape(16.dp))
                                    .padding(14.dp),
                                verticalArrangement = Arrangement.spacedBy(6.dp)
                            ) {
                                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                                    Text("Multi-Modal Sensor Fusion", color = ScanBlue, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                    Text("v0.5.0", color = ResultGreen1, fontWeight = FontWeight.Bold, fontSize = 11.sp)
                                }
                                Text("• Acoustic: ${attr.acousticEvidence}", fontSize = 12.sp, color = Color(0xFF334155))
                                Text("• Optical: ${attr.visionEvidence}", fontSize = 12.sp, color = Color(0xFF334155))
                                if (!attr.comparatorEvidence.isNullOrBlank()) {
                                    Text("• Comparator: ${attr.comparatorEvidence}", fontSize = 12.sp, color = ResultGreen1, fontWeight = FontWeight.SemiBold)
                                }
                                if (attr.recommendsComparator) {
                                    Button(
                                        onClick = onOpenComparator,
                                        shape = RoundedCornerShape(12.dp),
                                        colors = ButtonDefaults.buttonColors(containerColor = ScanBlue),
                                        modifier = Modifier.fillMaxWidth().padding(top = 4.dp)
                                    ) {
                                        Text("Open 3-Step Cup Comparator", color = Color.White, fontWeight = FontWeight.Bold)
                                    }
                                }
                            }
                        }

                        Spacer(modifier = Modifier.height(12.dp))
                        Text(
                            item.scientificNote,
                            fontSize = 12.sp,
                            color = Color.Gray,
                            textAlign = TextAlign.Center
                        )

                        if (item.status == MatchStatus.REFERENCE_MATCH || item.status == MatchStatus.NO_VALIDATED_MATCH) {
                            Spacer(modifier = Modifier.height(16.dp))
                            Button(
                                onClick = onPlayTune,
                                shape = RoundedCornerShape(16.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = Color.Transparent),
                                contentPadding = PaddingValues(),
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(52.dp)
                                    .background(
                                        Brush.horizontalGradient(listOf(ScanBlue, TunePurple, TuneMagenta)),
                                        RoundedCornerShape(16.dp)
                                    )
                            ) {
                                Icon(Icons.Default.MusicNote, contentDescription = null, tint = Color.White)
                                Spacer(modifier = Modifier.width(8.dp))
                                Text("Play Chemical Tune", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 17.sp)
                            }
                        }

                        Spacer(modifier = Modifier.height(8.dp))
                        TextButton(onClick = onScanAnother) {
                            Text("Scan Another Liquid", color = ScanBlue, fontWeight = FontWeight.SemiBold)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ChemicalTuneScreen(
    item: ScanResultItem,
    isPlaying: Boolean,
    onTogglePlay: () -> Unit,
    onBack: () -> Unit
) {
    val inf = rememberInfiniteTransition(label = "rainbow")
    val phase by inf.animateFloat(
        initialValue = 0f,
        targetValue = 6.28f,
        animationSpec = infiniteRepeatable(tween(1400, easing = LinearEasing), RepeatMode.Restart),
        label = "rainbowPhase"
    )

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Brush.verticalGradient(listOf(Color(0xFF040714), Color(0xFF0E112E), Color(0xFF040714)))),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        TopHeaderBar(title = "Chemical Tune", onBack = onBack)
        Spacer(modifier = Modifier.weight(1f))

        Canvas(modifier = Modifier.fillMaxWidth().height(165.dp).padding(horizontal = 18.dp)) {
            val count = 31
            val barW = 5.dp.toPx()
            val gap = (size.width - count * barW) / (count - 1)
            for (i in 0 until count) {
                val frac = i.toFloat() / (count - 1)
                val hue = (230f - frac * 290f).let { if (it < 0f) it + 360f else it }
                val barColor = Color.hsv(hue, 0.85f, 1.0f)
                val anim = if (isPlaying) (0.45f + 0.55f * abs(sin(phase + i * 0.45f))) else (0.55f + 0.30f * abs(sin(i * 0.6f)))
                val h = (size.height * anim).coerceAtLeast(16f)
                drawRoundRect(
                    color = barColor,
                    topLeft = Offset(i * (barW + gap), (size.height - h) / 2f),
                    size = Size(barW, h),
                    cornerRadius = CornerRadius(barW / 2f, barW / 2f)
                )
            }
        }

        Spacer(modifier = Modifier.height(24.dp))
        Text(item.formulaDisplay, color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.ExtraBold, textAlign = TextAlign.Center)
        Text("${item.title} • Chemical Tune", color = Color(0xFFC084FC), fontSize = 17.sp, fontWeight = FontWeight.Bold)
        Spacer(modifier = Modifier.height(8.dp))
        Text(
            item.tuneSummary,
            color = Color.White.copy(alpha = 0.74f),
            fontSize = 13.sp,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 28.dp)
        )

        Spacer(modifier = Modifier.height(28.dp))
        IconButton(
            onClick = onTogglePlay,
            modifier = Modifier
                .size(76.dp)
                .border(2.5.dp, TunePurple, CircleShape)
                .background(Color(0xFF1E1B4B), CircleShape)
        ) {
            Icon(
                if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                contentDescription = if (isPlaying) "Pause" else "Play",
                tint = Color.White,
                modifier = Modifier.size(34.dp)
            )
        }
        Spacer(modifier = Modifier.height(8.dp))
        Text(if (isPlaying) "Pause" else "Play", color = Color.White.copy(alpha = 0.8f), fontSize = 12.sp)
        Spacer(modifier = Modifier.weight(1f))
    }
}

@Composable
private fun HistoryScreen(
    items: List<ScanResultItem>,
    onSelect: (ScanResultItem) -> Unit,
    onClear: () -> Unit
) {
    Column(modifier = Modifier.fillMaxSize().background(Color(0xFFF1F5FB))) {
        Row(
            modifier = Modifier.fillMaxWidth().background(Color.White).padding(16.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text("History", fontSize = 22.sp, fontWeight = FontWeight.ExtraBold)
            if (items.isNotEmpty()) {
                TextButton(onClick = onClear) { Text("Clear", color = Color.Red) }
            }
        }

        if (items.isEmpty()) {
            Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("No scans yet. Tap Scan to analyze a liquid.", color = Color.Gray)
            }
        } else {
            Column(modifier = Modifier.verticalScroll(rememberScrollState()).padding(16.dp)) {
                items.forEach { item ->
                    Card(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 10.dp)
                            .clickable { onSelect(item) },
                        shape = RoundedCornerShape(16.dp),
                        colors = CardDefaults.cardColors(containerColor = Color.White)
                    ) {
                        Row(
                            modifier = Modifier.padding(14.dp).fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Text(item.title, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                                Text("${item.formulaDisplay} • ${item.timestampLabel}", color = Color.Gray, fontSize = 12.sp)
                            }
                            Icon(Icons.Default.MusicNote, contentDescription = null, tint = TunePurple)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LearnScreen() {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFF1F5FB))
            .verticalScroll(rememberScrollState())
            .padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("Learn", fontSize = 24.sp, fontWeight = FontWeight.ExtraBold)
        Text("See the liquid. Hear the science.", color = Color.DarkGray, fontWeight = FontWeight.SemiBold)

        LearnCardItem("1. Multi-Modal Camera + Sound", "Camera colorimetry, turbidity, and meniscus geometry fuse with 48 kHz container resonance and fizz scatter.", ScanBlue)
        LearnCardItem("2. 3-Step Cup Comparator", "For clear household liquids, lock Empty Cup → Water Blank → Sample in a stationary glass.", ResultGreen1)
        LearnCardItem("3. Reference Composition & pH", "Explore literature-based formulas and nominal pH profiles. Educational household tool—never a clinical or safety test.", CompOrange)
        LearnCardItem("4. Chemical Tune & Voice Readout", "Audition mapped polyphonic chords and hear instant spoken summaries 100% offline.", TunePurple)
    }
}

@Composable
private fun LearnCardItem(title: String, body: String, accent: Color) {
    Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(title, color = accent, fontWeight = FontWeight.Bold, fontSize = 15.sp)
            Spacer(modifier = Modifier.height(4.dp))
            Text(body, color = Color.DarkGray, fontSize = 13.sp)
        }
    }
}

@Composable
private fun MoreScreen(onOpenResearchGate: () -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFFF1F5FB))
            .verticalScroll(rememberScrollState())
            .padding(18.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)
    ) {
        Text("More", fontSize = 24.sp, fontWeight = FontWeight.ExtraBold)

        Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text("100% Private & Educational", fontWeight = FontWeight.Bold, fontSize = 14.sp)
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    "All optical and acoustic signal processing runs locally on your Android device with zero cloud uploads. Reference profiles are for educational household exploration—never clinical diagnostics, drinkability, or safety verification.",
                    fontSize = 13.sp,
                    color = Color.DarkGray
                )
            }
        }

        Card(shape = RoundedCornerShape(16.dp), colors = CardDefaults.cardColors(containerColor = Color.White)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onOpenResearchGate() }
                    .padding(16.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Science, contentDescription = null, tint = ScanBlue)
                    Spacer(modifier = Modifier.width(10.dp))
                    Text("Research & Developer Mode", color = ScanBlue, fontWeight = FontWeight.SemiBold)
                }
                Text("›", fontSize = 20.sp, color = Color.Gray)
            }
        }
    }
}
