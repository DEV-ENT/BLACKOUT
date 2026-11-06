package it.blackout.mesh

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.*
import java.util.UUID

/**
 * The MeshCore companion-radio protocol, as far as DarkProof uses it (spec/FORMAT.md, "LoRa via MeshCore"). Pure
 * functions, so unit tests run; [MeshCoreLink] does the Bluetooth part.
 */
object MeshCore {
    const val PAYLOAD_MAX = 163           // channel data that every firmware from 1.15 delivers
    const val MIN_FIRMWARE = 11            // FIRMWARE_VER_CODE of 1.15, the first with channel data
    const val DATA_TYPE = 0xFF44           // development range FF00-FFFF
    const val CHANNEL_NAME = "#darkproof"
    /** First 16 bytes of SHA-256("#darkproof"), as MeshCore derives hashtag channel keys. */
    val CHANNEL_KEY: ByteArray = java.security.MessageDigest.getInstance("SHA-256").digest(CHANNEL_NAME.toByteArray()).copyOf(16)

    const val OK = 0x00; const val ERR = 0x01; const val SELF_INFO = 0x05; const val NO_MORE = 0x0A
    const val DEVICE_INFO = 0x0D; const val CHANNEL_INFO = 0x12; const val CHANNEL_DATA = 0x1B; const val MSG_WAITING = 0x83

    fun fits(p: Packet) = p.encode().size <= PAYLOAD_MAX

    fun deviceQuery() = byteArrayOf(0x16, 0x03)
    fun appStart() = byteArrayOf(0x01) + ByteArray(7) + "DarkProof".toByteArray()
    fun getChannel(idx: Int) = byteArrayOf(0x1F, idx.toByte())
    fun setChannel(idx: Int) = byteArrayOf(0x20, idx.toByte()) + CHANNEL_NAME.toByteArray().copyOf(32) + CHANNEL_KEY
    fun syncNext() = byteArrayOf(0x0A)
    fun sendData(idx: Int, packet: ByteArray): ByteArray {
        require(packet.size <= PAYLOAD_MAX)
        return byteArrayOf(0x3E, idx.toByte(), 0xFF.toByte(), (DATA_TYPE and 0xFF).toByte(), (DATA_TYPE shr 8).toByte()) + packet
    }

    /** Replies have codes below 0x80; pushes (sent by the radio on its own) at 0x80 and above. */
    fun isPush(f: ByteArray) = f.isNotEmpty() && (f[0].toInt() and 0xFF) >= 0x80

    class DeviceInfo(val firmware: Int, val channels: Int)
    fun deviceInfo(f: ByteArray): DeviceInfo? =
        if (f.size >= 4 && f[0].toInt() == DEVICE_INFO) DeviceInfo(f[1].toInt() and 0xFF, f[3].toInt() and 0xFF) else null

    /** A channel slot: null if the frame isn't one. [isOurs] when it holds the DarkProof key; [isEmpty] when unused. */
    class Slot(val idx: Int, val name: String, val key: ByteArray) {
        val isOurs get() = key.contentEquals(CHANNEL_KEY)
        val isEmpty get() = name.isEmpty() && key.all { it.toInt() == 0 }
    }
    fun slot(f: ByteArray): Slot? {
        if (f.size < 2 + 32 + 16 || f[0].toInt() != CHANNEL_INFO) return null
        val nameBytes = f.copyOfRange(2, 34).takeWhile { it.toInt() != 0 }.toByteArray()
        return Slot(f[1].toInt() and 0xFF, String(nameBytes, Charsets.UTF_8), f.copyOfRange(34, 50))
    }

    /** The DarkProof packet in a channel-data frame on [ourSlot], or null for anything else. */
    fun packet(f: ByteArray, ourSlot: Int): ByteArray? {
        if (f.size < 9 || f[0].toInt() != CHANNEL_DATA || (f[4].toInt() and 0xFF) != ourSlot) return null
        val type = (f[6].toInt() and 0xFF) or ((f[7].toInt() and 0xFF) shl 8)
        val len = f[8].toInt() and 0xFF
        if (type != DATA_TYPE || f.size < 9 + len) return null
        return f.copyOfRange(9, 9 + len)
    }
}

