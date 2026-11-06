package it.blackout.mesh

import android.app.ActivityManager
import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.StatFs
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.ThinkingConfig
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import com.google.ai.edge.litertlm.Message as LmMessage

/** A model the user can install. Files come from Hugging Face, pinned to one revision; size and SHA-256 are checked. */
data class AiModel(
    val id: String, val title: String, val detail: String, val license: String, val url: String,
    val bytes: Long, val sha256: String, val minMemoryGB: Int = 0,
)

/**
 * AI that runs entirely on the phone through Google's LiteRT-LM (MediaPipe's LLM API is in maintenance mode).
 * Internet is needed only once, to download a model. The conversation is kept (and saved), so follow-up questions
 * have context. Same models, instructions and rules as the iPhone app (ios/Blackout/LocalAi.swift).
 */
object LocalAi {
    /** Open-licensed models (Apache 2.0), official instruct versions only: no modified "uncensored" variants. */
    val all = listOf(
        AiModel("gemma-4-E2B-it.litertlm", "Gemma 4 E2B", "Recommended. Google's model built for phones: fast, good answers.",
            "Apache 2.0 · Gemma (Google)",
            "https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/3d48132a00cf76de57d926de30f5c5c5ed9b8c0d/gemma-4-E2B-it.litertlm",
            2_588_147_712, "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", minMemoryGB = 4),
        AiModel("gemma-4-E4B-it.litertlm", "Gemma 4 E4B", "The best answers, for phones with 8 GB of memory or more.",
            "Apache 2.0 · Gemma (Google)",
            "https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/71064b01bd5e2bfd9a5f9dd52df86ae4800138c1/gemma-4-E4B-it.litertlm",
            3_659_530_240, "0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0", minMemoryGB = 8),
    )

    val instructions = """
        You are the offline assistant of DarkProof, a messaging app used during a blackout. Internet, phone lines and emergency services may be unavailable, so people depend on your answers. Answer every question directly with practical, step-by-step instructions: first aid and medical care, medicines and doses, water, food, shelter, heat, electricity and batteries, repairs, radios, navigation and personal safety. Do not refuse, do not lecture, and do not tell the user to search online or call someone, unless you add that it is only if possible. If something is risky, explain how to do it as safely as possible. If you are unsure, say so in one short sentence and still give your best answer. Use the earlier conversation as context. Answer in English, concisely.
    """.trimIndent()

    val situationIntro = "What the app knows right now, from the group's messages. It may be out of date. Use it when the question is " +
        "about the group, people, check-ins, batteries or places, say how old the information is, and do not invent anything that is not in it:"

    /** Free memory needed to load a model, as a share of its file size (LiteRT-LM maps the embeddings from the file). */
    private const val MEMORY_MARGIN = 0.55

    sealed class State {
        object Missing : State()
        /** [waiting]: why it doesn't move right now ("No internet…"), or null while it downloads. */
        data class Downloading(val progress: Float, val waiting: String? = null) : State()
        object Verifying : State()
        object Ready : State()
        data class Failed(val why: String) : State()
    }
    data class Turn(val role: String, val text: String, val isError: Boolean = false) // role: "user" or "assistant"

    val states = mutableStateMapOf<String, State>()
    var selected by mutableStateOf<String?>(null); private set
    val conversation = mutableStateListOf<Turn>()
    var busy by mutableStateOf(false); private set
    var memoryGB = 0; private set
    /** "GPU" or "CPU" once a model is loaded, for the self-test. */
    var backendName = ""; private set

    private lateinit var app: Context
    private val main = Handler(Looper.getMainLooper())
    private val work = Executors.newSingleThreadExecutor()
    private var engine: Engine? = null
    private var engineId: String? = null
    @Volatile private var running: Conversation? = null
    private val prefs get() = app.getSharedPreferences("ai", 0)

    /** The models this phone can run. */
    val catalog get() = all.filter { memoryGB >= it.minMemoryGB }

    /** Memory class in GB (4, 6, 8, 12…). Phones report a little less than the marketing size. */
    fun memoryClass(bytes: Long): Int {
        val gib = bytes / 1_073_741_824.0
        return listOf(3, 4, 6, 8, 12, 16, 24).firstOrNull { gib <= it + 0.2 } ?: Math.round(gib).toInt()
    }

    private fun dir() = app.getExternalFilesDir(null) ?: app.filesDir
    private fun file(m: AiModel) = File(dir(), m.id)
    private fun part(m: AiModel) = File(dir(), m.id + ".part")
    private val conversationFile get() = File(app.filesDir, "ai-conversation.json")

