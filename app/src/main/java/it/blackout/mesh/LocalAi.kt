package it.blackout.mesh

import android.app.DownloadManager
import android.content.Context
import android.net.Uri
import com.google.mediapipe.tasks.genai.llminference.LlmInference
import java.io.File
import java.util.concurrent.Executors

/** AI that runs entirely on the phone. Internet is needed only beforehand, to download the model. */
object LocalAi {
    private const val FILE = "Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.task"
    private const val URL = "https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/$FILE"
    const val EXPECTED_BYTES = 1_500_000_000L
    private val worker = Executors.newSingleThreadExecutor()
    private var engine: LlmInference? = null

    private fun file(c: Context) = File(c.getExternalFilesDir(null), FILE)
    fun ready(c: Context) = file(c).length() > EXPECTED_BYTES
    fun download(c: Context) {
        file(c).delete()
        c.getSystemService(DownloadManager::class.java).enqueue(
            DownloadManager.Request(Uri.parse(URL)).setTitle("Blackout AI model")
                .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
                .setDestinationInExternalFilesDir(c, null, FILE))
    }
    fun ask(c: Context, prompt: String, done: (String) -> Unit) = worker.execute {
        val out = try {
            val e = engine ?: LlmInference.createFromOptions(c.applicationContext,
                LlmInference.LlmInferenceOptions.builder().setModelPath(file(c).path).setMaxTokens(1024).build()).also { engine = it }
            e.generateResponse(prompt)
        } catch (t: Throwable) { "AI error: ${t.message}" }
        done(out)
    }
}
