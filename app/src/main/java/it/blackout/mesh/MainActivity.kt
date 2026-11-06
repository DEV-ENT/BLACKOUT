package it.blackout.mesh

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.widget.*
import java.text.SimpleDateFormat
import java.util.*

class MainActivity : Activity() {
    private val prefs by lazy { getSharedPreferences("mesh", 0) }
    private lateinit var status: TextView
    private lateinit var log: TextView
    private lateinit var scroll: ScrollView
    private lateinit var aiOut: TextView
    private lateinit var dl: Button
    private lateinit var boardStatus: TextView
    private lateinit var boardButton: Button
    private val fmt = SimpleDateFormat("HH:mm", Locale.ITALY)

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        if (prefs.getString("code", null) == null) setup() else permissions()
    }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun col() = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(32), dp(16), dp(16)); setBackgroundColor(Color.BLACK) }
    private fun label(s: String) = TextView(this).apply { text = s; setTextColor(Color.WHITE); textSize = 16f }
    private fun input(h: String) = EditText(this).apply { hint = h; setTextColor(Color.WHITE); setHintTextColor(Color.GRAY) }

    private fun setup() {
        val name = input("Your name"); val code = input("Group code (same for everyone)")
        setContentView(col().apply {
            addView(label("Choose a long code: anyone who knows it can read the group's messages.")); addView(name); addView(code)
            addView(Button(context).apply { text = "Join"; setOnClickListener {
                val n = name.text.toString().trim().take(20); val c = code.text.toString().trim()
                if (n.isEmpty() || c.length < 8) { Toast.makeText(context, "Enter your name and a code of at least 8 characters", Toast.LENGTH_LONG).show(); return@setOnClickListener }
                prefs.edit().putString("name", n).putString("code", c).apply(); permissions()
            } })
        })
    }
    private fun permissions() {
        val need = when {
            Build.VERSION.SDK_INT >= 33 -> listOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.NEARBY_WIFI_DEVICES, Manifest.permission.POST_NOTIFICATIONS, Manifest.permission.ACCESS_FINE_LOCATION)
            Build.VERSION.SDK_INT >= 31 -> listOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.ACCESS_FINE_LOCATION)
            else -> listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (need.isEmpty()) launch() else requestPermissions(need.toTypedArray(), 1)
    }
    override fun onRequestPermissionsResult(r: Int, p: Array<String>, g: IntArray) {
        val required = p.filter { it != Manifest.permission.POST_NOTIFICATIONS }
        if (required.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }) launch()
        else setContentView(col().apply { addView(label("Without Bluetooth, Wi-Fi, and location permissions, the app can't connect phones. Grant them in Settings and reopen the app.")) })
    }
    private fun launch() {
        startForegroundService(Intent(this, MeshService::class.java).putExtra("name", prefs.getString("name", "")).putExtra("code", prefs.getString("code", "")))
        ui()
        MeshEngine.listener = ::refresh
        refresh()
    }
    private fun ui() {
        status = label("Starting…").apply { textSize = 14f; setTextColor(Color.rgb(120, 220, 140)) }
        log = label("").apply { setTextIsSelectable(true) }
        scroll = ScrollView(this).apply { addView(log) }
        val msg = input("Message").apply { layoutParams = LinearLayout.LayoutParams(0, -2, 1f) }
        val public = CheckBox(this).apply { text = "Send on the Public channel (everyone can read)"; setTextColor(Color.LTGRAY) }
        val chat = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(scroll, LinearLayout.LayoutParams(-1, 0, 1f))
            addView(public)
            addView(LinearLayout(context).apply {
                addView(msg)
                addView(Button(context).apply { text = "Send"; setOnClickListener {
                    val t = msg.text.toString().trim().take(1000)
                    val toPublic = public.isChecked
                    if (t.isNotEmpty() && MeshEngine.router != null) { msg.setText(""); Thread {
                        val fits = MeshEngine.send(t, toPublic)
                        if (!fits && MeshEngine.lora?.connected == true) runOnUiThread { Toast.makeText(context, "Too long for LoRa: it will travel only over Bluetooth/Wi-Fi", Toast.LENGTH_LONG).show() }
                    }.start() }
                } })
            })
        }
        aiOut = label("").apply { setTextIsSelectable(true) }
        val q = input("Question for the AI")
        dl = Button(this)
        val ai = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; visibility = View.GONE
            addView(dl); addView(q)
            addView(Button(context).apply { text = "Ask"; setOnClickListener { val t = q.text.toString().trim(); if (t.isNotEmpty()) run(t) } })
            addView(Button(context).apply { text = "Summarize messages"; setOnClickListener {
                val h = MeshEngine.snapshot().takeLast(40).joinToString("\n") { "${fmt.format(Date(it.ts))} ${it.name}: ${it.text}" }
                if (h.isNotEmpty()) run("Summarize these emergency messages in English: who is safe, who is asking for help, and what is missing. Do not make anything up.\n\n$h")
            } })
            addView(ScrollView(context).apply { addView(aiOut) }, LinearLayout.LayoutParams(-1, 0, 1f))
        }
        val radios = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val radio = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; visibility = View.GONE
            addView(label("Meshtastic radio with the EU_868 region already set. Turn it on near the phone."))
            addView(Button(context).apply { text = "Search for LoRa radios"; setOnClickListener {
                radios.removeAllViews()
                val seen = HashSet<String>()
                MeshEngine.lora?.scan { addr, nm ->
                    if (seen.add(addr)) radios.addView(Button(context).apply { text = nm; setOnClickListener {
                        MeshEngine.lora?.select(addr); Toast.makeText(context, "Connecting: if asked, enter the PIN shown on the radio", Toast.LENGTH_LONG).show()
                    } })
                }
            } })
            addView(radios)
        }
        boardStatus = label("").apply { setTextIsSelectable(true); setTextColor(Color.rgb(120, 220, 140)) }
        boardButton = Button(this).apply { setOnClickListener {
            if (WifiBoard.running) WifiBoard.stop() else WifiBoard.start(this@MainActivity) { MeshEngine.notifyUi() }
            refresh()
        } }
        val share = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL; visibility = View.GONE
            addView(label("Give DarkProof to another Android phone without internet, with Quick Share or Bluetooth."))
            addView(Button(context).apply { text = "Share the app"; setOnClickListener { ApkShare.share(this@MainActivity) } })
            addView(label("\nWi-Fi board: people without the app join this phone's Wi-Fi network and read and post Public messages in their browser."))
            addView(boardButton); addView(boardStatus)
        }
        val lan = LanTest.panel(this)?.apply { visibility = View.GONE } // null in release builds
        val pages = listOfNotNull(chat, ai, radio, share, lan)
        fun show(v: View) = pages.forEach { it.visibility = if (it === v) View.VISIBLE else View.GONE }
        val tabs = LinearLayout(this).apply {
            gravity = Gravity.CENTER
            addView(Button(context).apply { text = "Chat"; setOnClickListener { show(chat) } })
            addView(Button(context).apply { text = "AI"; setOnClickListener { show(ai); refreshAi() } })
            addView(Button(context).apply { text = "Radio"; setOnClickListener { show(radio) } })
            addView(Button(context).apply { text = "Share"; setOnClickListener { show(share) } })
            lan?.let { v -> addView(Button(context).apply { text = "LAN test"; setOnClickListener { show(v) } }) }
        }
        setContentView(col().apply {
            addView(status); addView(tabs)
            pages.forEach { addView(it, LinearLayout.LayoutParams(-1, 0, 1f)) }
        })
        refreshAi()
    }
    private fun run(prompt: String) {
        if (!LocalAi.ready(this)) { aiOut.text = "Model not downloaded: download it while internet is available."; return }
        aiOut.text = "Processing on the phone…"
        LocalAi.ask(this, "You are an offline emergency assistant. Answer in English, briefly. If you are not sure, say so. In medical emergencies, follow the instructions of emergency services.\n\n$prompt") { r -> runOnUiThread { aiOut.text = r } }
    }
    private fun refreshAi() {
        val ok = LocalAi.ready(this)
        dl.text = if (ok) "AI model ready" else "Download AI model (1.6 GB)"
        dl.isEnabled = !ok
        dl.setOnClickListener { LocalAi.download(this); Toast.makeText(this, "Download started: keep the internet connection on", Toast.LENGTH_LONG).show() }
    }
    private fun refresh() {
        if (!::status.isInitialized) return
        val n = MeshEngine.router?.peerCount() ?: 0
        val lora = MeshEngine.lora?.status ?: "LoRa: no radio"
        // "Phones connected" counts Nearby links only; Bluetooth LE and LAN test links have their own lines.
        val ble = MeshEngine.ble
        val peers = (if (MeshEngine.lora?.connected == true) n - 1 else n) - LanTest.linkCount() - (ble?.linkCount() ?: 0)
        status.text = (if (peers > 0) "Phones connected: $peers" else MeshEngine.transportStatus + " · no phones connected") + "\n" +
            (ble?.statusLine() ?: "Bluetooth LE: off") + "\n" + lora + (LanTest.statusLine()?.let { "\n$it" } ?: "")
        log.text = MeshEngine.snapshot().takeLast(300).joinToString("\n\n") { "${fmt.format(Date(it.ts))}  ${if (it.public) "[Public] " else ""}${if (it.sender == MeshEngine.deviceId) "You" else it.name}\n${it.text}" }
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
        boardButton.text = if (WifiBoard.running) "Stop the Wi-Fi board" else "Start the Wi-Fi board"
        boardStatus.text = WifiBoard.status.takeIf { it != "Off" } ?: ""
    }
    override fun onDestroy() { MeshEngine.listener = null; super.onDestroy() }
}