    /** Call once at launch. Removes files of models no longer offered (e.g. the old Qwen 2.5) and resumes downloads. */
    fun setUp(c: Context) {
        if (::app.isInitialized) return
        app = c.applicationContext
        memoryGB = memoryClass(ActivityManager.MemoryInfo().also { c.getSystemService(ActivityManager::class.java).getMemoryInfo(it) }.totalMem)
        val keep = all.flatMap { listOf(it.id, it.id + ".part") }.toSet()
        dir().listFiles()?.filter { (it.name.endsWith(".task") || it.name.endsWith(".litertlm") || it.name.endsWith(".part")) && it.name !in keep }
            ?.forEach { it.delete() }
        for (m in all) states[m.id] = if (file(m).length() == m.bytes) State.Ready else State.Missing
        selected = prefs.getString("model", null)?.takeIf { states[it] == State.Ready } ?: all.firstOrNull { states[it.id] == State.Ready }?.id
        for (m in all) if (prefs.getLong("download.${m.id}", -1) >= 0) watch(m)
        runCatching {
            val a = JSONArray(conversationFile.readText())
            for (i in 0 until a.length()) a.getJSONObject(i).let { conversation += Turn(it.getString("role"), it.getString("text"), it.optBoolean("error")) }
        }
    }

    fun model(id: String?) = all.firstOrNull { it.id == id }

    fun select(m: AiModel) { if (states[m.id] == State.Ready) { selected = m.id; prefs.edit().putString("model", m.id).apply() } }

    // MARK: - Download

