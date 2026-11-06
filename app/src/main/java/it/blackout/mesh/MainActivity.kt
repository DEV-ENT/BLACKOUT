package it.blackout.mesh

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/** What the screens show; [tick] changes whenever the mesh has news, so the screens read it again. */
class AppState(a: ComponentActivity) {
    private val prefs = a.getSharedPreferences("mesh", 0)
    var tick by mutableIntStateOf(0)
    var group by mutableStateOf(Groups.current(a))
    var name by mutableStateOf(prefs.getString("name", "") ?: "")
    var invite by mutableStateOf<SavedGroup?>(null)          // an invite link that was opened
    var shareLocation by mutableStateOf(prefs.getBoolean("shareLocation", false))
    var permissionsMissing by mutableStateOf(false) // Bluetooth: without it phones can't connect
    var locationMissing by mutableStateOf(false)    // precise location: Android needs it to find phones before Android 13
    var tab by mutableIntStateOf(0)
    var moderated by mutableIntStateOf(0) // changes when someone is blocked or a message reported
    fun setShareLocation(c: ComponentActivity, on: Boolean) { shareLocation = on; c.getSharedPreferences("mesh", 0).edit().putBoolean("shareLocation", on).apply() }
}

class MainActivity : ComponentActivity() {
    lateinit var state: AppState
    private val refresh: () -> Unit = { state.tick++ }

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        enableEdgeToEdge(SystemBarStyle.dark(Color.TRANSPARENT), SystemBarStyle.dark(Color.TRANSPARENT))
        DebugTools.debugIntent(this, intent) // debug builds only; does nothing in release
        state = AppState(this)
        Notifier.setUp(this)
        OfflineMap.setUp(this)
        LocalAi.setUp(this)
        link(intent)
        MeshEngine.listener = refresh
        if (state.group != null) { startStore(); permissions() }
        setContent { DarkProofApp(state, this) }
    }

    override fun onNewIntent(i: Intent) {
        super.onNewIntent(i)
        DebugTools.debugIntent(this, i)
        link(i)
    }

    /** darkproof://join?name=…&code=… opened from a QR code or a shared link. */
    private fun link(i: Intent?) {
        val g = i?.data?.toString()?.let(Invite::parse) ?: return
        if (g.second != state.group?.code) state.invite = SavedGroup(g.first, g.second)
    }

    override fun onResume() {
        super.onResume(); Notifier.onScreen = true
        if (state.group != null && (state.permissionsMissing || state.locationMissing)) check() // back from Settings
    }

    /** Opens the message store and the group's keys at once, so messages written before the mesh is up are kept. */
    private fun startStore() {
        val g = state.group ?: return; val name = state.name
        Thread { MeshEngine.start(applicationContext, name, g.code) }.start()
    }
    override fun onPause() { Notifier.onScreen = false; super.onPause() }

    /** After the first setup: saves the group and starts the mesh. */
    fun started(name: String, g: SavedGroup) {
        Groups.setUp(this, name, g)
        state.name = name; state.group = g
        startStore(); permissions()
    }

    fun switchTo(g: SavedGroup) { Groups.switchTo(this, g); state.group = g; state.tick++ }

    private fun granted(p: String) = checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    /** Without these the Bluetooth code would crash, so the mesh starts only with them (Android 12+). */
    private val bluetooth = if (Build.VERSION.SDK_INT >= 31)
        listOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN) else emptyList()

    /** Asked for once; location is asked for (fine and coarse together, as Android 12+ requires) but never blocks the app. */
    private fun permissions() {
        val wanted = bluetooth + (if (Build.VERSION.SDK_INT >= 33) listOf(Manifest.permission.NEARBY_WIFI_DEVICES, Manifest.permission.POST_NOTIFICATIONS) else emptyList()) +
            listOf(Manifest.permission.ACCESS_COARSE_LOCATION, Manifest.permission.ACCESS_FINE_LOCATION)
        val need = wanted.filterNot(::granted)
        if (need.isEmpty()) check() else requestPermissions(need.toTypedArray(), 1)
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(r: Int, p: Array<String>, g: IntArray) {
        super.onRequestPermissionsResult(r, p, g)
        if (r == 1) check() // reads the real state: a cancelled request returns empty arrays
    }

    /** Starts the mesh when Bluetooth is allowed; without precise location it still runs, with fewer ways to find phones. */
    private fun check() {
        state.permissionsMissing = !bluetooth.all(::granted)
        state.locationMissing = !granted(Manifest.permission.ACCESS_FINE_LOCATION)
        if (!state.permissionsMissing) launch()
    }

    fun askNotifications() { if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2) }

    private fun launch() {
        val g = state.group ?: return
        startForegroundService(Intent(this, MeshService::class.java).putExtra("name", state.name).putExtra("code", g.code))
        state.tick++
    }

    // A new screen can start before the old one is destroyed: only unhook our own listener.
    override fun onDestroy() { if (MeshEngine.listener === refresh) MeshEngine.listener = null; super.onDestroy() }
}
