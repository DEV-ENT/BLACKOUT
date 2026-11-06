package it.blackout.mesh

import android.app.*
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.*
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/** Transport: direct Bluetooth and Wi-Fi between phones, with no router or internet. */
class MeshService : Service() {
    private val io = Executors.newSingleThreadExecutor()
    private val ui = Handler(Looper.getMainLooper())
    private lateinit var client: ConnectionsClient
    private lateinit var svc: String
    private val found = ConcurrentHashMap<String, String>()   // endpoint -> deviceId
    private val connected = ConcurrentHashMap.newKeySet<String>()
    private val pending = ConcurrentHashMap.newKeySet<String>()
    private var started = false

    override fun onBind(i: Intent?): IBinder? = null

    override fun onStartCommand(i: Intent?, f: Int, id: Int): Int {
        Notifier.setUp(this) // message alerts also when no screen is open
        val ch = "mesh"
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel(ch, "Network", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, ch).setContentTitle("DarkProof active").setContentText("Relaying messages")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth).setContentIntent(open).setOngoing(true).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(1, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) else startForeground(1, n)
        // The saved group wins over the intent: Android may redeliver an old intent after the user switched groups.
        val prefs = getSharedPreferences("mesh", 0)
        val name = prefs.getString("name", null) ?: i?.getStringExtra("name"); val code = prefs.getString("code", null) ?: i?.getStringExtra("code")
        if (!started && name != null && code != null) {
            started = true
            io.execute {
                MeshEngine.start(this, name, code)
                ui.post { begin() }
            }
        }
        return START_REDELIVER_INTENT
    }

    private fun status(s: String) { MeshEngine.transportStatus = s; MeshEngine.notifyUi() }

    private fun begin() {
        svc = "it.blackout.mesh.v1" // the same for every DarkProof phone: all relay for each other (spec/FORMAT.md)
        client = Nearby.getConnectionsClient(this)
        val lora = LoraLink(this); MeshEngine.lora = lora; lora.start()
        val meshcore = MeshCoreLink(this); MeshEngine.meshcore = meshcore; meshcore.start()
        val ble = BleLink(this, MeshEngine.deviceId); MeshEngine.ble = ble
        MeshEngine.sender = { peer, p ->
            when {
                peer == LoraLink.PEER -> lora.offer(p)
                peer == MeshCoreLink.PEER -> meshcore.offer(p)
                BleLink.owns(peer) -> ble.send(peer, p)
                else -> client.sendPayload(peer, Payload.fromBytes(p.encode()))
            }
        }
        ble.start()
        advertise(); discover(); status("Looking for phones")
    }
    private fun advertise() {
        client.startAdvertising(MeshEngine.deviceId, svc, lifecycle,
            AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build())
            .addOnFailureListener { if (it.message?.contains("8001") != true) { status("Network error: ${it.message}"); ui.postDelayed(::advertise, 10_000) } }
    }
    private fun discover() {
        client.startDiscovery(svc, discovery, DiscoveryOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build())
            .addOnFailureListener { if (it.message?.contains("8002") != true) { status("Network error: ${it.message}"); ui.postDelayed(::discover, 10_000) } }
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
        override fun onConnectionInitiated(ep: String, i: ConnectionInfo) { client.acceptConnection(ep, payloads) }
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
