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
    var permissionsMissing by mutableStateOf(false)
    var tab by mutableIntStateOf(0)
    fun setShareLocation(c: ComponentActivity, on: Boolean) { shareLocation = on; c.getSharedPreferences("mesh", 0).edit().putBoolean("shareLocation", on).apply() }
}

class MainActivity : ComponentActivity() {
    lateinit var state: AppState

    override fun onCreate(b: Bundle?) {
        super.onCreate(b)
        enableEdgeToEdge(SystemBarStyle.dark(Color.TRANSPARENT), SystemBarStyle.dark(Color.TRANSPARENT))
        LanTest.debugIntent(this, intent) // debug builds only; does nothing in release
        state = AppState(this)
        Notifier.setUp(this)
        OfflineMap.setUp(this)
        link(intent)
        if (state.group != null) permissions()
        setContent { DarkProofApp(state, this) }
    }

    override fun onNewIntent(i: Intent) {
        super.onNewIntent(i)
        LanTest.debugIntent(this, i)
        link(i)
    }

    /** darkproof://join?name=…&code=… opened from a QR code or a shared link. */
    private fun link(i: Intent?) {
        val g = i?.data?.toString()?.let(Invite::parse) ?: return
        if (g.second != state.group?.code) state.invite = SavedGroup(g.first, g.second)
    }

    override fun onResume() { super.onResume(); Notifier.onScreen = true }
    override fun onPause() { Notifier.onScreen = false; super.onPause() }

    /** After the first setup: saves the group and starts the mesh. */
    fun started(name: String, g: SavedGroup) {
        Groups.setUp(this, name, g)
        state.name = name; state.group = g
        permissions()
    }

    fun switchTo(g: SavedGroup) { Groups.switchTo(this, g); state.group = g; state.tick++ }

    private fun permissions() {
        val need = when {
            Build.VERSION.SDK_INT >= 33 -> listOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.NEARBY_WIFI_DEVICES, Manifest.permission.POST_NOTIFICATIONS, Manifest.permission.ACCESS_FINE_LOCATION)
            Build.VERSION.SDK_INT >= 31 -> listOf(Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.ACCESS_FINE_LOCATION)
            else -> listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }.filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (need.isEmpty()) launch() else requestPermissions(need.toTypedArray(), 1)
    }

    @Deprecated("Deprecated in Java")
    override fun onRequestPermissionsResult(r: Int, p: Array<String>, g: IntArray) {
        super.onRequestPermissionsResult(r, p, g)
        if (r != 1) return
        val required = p.filter { it != Manifest.permission.POST_NOTIFICATIONS }
        state.permissionsMissing = !required.all { checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
        if (!state.permissionsMissing) launch()
    }

    fun askNotifications() { if (Build.VERSION.SDK_INT >= 33) requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2) }

    private fun launch() {
        val g = state.group ?: return
        startForegroundService(Intent(this, MeshService::class.java).putExtra("name", state.name).putExtra("code", g.code))
        MeshEngine.listener = { state.tick++ }
        state.tick++
    }

    override fun onDestroy() { MeshEngine.listener = null; super.onDestroy() }
}