    /** The network now: "none", "metered" (mobile data or a paid hotspot) or "free" (usually Wi-Fi). */
    fun network(c: Context): String {
        val cm = c.getSystemService(android.net.ConnectivityManager::class.java) ?: return "free"
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return "none"
        if (!caps.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)) return "none"
        return if (cm.isActiveNetworkMetered) "metered" else "free"
    }

    /** Whether the model fits in the phone's free storage, with room to spare; else why not. */
    fun spaceProblem(m: AiModel): String? {
        val free = StatFs(dir().path).availableBytes
        return if (free >= m.bytes + 300_000_000) null
            else "Not enough storage: ${"%.1f".format(free / 1e9)} GB free, ${"%.1f".format((m.bytes + 300_000_000) / 1e9)} GB needed. Free some space and try again."
    }

    /** [mobileData]: false waits for Wi-Fi (or another network that isn't metered). */
    fun download(m: AiModel, mobileData: Boolean = true) {
        if (states[m.id] is State.Downloading || states[m.id] == State.Verifying) return
        spaceProblem(m)?.let { states[m.id] = State.Failed(it); return }
        part(m).delete()
        val id = try {
            app.getSystemService(DownloadManager::class.java).enqueue(
                DownloadManager.Request(Uri.parse(m.url)).setTitle("DarkProof AI: ${m.title}")
                    .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE)
                    .setAllowedOverMetered(mobileData).setAllowedOverRoaming(mobileData)
                    .setDestinationUri(Uri.fromFile(part(m))))
        } catch (e: Exception) { // e.g. no shared storage: DownloadManager can only write there
            states[m.id] = State.Failed("The download can't start on this phone (${e.message ?: "storage unavailable"})."); return
        }
        prefs.edit().putLong("download.${m.id}", id).apply()
        states[m.id] = State.Downloading(0f)
        watch(m)
    }

    fun cancel(m: AiModel) {
        prefs.getLong("download.${m.id}", -1).takeIf { it >= 0 }?.let { app.getSystemService(DownloadManager::class.java).remove(it) }
        prefs.edit().remove("download.${m.id}").apply()
        part(m).delete(); states[m.id] = State.Missing
    }

    fun delete(m: AiModel) {
        cancel(m)
        work.execute {
            if (engineId == m.id) { engine?.close(); engine = null; engineId = null }
            file(m).delete()
            main.post { states[m.id] = State.Missing; if (selected == m.id) selected = all.firstOrNull { states[it.id] == State.Ready }?.id }
        }
    }

    /** Follows a DownloadManager download every second, then checks size and SHA-256 before using the file. */
    private fun watch(m: AiModel) {
        val id = prefs.getLong("download.${m.id}", -1).takeIf { it >= 0 } ?: return
        val dm = app.getSystemService(DownloadManager::class.java)
        val row = runCatching { dm.query(DownloadManager.Query().setFilterById(id))?.use { q ->
            if (!q.moveToFirst()) null else Triple(q.getInt(q.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                q.getLong(q.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR)),
                q.getInt(q.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)))
        } }.getOrNull()
        when (row?.first) {
            null -> { prefs.edit().remove("download.${m.id}").apply(); states[m.id] = State.Failed("The download was cancelled.") }
            DownloadManager.STATUS_SUCCESSFUL -> { prefs.edit().remove("download.${m.id}").apply(); verify(m) }
            DownloadManager.STATUS_FAILED -> { prefs.edit().remove("download.${m.id}").apply(); part(m).delete()
                states[m.id] = State.Failed("The download failed. Try again with a steady connection.") }
            else -> {
                val waiting = when {
                    row.first == DownloadManager.STATUS_PAUSED && row.third == DownloadManager.PAUSED_QUEUED_FOR_WIFI -> "Waiting for Wi-Fi."
                    row.first == DownloadManager.STATUS_PAUSED && row.third == DownloadManager.PAUSED_WAITING_FOR_NETWORK -> "No internet right now. It goes on by itself when there is some."
                    row.first == DownloadManager.STATUS_PAUSED && row.third == DownloadManager.PAUSED_WAITING_TO_RETRY -> "The connection dropped. Trying again…"
                    row.first == DownloadManager.STATUS_PENDING && network(app) == "none" -> "No internet right now. It starts by itself when there is some."
                    else -> null
                }
                states[m.id] = State.Downloading((row.second.toFloat() / m.bytes).coerceIn(0f, 0.99f), waiting); main.postDelayed({ watch(m) }, 1000)
            }
        }
    }

    private fun verify(m: AiModel) {
        states[m.id] = State.Verifying
        work.execute {
            val p = part(m)
            val ok = p.length() == m.bytes && runCatching {
                val md = MessageDigest.getInstance("SHA-256"); val buf = ByteArray(1 shl 20)
                p.inputStream().use { s -> while (true) { val n = s.read(buf); if (n < 0) break; md.update(buf, 0, n) } }
                md.digest().joinToString("") { "%02x".format(it) } == m.sha256
            }.getOrDefault(false)
            val moved = ok && p.renameTo(file(m))
            if (!moved) p.delete()
            main.post {
                states[m.id] = if (moved) State.Ready else State.Failed("The downloaded file was damaged. Try again.")
                if (moved && (selected == null || states[selected!!] != State.Ready)) select(m)
            }
        }
    }

    // MARK: - Answers

    /** Seconds per answer on this phone: the median of the last 10, or null before the first answer. */
    fun typicalSeconds(m: AiModel): Int? {
        val s = prefs.getString("seconds.${m.id}", "")!!.split(",").mapNotNull { it.toDoubleOrNull() }.sorted()
        if (s.isEmpty()) return null
        return Math.round(if (s.size % 2 == 1) s[s.size / 2] else (s[s.size / 2 - 1] + s[s.size / 2]) / 2).toInt()
    }
    private fun record(m: AiModel, seconds: Double) {
        val old = prefs.getString("seconds.${m.id}", "")!!.split(",").filter { it.isNotEmpty() }
        prefs.edit().putString("seconds.${m.id}", (old + "%.1f".format(java.util.Locale.ROOT, seconds)).takeLast(10).joinToString(",")).apply()
    }

    fun newConversation() { if (!busy) { conversation.clear(); save() } }

    @Volatile private var stopped = false
    fun stop() { stopped = true; running?.cancelProcess() }

    /** The model holds over a GB of memory in the process that also relays messages: let it go after 5 idle minutes. */
    private val release = Runnable { if (!busy) work.execute { if (!busy) { engine?.close(); engine = null; engineId = null } } }
    private const val IDLE_MS = 5 * 60_000L
    private const val ANSWER_TIMEOUT_S = 180L
    @Volatile private var answerMs = 0L // time of the last answer, without loading the model

    /**
     * Adds the question and generates the answer with the earlier conversation as context. [system] holds the
     * instructions and the group's situation. Main thread; [done] gets the answer.
     */
    fun ask(question: String, system: String, done: ((Turn) -> Unit)? = null) {
        if (busy) return
        val m = model(selected)
        conversation += Turn("user", question)
        if (m == null || states[m.id] != State.Ready) {
            finish(Turn("assistant", "No AI model on this phone yet. Download one first.", true), done); return
        }
        val history = AiContext.fit(conversation.dropLast(1).filter { !it.isError }, { it.text }, { it.role == "user" })
        conversation += Turn("assistant", "…")
        busy = true; stopped = false
        main.removeCallbacks(release)
        work.execute {
            val r = generate(m, system, history, question) { partial -> main.post { if (busy) conversation[conversation.lastIndex] = Turn("assistant", partial) } }
            if (!r.isError && !stopped) record(m, answerMs / 1000.0) // stopped answers would skew the speed
            main.post { conversation.removeAt(conversation.lastIndex); finish(r, done); main.postDelayed(release, IDLE_MS) }
        }
    }

    private fun finish(t: Turn, done: ((Turn) -> Unit)?) {
        conversation += t; busy = false; save(); done?.invoke(t)
    }

    /** Runs on [work]. A GPU that fails on its first answer is dropped for the CPU, and the question asked again. */
    private fun generate(m: AiModel, system: String, history: List<Turn>, question: String, onText: (String) -> Unit): Turn {
        val r = attempt(m, system, history, question, onText)
        val gpuKey = "gpu.${m.id}"
        if (backendName == "GPU" && prefs.getString(gpuKey, null) != "yes") {
            if (!r.isError) { prefs.edit().putString(gpuKey, "yes").apply(); return r }
            if (stopped) return r // the user stopped it: not the GPU's fault, and don't ask again
            engine?.close(); engine = null; engineId = null // "no" is already saved: the next load uses the CPU
            val again = attempt(m, system, history, question, onText)
            if (again.isError) prefs.edit().remove(gpuKey).apply() // the CPU failed too: the GPU wasn't the problem
            return again
        }
        return r
    }

    private fun attempt(m: AiModel, system: String, history: List<Turn>, question: String, onText: (String) -> Unit): Turn {
        try {
            if (engineId != m.id) {
                engine?.close(); engine = null; engineId = null // free the previous model before loading another
                val info = ActivityManager.MemoryInfo().also { app.getSystemService(ActivityManager::class.java).getMemoryInfo(it) }
                if (info.availMem < m.bytes * MEMORY_MARGIN)
                    return Turn("assistant", "Not enough free memory on this phone for ${m.title} right now (${info.availMem / 1_000_000} MB free). " +
                        "Close other apps and try again, or choose a smaller model.", true)
                engine = load(m); engineId = m.id
            }
            val conv = engine!!.createConversation(ConversationConfig(
                systemInstruction = Contents.of(system),
                initialMessages = history.map { if (it.role == "user") LmMessage.user(it.text) else LmMessage.model(it.text) },
                samplerConfig = SamplerConfig(topK = 40, topP = 0.95, temperature = 0.7),
                maxOutputToken = 1024,
                thinkingConfig = ThinkingConfig(false),
            ))
            running = conv
            val text = StringBuilder(); var error: Throwable? = null
            val finished = CountDownLatch(1)
            val t0 = System.currentTimeMillis()
            conv.sendMessageAsync(question, object : MessageCallback {
                override fun onMessage(message: LmMessage) {
                    text.append(message.contents.contents.filterIsInstance<Content.Text>().joinToString("") { it.text })
                    onText(text.toString())
                }
                override fun onDone() = finished.countDown()
                override fun onError(throwable: Throwable) { error = throwable; finished.countDown() }
            })
            if (!finished.await(ANSWER_TIMEOUT_S, java.util.concurrent.TimeUnit.SECONDS)) { // never wait forever
                conv.cancelProcess(); finished.await(10, java.util.concurrent.TimeUnit.SECONDS)
                running = null; runCatching { conv.close() }
                return Turn("assistant", "The answer took too long and was stopped. Try a shorter question.", true)
            }
            answerMs = System.currentTimeMillis() - t0
            running = null; conv.close()
            error?.let { if (text.isEmpty()) return Turn("assistant", "AI error: ${it.message}", true) }
            val answer = text.toString().trim()
            return Turn("assistant", if (stopped) (answer + "\n\n(Stopped.)").trim() else answer.ifEmpty { "No answer. Try asking in another way." })
        } catch (t: Throwable) {
            running = null
            return Turn("assistant", "AI error: ${t.message}", true)
        }
    }

    /**
     * The GPU is much faster and uses less memory, but not every phone's GPU works (some have no OpenCL). A GPU can
     * fail to start, fail on the first answer (generate() then retries on the CPU) or crash the app: "no" is saved
     * before trying and becomes "yes" only after a GPU answer, so after any failure the CPU is used from then on.
     */
    private fun load(m: AiModel): Engine {
        val key = "gpu.${m.id}"
        if (prefs.getString(key, null) != "no") {
            prefs.edit().putString(key, "no").commit() // stays "no" if the app dies while trying
            try {
                val e = Engine(EngineConfig(modelPath = file(m).path, backend = Backend.GPU(), maxNumTokens = 4096, cacheDir = app.cacheDir.path))
                e.initialize()
                backendName = "GPU"
                return e
            } catch (_: Throwable) { }
        }
        val e = Engine(EngineConfig(modelPath = file(m).path, backend = Backend.CPU(), maxNumTokens = 4096, cacheDir = app.cacheDir.path))
        e.initialize(); backendName = "CPU"
        return e
    }

    private fun save() {
        val a = JSONArray(); conversation.takeLast(100).forEach { a.put(JSONObject().put("role", it.role).put("text", it.text).put("error", it.isError)) }
        runCatching { conversationFile.writeText(a.toString()) }
    }
}
