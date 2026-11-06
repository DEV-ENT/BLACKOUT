package it.blackout.mesh

import android.Manifest
import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.*
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Transport: direct Bluetooth and Wi-Fi between phones, with no router or internet. */
class MeshService : Service() {
    companion object {
        const val ACTION_STOP = "it.darkproof.mesh.action.STOP"
        /** Set by the screen: closes it before "Stop DarkProof" ends the app. */
        var onStop: (() -> Unit)? = null

        /** The Bluetooth permissions the mesh can't run without (Android 12+). */
        fun permitted(c: Context) = Build.VERSION.SDK_INT < 31 || listOf(Manifest.permission.BLUETOOTH_ADVERTISE,
            Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_SCAN).all { c.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }

        /** Starts the mesh in the background if the phone allows it; false if it couldn't. */
        fun start(c: Context): Boolean {
            if (!permitted(c)) return false
            return try { c.startForegroundService(Intent(c, MeshService::class.java)); true }
            catch (e: Exception) { DebugTools.log("mesh service not started: $e"); false } // e.g. not allowed from the background
        }
    }

    private val io = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var client: ConnectionsClient
    private lateinit var svc: String
    private val found = ConcurrentHashMap<String, String>()   // endpoint -> deviceId (discovered)
    private val names = ConcurrentHashMap<String, String>()   // endpoint -> deviceId (any connection, either direction)
    private val connected = ConcurrentHashMap.newKeySet<String>()
    private val pending = ConcurrentHashMap.newKeySet<String>()
    private var started = false
    private var discovering = false

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int {
        if (i?.action == ACTION_STOP) { stopAll(); return START_NOT_STICKY }
        // Without Bluetooth permission the links would crash: don't start, and don't come back by itself.
        if (!permitted(this)) { stopSelf(); return START_NOT_STICKY }
        Notifier.setUp(this) // message alerts also when no screen is open
        val ch = "mesh"
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(ch, "Network", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, MeshService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, ch).setContentTitle("DarkProof is on")
            .setContentText("Passing messages between phones nearby, also when the app is closed")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Stop DarkProof", stop).build()).build()
        try {
            if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) else startForeground(1, n)
        } catch (e: Exception) { // ForegroundServiceStartNotAllowedException, or SecurityException without the permissions
            DebugTools.log("foreground start refused: $e"); stopSelf(); return START_NOT_STICKY
        }
        // The saved group wins over the intent: Android may redeliver an old intent after the user switched groups.
        val prefs = getSharedPreferences("mesh", 0)
        val name = prefs.getString("name", null) ?: i?.getStringExtra("name"); val code = prefs.getString("code", null) ?: i?.getStringExtra("code")
        if (!started && name != null && code != null) {
            started = true
            io.execute {
                MeshEngine.start(this, name, code)
                ui.post { runCatching { begin() }.onFailure { status("Not available right now"); DebugTools.log("mesh start failed: $it") } }
            }
        }
        return START_STICKY // name and group come from the saved settings
    }

    /** "Stop DarkProof": every link stops and the app ends, until it is opened again. */
    private fun stopAll() {
        getSharedPreferences("mesh", 0).edit().putBoolean("stopped", true).commit()
        if (::client.isInitialized) runCatching { client.stopAdvertising(); client.stopDiscovery(); client.stopAllEndpoints() }
        runCatching { MeshEngine.shutdown() }
        onStop?.invoke()
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        ui.postDelayed({ Process.killProcess(Process.myPid()) }, 800) // Bluetooth, radios and Wi-Fi threads all end with it
    }

    private fun status(s: String) { MeshEngine.transportStatus = s; MeshEngine.notifyUi() }

    /** Nearby's error codes, in words: 8030-8040 are missing permissions. */
    private fun problem(e: Exception): String {
        val code = (e as? com.google.android.gms.common.api.ApiException)?.statusCode ?: Regex("\\d{4}").find(e.message ?: "")?.value?.toIntOrNull()
        return if (code != null && code in 8030..8040) "needs the Nearby devices and Location permissions" else "not available right now"
    }

    private fun begin() {
        svc = "it.blackout.mesh.v1" // the same for every DarkProof phone: all relay for each other (spec/FORMAT.md)
        client = Nearby.getConnectionsClient(this)
        val lora = LoraLink(this); MeshEngine.lora = lora; lora.start()
        val meshcore = MeshCoreLink(this); MeshEngine.meshcore = meshcore; meshcore.start()
        val ble = BleLink(this, MeshEngine.deviceId); MeshEngine.ble = ble
        MeshEngine.nearbyNodes = { connected.mapNotNull { names[it] }.toSet() }
        MeshEngine.sender = { peer, p ->
            when {
                peer == LoraLink.PEER -> lora.offer(p)
                peer == MeshCoreLink.PEER -> meshcore.offer(p)
                BleLink.owns(peer) -> ble.send(peer, p)
                else -> client.sendPayload(peer, Payload.fromBytes(p.encode()))
            }
        }
        ble.start()
        advertise(); discover(); status("searching")
        ui.postDelayed(::cycle, 30_000)
    }

    /** Battery saver: Nearby searches 30 s out of every 2 minutes (linked phones stay linked); otherwise all the time. */
    private fun cycle() {
        val saver = MeshEngine.batterySaver(this)
        if (saver && discovering) { client.stopDiscovery(); discovering = false; ui.postDelayed(::cycle, 90_000); return }
        if (!discovering) discover()
        ui.postDelayed(::cycle, 30_000)
    }

    private fun advertise() {
        client.startAdvertising(MeshEngine.deviceId, svc, lifecycle,
            AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build())
            .addOnFailureListener { if (it.message?.contains("8001") != true) { status(problem(it)); ui.postDelayed(::advertise, 10_000) } }
    }
    private fun discover() {
        discovering = true
        client.startDiscovery(svc, discovery, DiscoveryOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build())
            .addOnFailureListener { if (it.message?.contains("8002") != true) { discovering = false; status(problem(it)) } }
            .addOnSuccessListener { if (MeshEngine.transportStatus != "searching") status("searching") }
    }
    /** Only the phone with the lower ID initiates, so two phones never call each other at the same time. */
    private fun dial(ep: String) {
        val other = found[ep] ?: return
        if (MeshEngine.deviceId >= other || ep in connected || !pending.add(ep)) return
        client.requestConnection(MeshEngine.deviceId, ep, lifecycle).addOnFailureListener {
            pending -= ep; ui.postDelayed({ dial(ep) }, 5_000)
        }
    }
    private val discovery = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(ep: String, info: DiscoveredEndpointInfo) { found[ep] = info.endpointName; dial(ep) }
        override fun onEndpointLost(ep: String) { found -= ep }
    }
    private val payloads = object : PayloadCallback() {
        override fun onPayloadReceived(ep: String, p: Payload) {
            val raw = p.asBytes() ?: return
            io.execute { Packet.decode(raw)?.let { MeshEngine.router?.receive(ep, it) } }
        }
        override fun onPayloadTransferUpdate(ep: String, u: PayloadTransferUpdate) {}
    }
    private val lifecycle = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(ep: String, i: ConnectionInfo) {
            names[ep] = i.endpointName // the other phone's node id, also when it dialed us
            client.acceptConnection(ep, payloads)
        }
        override fun onConnectionResult(ep: String, r: ConnectionResolution) {
            pending -= ep
            if (r.status.isSuccess) {
                connected += ep
                io.execute { MeshEngine.router?.peerUp(ep); MeshEngine.notifyUi() }
            } else ui.postDelayed({ dial(ep) }, 5_000)
        }
        override fun onDisconnected(ep: String) {
            connected -= ep
            io.execute { MeshEngine.router?.peerDown(ep); MeshEngine.notifyUi() }
            ui.postDelayed({ dial(ep) }, 3_000)
        }
    }
}
