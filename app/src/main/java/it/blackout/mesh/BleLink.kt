package it.blackout.mesh

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log

/**
 * Bluetooth LE link (spec/FORMAT.md, "Bluetooth LE"): the one radio iPhones and Android phones share.
 * Runs next to Nearby. This phone is both a peripheral (advertises, GATT server) and a central (scans, connects).
 * All state is touched only on the [h] thread; Android callbacks are moved there first.
 */
@SuppressLint("MissingPermission")
class BleLink(private val ctx: Context, code: String, private val nodeId: String) {
    companion object {
        const val PREFIX = "ble:"
        private const val TAG = "BlackoutBle"
        private const val MAX_LINKS = 6
        private const val RETRY_MS = 5_000L
        fun owns(peer: String) = peer.startsWith(PREFIX)
    }

    private class Link(val id: String, val central: Boolean, val address: String) {
        var gatt: BluetoothGatt? = null               // central role
        var device: BluetoothDevice? = null           // peripheral role
        var rx: BluetoothGattCharacteristic? = null   // remote RX (central role)
        var chunk = 20
        var open = false       // setup finished, can send
        var remote: String? = null
        var up = false         // known to the router
        var busy = false       // a write or notification is in flight
        val out = ArrayDeque<ByteArray>()
        val reader = BleProtocol.Reader()
    }

    private val h = Handler(HandlerThread("ble").apply { start() }.looper)
    private val manager: BluetoothManager? = ctx.getSystemService(BluetoothManager::class.java)
    private val service = BleProtocol.serviceUuid(code)
    private val links = HashMap<String, Link>()     // link id -> link
    private val retryAt = HashMap<String, Long>()   // address -> earliest time to dial it again
    private val nodeOf = HashMap<String, String>()  // address we dialed -> node id it reported
    private val mtus = HashMap<String, Int>()       // peripheral role: address -> ATT MTU
    private var server: BluetoothGattServer? = null
    private var tx: BluetoothGattCharacteristic? = null
    private var running = false
    private var nextId = 0
    @Volatile private var upCount = 0
    @Volatile private var note = ""

    fun linkCount() = upCount
    fun statusLine() = "Bluetooth LE: $upCount link(s)" + if (note.isNotEmpty()) " · $note" else ""