/**
 * Bluetooth LE client for a MeshCore radio. Commands go one at a time, each waiting for its reply, as the firmware
 * expects. Setup: device query (firmware check), app start, then find or add the #darkproof channel.
 */
@SuppressLint("MissingPermission")
class MeshCoreLink(private val ctx: Context) {
    companion object {
        const val PEER = "meshcore"
        private val SERVICE = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        private val RX = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e") // the phone writes here
        private val TX = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e") // the radio notifies here
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
    private val h = Handler(Looper.getMainLooper())
    private val prefs = ctx.getSharedPreferences("mesh", 0)
    private val adapter get() = ctx.getSystemService(BluetoothManager::class.java).adapter
    private val queue = LoraQueue(maxBytes = MeshCore.PAYLOAD_MAX)
    private var gatt: BluetoothGatt? = null
    private var rx: BluetoothGattCharacteristic? = null
    private val commands = ArrayDeque<Pair<ByteArray, (ByteArray?) -> Unit>>() // waiting to be sent, with what to do with the reply
    private var waiting: ((ByteArray?) -> Unit)? = null
    private var timeout: Runnable? = null
    private var slot = -1
    private var syncing = false
    @Volatile var connected = false; private set
    @Volatile var status = "MeshCore: no radio"; private set

    private fun set(s: String) { status = "MeshCore: $s"; MeshEngine.notifyUi() }
    fun offer(p: Packet) = queue.offer(p)
    fun start() { if (prefs.getString("meshcore", null) != null) connect(); pump() }
    fun select(addr: String) { prefs.edit().putString("meshcore", addr).apply(); close(); connect() }

    fun scan(found: (addr: String, name: String) -> Unit) {
        val s = adapter?.bluetoothLeScanner ?: run { set("Bluetooth is off"); return }
        val cb = object : ScanCallback() {
            override fun onScanResult(t: Int, r: ScanResult) { h.post { found(r.device.address, r.device.name ?: r.device.address) } }
        }
        s.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()), ScanSettings.Builder().build(), cb)
        h.postDelayed({ s.stopScan(cb) }, 15_000)
    }

    private fun connect() {
        val addr = prefs.getString("meshcore", null) ?: return
        val a = adapter ?: return
        set("connecting…")
        gatt = a.getRemoteDevice(addr).connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
    }

    private fun close() {
        if (connected) MeshEngine.router?.peerDown(PEER)
        connected = false; slot = -1; syncing = false
        commands.clear(); waiting = null; timeout?.let(h::removeCallbacks)
        gatt?.close(); gatt = null; rx = null
    }

    private fun retry(why: String) { close(); set("$why, retrying"); h.postDelayed({ if (gatt == null) connect() }, 10_000) }

    /** Queues a command; [reply] gets its reply frame, or null if none came within 5 s. */
    private fun command(frame: ByteArray, reply: (ByteArray?) -> Unit = {}) { commands.addLast(frame to reply); next() }

    private fun next() {
        if (waiting != null) return
        val (frame, reply) = commands.removeFirstOrNull() ?: return
        val c = rx; val g = gatt
        if (c == null || g == null) return
        waiting = reply
        c.value = frame; c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        if (!g.writeCharacteristic(c)) { finish(null); return }
        timeout = Runnable { finish(null) }.also { h.postDelayed(it, 5_000) }
    }

    private fun finish(f: ByteArray?) {
        val r = waiting ?: return
        waiting = null; timeout?.let(h::removeCallbacks)
        r(f); next()
    }

    private fun frame(f: ByteArray) {
        if (f.isEmpty()) return
        if (MeshCore.isPush(f)) { if ((f[0].toInt() and 0xFF) == MeshCore.MSG_WAITING) sync(); return }
        finish(f)
    }

    /** Connected and subscribed: check the firmware, start, find or add the DarkProof channel. */
    private fun setUp() {
        command(MeshCore.deviceQuery()) { f ->
            val info = f?.let(MeshCore::deviceInfo) ?: return@command retry("not a MeshCore radio")
            if (info.firmware < MeshCore.MIN_FIRMWARE) { close(); set("firmware too old: update the radio to MeshCore 1.15 or newer"); return@command }
            command(MeshCore.appStart()) { s -> if (s == null || s[0].toInt() != MeshCore.SELF_INFO) retry("no answer from the radio") else findSlot(0, info.channels, -1) }
        }
    }

    private fun findSlot(i: Int, count: Int, firstEmpty: Int) {
        if (i >= count) {
            if (firstEmpty < 0) { close(); set("no free channel on the radio: remove one in the MeshCore app"); return }
            command(MeshCore.setChannel(firstEmpty)) { f -> if (f?.firstOrNull()?.toInt() == MeshCore.OK) ready(firstEmpty) else retry("couldn't add the #darkproof channel") }
            return
        }
        command(MeshCore.getChannel(i)) { f ->
            val s = f?.let(MeshCore::slot)
            when {
                s?.isOurs == true -> ready(s.idx)
                else -> findSlot(i + 1, count, if (firstEmpty < 0 && (s == null || s.isEmpty)) i else firstEmpty)
            }
        }
    }

    private fun ready(idx: Int) {
        slot = idx; connected = true; set("radio connected")
        Thread { MeshEngine.router?.peerUp(PEER); MeshEngine.notifyUi() }.start()
        sync()
    }

    /** Fetches queued frames until the radio says there are no more. */
    private fun sync() {
        if (syncing || slot < 0) return
        syncing = true
        command(MeshCore.syncNext()) { f ->
            syncing = false
            if (f == null || f[0].toInt() == MeshCore.NO_MORE) return@command
            MeshCore.packet(f, slot)?.let { raw -> Packet.decode(raw)?.let { p -> Thread { MeshEngine.router?.receive(PEER, p) }.start() } }
            sync()
        }
    }

    private fun pump() {
        if (connected && waiting == null && commands.isEmpty()) queue.next()?.let { p -> command(MeshCore.sendData(slot, p.encode())) }
        h.postDelayed(::pump, 1_000)
    }

    private val cb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, st: Int, ns: Int) = post {
            if (g !== gatt) return@post
            if (ns == BluetoothProfile.STATE_CONNECTED) { if (!g.requestMtu(185)) g.discoverServices() } // frames up to 176 bytes
            else retry("radio unreachable")
        }
        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, st: Int) = post { if (g === gatt) g.discoverServices() }
        override fun onServicesDiscovered(g: BluetoothGatt, st: Int) = post {
            if (g !== gatt) return@post
            val s = g.getService(SERVICE)
            val tx = s?.getCharacteristic(TX); rx = s?.getCharacteristic(RX)
            val d = tx?.getDescriptor(CCCD)
            if (st != BluetoothGatt.GATT_SUCCESS || tx == null || d == null || rx == null) { retry("not a MeshCore radio"); return@post }
            g.setCharacteristicNotification(tx, true)
            d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            if (!g.writeDescriptor(d)) retry("couldn't subscribe")
        }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, st: Int) = post {
            if (g !== gatt) return@post
            if (st != BluetoothGatt.GATT_SUCCESS) retry("pairing or PIN failed") else setUp()
        }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) = post {
            if (st != BluetoothGatt.GATT_SUCCESS) finish(null)
        }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, v: ByteArray) = post { if (g === gatt) frame(v) }
        @Deprecated("API < 33")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) { val v = c.value; post { if (g === gatt) frame(v) } }
    }
    private fun post(f: () -> Unit) { h.post(f) }
}