    fun start() {
        h.post {
            ctx.registerReceiver(btState, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED), null, h,
                if (Build.VERSION.SDK_INT >= 33) Context.RECEIVER_NOT_EXPORTED else 0)
            up()
        }
    }

    /** Called by the router, possibly while it holds its lock, so only queue the work. */
    fun send(peer: String, p: Packet) {
        val f = BleProtocol.frame(BleProtocol.PACKET, p.encode())
        h.post { links[peer]?.let { enqueue(it, f) } }
    }

    // ---- start / stop -------------------------------------------------------------------------

    private fun up() {
        val m = manager; val a = m?.adapter
        if (m == null || a == null || !a.isEnabled) { set("Bluetooth is off"); return }
        if (running) return
        val s = m.openGattServer(ctx, serverCb) ?: run { set("GATT server unavailable"); return }
        running = true; server = s; set("")
        val svc = BluetoothGattService(service, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        svc.addCharacteristic(BluetoothGattCharacteristic(BleProtocol.RX,
            BluetoothGattCharacteristic.PROPERTY_WRITE, BluetoothGattCharacteristic.PERMISSION_WRITE))
        tx = BluetoothGattCharacteristic(BleProtocol.TX, BluetoothGattCharacteristic.PROPERTY_NOTIFY, 0).apply {
            addDescriptor(BluetoothGattDescriptor(BleProtocol.CCCD,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE))
        }
        svc.addCharacteristic(tx)
        s.addService(svc) // advertising starts once the service is added
        try { // throws if Bluetooth turns off in the meantime
            a.bluetoothLeScanner?.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(service)).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_BALANCED).build(), scanCb)
        } catch (e: RuntimeException) { set("scan failed: ${e.message}") }
    }

    private fun down() {
        if (!running) return
        running = false
        val a = manager?.adapter
        try { a?.bluetoothLeScanner?.stopScan(scanCb) } catch (_: Exception) { }
        try { a?.bluetoothLeAdvertiser?.stopAdvertising(advCb) } catch (_: Exception) { }
        links.values.toList().forEach { drop(it) }
        server?.close(); server = null; tx = null
    }

    private fun advertise() {
        if (!running) return
        val adv = manager?.adapter?.bluetoothLeAdvertiser ?: run { set("advertising not supported"); return }
        try { // throws if Bluetooth turns off in the meantime
            adv.startAdvertising(
                AdvertiseSettings.Builder().setConnectable(true).setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_BALANCED)
                    .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH).build(),
                AdvertiseData.Builder().setIncludeDeviceName(false).addServiceUuid(ParcelUuid(service)).build(), advCb)
        } catch (e: RuntimeException) { set("advertising failed: ${e.message}") }
    }

    private val advCb = object : AdvertiseCallback() {
        override fun onStartSuccess(s: AdvertiseSettings) { h.post { if (note.startsWith("advertising")) set("") } }
        override fun onStartFailure(code: Int) {
            h.post {
                set("advertising failed ($code)")
                if (code != ADVERTISE_FAILED_ALREADY_STARTED && code != ADVERTISE_FAILED_FEATURE_UNSUPPORTED) h.postDelayed(::advertise, 10_000)
            }
        }
    }

    private val btState = object : BroadcastReceiver() {
        override fun onReceive(c: Context, i: Intent) { // runs on h
            when (i.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)) {
                BluetoothAdapter.STATE_ON -> up()
                BluetoothAdapter.STATE_TURNING_OFF, BluetoothAdapter.STATE_OFF -> { down(); set("Bluetooth is off") }
            }
        }
    }

    // ---- central role: scan and connect -------------------------------------------------------

    private val scanCb = object : ScanCallback() {
        override fun onScanResult(type: Int, r: ScanResult) { val d = r.device; h.post { dial(d) } }
        override fun onScanFailed(code: Int) { h.post { set("scan failed ($code)") } }
    }

    private fun dial(d: BluetoothDevice) {
        val addr = d.address
        if (!running || links.size >= MAX_LINKS || links.values.any { it.central && it.address == addr }) return
        if (SystemClock.elapsedRealtime() < (retryAt[addr] ?: 0L)) return
        nodeOf[addr]?.let { n -> if (links.values.any { it.up && it.remote == n }) return } // already linked the other way
        val l = Link(PREFIX + (++nextId), central = true, address = addr)
        links[l.id] = l
        Log.d(TAG, "dial $addr as ${l.id}")
        l.gatt = d.connectGatt(ctx, false, gattCb, BluetoothDevice.TRANSPORT_LE, BluetoothDevice.PHY_LE_1M_MASK, h)
        if (l.gatt == null) drop(l)
    }

    private fun linkOf(g: BluetoothGatt) = links.values.firstOrNull { it.gatt === g }

    private val gattCb = object : BluetoothGattCallback() { // delivered on h (see connectGatt)
        override fun onConnectionStateChange(g: BluetoothGatt, st: Int, ns: Int) {
            val l = linkOf(g) ?: run { g.close(); return }
            if (st == BluetoothGatt.GATT_SUCCESS && ns == BluetoothProfile.STATE_CONNECTED) { if (!g.requestMtu(517)) g.discoverServices() }
            else drop(l)
        }
        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, st: Int) {
            val l = linkOf(g) ?: return
            if (st == BluetoothGatt.GATT_SUCCESS) l.chunk = BleProtocol.chunkSize(mtu)
            if (l.rx == null) g.discoverServices()
        }
        override fun onServicesDiscovered(g: BluetoothGatt, st: Int) {
            val l = linkOf(g) ?: return
            val s = g.getService(service)
            val rx = s?.getCharacteristic(BleProtocol.RX); val txc = s?.getCharacteristic(BleProtocol.TX)
            val cccd = txc?.getDescriptor(BleProtocol.CCCD)
            if (st != BluetoothGatt.GATT_SUCCESS || rx == null || txc == null || cccd == null) { drop(l); return }
            l.rx = rx
            g.setCharacteristicNotification(txc, true)
            if (!writeDescriptor(g, cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) drop(l)
        }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, st: Int) {
            val l = linkOf(g) ?: return
            if (st != BluetoothGatt.GATT_SUCCESS) { drop(l); return }
            l.open = true; enqueue(l, BleProtocol.hello(nodeId))
        }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) {
            val l = linkOf(g) ?: return
            if (st != BluetoothGatt.GATT_SUCCESS) { drop(l); return }
            l.busy = false; pump(l)
        }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, v: ByteArray) {
            linkOf(g)?.let { onChunk(it, v) }
        }
        @Deprecated("API < 33") @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            val v = c.value ?: return
            linkOf(g)?.let { onChunk(it, v) }
        }
    }

    // ---- peripheral role: GATT server ---------------------------------------------------------

    private fun peripheralLink(d: BluetoothDevice) = links.values.firstOrNull { !it.central && it.address == d.address }

    private val serverCb = object : BluetoothGattServerCallback() { // binder threads: move to h
        override fun onServiceAdded(st: Int, s: BluetoothGattService) {
            h.post { if (st == BluetoothGatt.GATT_SUCCESS) advertise() else set("GATT service failed ($st)") }
        }
        override fun onConnectionStateChange(d: BluetoothDevice, st: Int, ns: Int) {
            if (ns == BluetoothProfile.STATE_DISCONNECTED) h.post { mtus.remove(d.address); peripheralLink(d)?.let { drop(it) } }
        }
        override fun onMtuChanged(d: BluetoothDevice, mtu: Int) {
            h.post { mtus[d.address] = mtu; peripheralLink(d)?.chunk = BleProtocol.chunkSize(mtu) }
        }
        override fun onDescriptorWriteRequest(d: BluetoothDevice, req: Int, desc: BluetoothGattDescriptor, prepared: Boolean,
                                              needsResponse: Boolean, offset: Int, value: ByteArray?) {
            h.post {
                if (needsResponse) server?.sendResponse(d, req, BluetoothGatt.GATT_SUCCESS, 0, null)
                if (desc.uuid != BleProtocol.CCCD) return@post
                val existing = peripheralLink(d)
                if (value != null && value.isNotEmpty() && (value[0].toInt() and 1) != 0) { // notifications enabled
                    if (existing != null || links.size >= MAX_LINKS) return@post
                    val l = Link(PREFIX + (++nextId), central = false, address = d.address)
                    l.device = d; l.chunk = BleProtocol.chunkSize(mtus[d.address] ?: 23); l.open = true
                    links[l.id] = l
                    Log.d(TAG, "${d.address} subscribed as ${l.id}")
                    enqueue(l, BleProtocol.hello(nodeId))
                } else existing?.let { drop(it) }
            }
        }
        override fun onDescriptorReadRequest(d: BluetoothDevice, req: Int, offset: Int, desc: BluetoothGattDescriptor) {
            h.post {
                val v = if (peripheralLink(d) != null) BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE else BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE
                server?.sendResponse(d, req, BluetoothGatt.GATT_SUCCESS, 0, v)
            }
        }
        override fun onCharacteristicWriteRequest(d: BluetoothDevice, req: Int, c: BluetoothGattCharacteristic, prepared: Boolean,
                                                  needsResponse: Boolean, offset: Int, value: ByteArray?) {
            h.post {
                val l = peripheralLink(d)
                val ok = l != null && value != null && c.uuid == BleProtocol.RX && !prepared && offset == 0
                if (needsResponse) server?.sendResponse(d, req, if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, 0, null)
                if (ok) onChunk(l!!, value!!)
            }
        }
        override fun onCharacteristicReadRequest(d: BluetoothDevice, req: Int, offset: Int, c: BluetoothGattCharacteristic) {
            h.post { server?.sendResponse(d, req, BluetoothGatt.GATT_READ_NOT_PERMITTED, 0, null) }
        }
        override fun onNotificationSent(d: BluetoothDevice, st: Int) {
            h.post {
                val l = peripheralLink(d) ?: return@post
                if (st != BluetoothGatt.GATT_SUCCESS) drop(l, hard = true) else { l.busy = false; pump(l) }
            }
        }
    }

    // ---- both roles ---------------------------------------------------------------------------

    private fun enqueue(l: Link, frame: ByteArray) { l.out.addAll(BleProtocol.chunks(frame, l.chunk)); pump(l) }

    /** Sends the next chunk once the previous write or notification has completed. */
    private fun pump(l: Link) {
        if (l.busy || !l.open || links[l.id] !== l) return
        val c = l.out.firstOrNull() ?: return
        val ok = try {
            if (l.central) { val g = l.gatt; val rx = l.rx; g != null && rx != null && writeChar(g, rx, c) }
            else { val s = server; val d = l.device; val t = tx; s != null && d != null && t != null && notify(s, d, t, c) }
        } catch (e: RuntimeException) { // the Bluetooth stack throws on some bad states: lose the link, not the app
            Log.w(TAG, "${l.id}: send failed: $e"); drop(l, hard = true); return
        }
        if (ok) { l.out.removeFirst(); l.busy = true } else h.postDelayed({ pump(l) }, 100) // stack busy: try again
    }

    private fun onChunk(l: Link, chunk: ByteArray) {
        val frames = try { l.reader.feed(chunk) } catch (e: IllegalArgumentException) {
            Log.w(TAG, "${l.id}: bad stream: ${e.message}"); drop(l, hard = true); return
        }
        for ((type, payload) in frames) {
            if (links[l.id] !== l) return
            when (type) {
                BleProtocol.HELLO -> if (l.remote == null) {
                    val remote = BleProtocol.parseHello(payload)
                    if (remote == null || remote == nodeId) { drop(l, hard = true); return }
                    hello(l, remote)
                }
                BleProtocol.PACKET -> if (l.up) Packet.decode(payload)?.let {
                    Log.d(TAG, "rx packet ${it.id} via ${l.id} from ${l.remote}")
                    MeshEngine.router?.receive(l.id, it)
                }
            }
        }
    }

    private fun hello(l: Link, remote: String) {
        l.remote = remote
        if (l.central) nodeOf[l.address] = remote
        val other = links.values.firstOrNull { it !== l && it.remote == remote }
        if (other != null) { // two links to the same phone: keep one (spec: "Duplicate links")
            val keepCentral = BleProtocol.keepMyCentralLink(nodeId, remote)
            val loser = if (other.central == l.central) other else if (l.central == keepCentral) other else l
            Log.d(TAG, "duplicate link to $remote: closing ${loser.id}")
            drop(loser)
            if (loser === l) return
        }
        Log.d(TAG, "${l.id} up: ${if (l.central) "central" else "peripheral"}, remote $remote")
        l.up = true
        MeshEngine.router?.peerUp(l.id)
        recount()
    }

    /**
     * Forgets a link. [hard] also disconnects a peripheral-role link; by default the remote central closes it,
     * because two phones may share one radio connection for both directions.
     */
    private fun drop(l: Link, hard: Boolean = false) {
        if (links.remove(l.id) == null) return
        Log.d(TAG, "drop ${l.id}")
        l.open = false; l.out.clear()
        if (l.central) {
            retryAt[l.address] = SystemClock.elapsedRealtime() + RETRY_MS
            l.gatt?.let { it.disconnect(); it.close() }
        } else if (hard) l.device?.let { server?.cancelConnection(it) }
        if (l.up) { l.up = false; MeshEngine.router?.peerDown(l.id) }
        recount()
    }

    private fun recount() { upCount = links.values.count { it.up }; MeshEngine.notifyUi() }
    private fun set(n: String) { note = n; MeshEngine.notifyUi() }

    @Suppress("DEPRECATION")
    private fun writeChar(g: BluetoothGatt, c: BluetoothGattCharacteristic, v: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= 33) g.writeCharacteristic(c, v, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
        else { c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; c.value = v; g.writeCharacteristic(c) }

    @Suppress("DEPRECATION")
    private fun writeDescriptor(g: BluetoothGatt, d: BluetoothGattDescriptor, v: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= 33) g.writeDescriptor(d, v) == BluetoothStatusCodes.SUCCESS
        else { d.value = v; g.writeDescriptor(d) }

    @Suppress("DEPRECATION")
    private fun notify(s: BluetoothGattServer, d: BluetoothDevice, c: BluetoothGattCharacteristic, v: ByteArray): Boolean =
        if (Build.VERSION.SDK_INT >= 33) s.notifyCharacteristicChanged(d, c, false, v) == BluetoothStatusCodes.SUCCESS
        else { c.value = v; s.notifyCharacteristicChanged(d, c, false) }
}
