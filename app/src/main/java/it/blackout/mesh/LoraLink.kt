package it.blackout.mesh

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.*
import java.security.SecureRandom
import java.util.UUID

/** BLE client for a Meshtastic radio. GATT operations must run one at a time. */
@SuppressLint("MissingPermission")
class LoraLink(private val ctx: Context) {
    companion object {
        const val PEER = "lora"
        private val SERVICE = UUID.fromString("6ba1b218-15a8-461f-9fa8-5dcae273eafd")
        private val TO_RADIO = UUID.fromString("f75c76d2-129e-4dad-a1dd-7866124401e7")
        private val FROM_RADIO = UUID.fromString("2c55e69e-4993-11ed-b878-0242ac120002")
        private val FROM_NUM = UUID.fromString("ed9da18c-a800-4f66-a670-aa7547e34453")
        private val CCCD = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
    private val h = Handler(Looper.getMainLooper())
    private val prefs = ctx.getSharedPreferences("mesh", 0)
    private val adapter get() = ctx.getSystemService(BluetoothManager::class.java).adapter
    private val rnd = SecureRandom()
    private val queue = LoraQueue()
    private var gatt: BluetoothGatt? = null
    private var toRadio: BluetoothGattCharacteristic? = null
    private var fromRadio: BluetoothGattCharacteristic? = null
    private val ops = ArrayDeque<() -> Boolean>()
    private var busy = false
    private var draining = false
    private var nonce = 0L
    @Volatile var connected = false; private set
    @Volatile var status = "LoRa: no radio"; private set

    private fun set(s: String) { status = "LoRa: $s"; MeshEngine.notifyUi() }
    fun offer(p: Packet) = queue.offer(p)
    fun start() { if (prefs.getString("radio", null) != null) connect(); pump() }
    fun select(addr: String) { prefs.edit().putString("radio", addr).apply(); close(); connect() }

    fun scan(found: (addr: String, name: String) -> Unit) {
        val s = adapter?.bluetoothLeScanner ?: run { set("Bluetooth is off"); return }
        val cb = object : ScanCallback() {
            override fun onScanResult(t: Int, r: ScanResult) { h.post { found(r.device.address, r.device.name ?: r.device.address) } }
        }
        s.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()), ScanSettings.Builder().build(), cb)
        h.postDelayed({ s.stopScan(cb) }, 15_000)
    }
    private fun connect() {
        val addr = prefs.getString("radio", null) ?: return
        val a = adapter ?: return
        set("connecting…")
        gatt = a.getRemoteDevice(addr).connectGatt(ctx, false, cb, BluetoothDevice.TRANSPORT_LE)
    }
    private fun close() {
        if (connected) MeshEngine.router?.peerDown(PEER)
        connected = false; ops.clear(); busy = false; draining = false
        gatt?.close(); gatt = null; toRadio = null; fromRadio = null
    }
    private fun retry(why: String) { close(); set("$why, retrying"); h.postDelayed({ if (gatt == null) connect() }, 10_000) }

    private fun enqueue(op: () -> Boolean) { ops.addLast(op); runNext() }
    private fun runNext() {
        while (!busy) {
            val op = ops.removeFirstOrNull() ?: return
            busy = true
            if (!op()) busy = false
        }
    }
    private fun opDone() { busy = false; runNext() }
    private fun write(b: ByteArray) = enqueue {
        val c = toRadio; val g = gatt
        if (c == null || g == null) false else {
            c.value = b; c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT; g.writeCharacteristic(c)
        }
    }
    private fun drain() {
        if (draining) return
        draining = true
        enqueue { val c = fromRadio; val g = gatt; if (c == null || g == null) { draining = false; false } else g.readCharacteristic(c).also { if (!it) draining = false } }
    }
    private fun handle(v: ByteArray?) {
        draining = false
        if (v == null || v.isEmpty()) return
        val m = Meshtastic.parseFromRadio(v)
        if (m.configComplete == nonce && !connected) {
            connected = true; set("radio connected")
            Thread { MeshEngine.router?.peerUp(PEER); MeshEngine.notifyUi() }.start()
        }
        m.payload?.let { raw -> Packet.decode(raw)?.let { p -> Thread { MeshEngine.router?.receive(PEER, p) }.start() } }
        drain()
    }
    private fun pump() {
        if (connected) queue.next()?.let { p -> write(Meshtastic.toRadioPacket(p.encode(), rnd.nextInt().toLong() and 0xFFFFFFFFL)) }
        h.postDelayed(::pump, 1_000)
    }

    private val cb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, st: Int, ns: Int) = post {
            if (g !== gatt) return@post
            if (ns == BluetoothProfile.STATE_CONNECTED) { if (!g.requestMtu(512)) g.discoverServices() }
            else retry("radio unreachable")
        }
        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, st: Int) = post { if (g === gatt) g.discoverServices() }
        override fun onServicesDiscovered(g: BluetoothGatt, st: Int) = post {
            if (g !== gatt) return@post
            val s = g.getService(SERVICE)
            val num = s?.getCharacteristic(FROM_NUM)
            toRadio = s?.getCharacteristic(TO_RADIO); fromRadio = s?.getCharacteristic(FROM_RADIO)
            val d = num?.getDescriptor(CCCD)
            if (st != BluetoothGatt.GATT_SUCCESS || num == null || d == null || toRadio == null || fromRadio == null) { retry("not a Meshtastic device"); return@post }
            g.setCharacteristicNotification(num, true)
            enqueue { d.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE; g.writeDescriptor(d) }
            nonce = (rnd.nextInt(1_000_000_000) + 1).toLong()
            write(Meshtastic.wantConfig(nonce))
            drain()
        }
        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, st: Int) = post {
            if (st != BluetoothGatt.GATT_SUCCESS) retry("pairing or PIN failed") else opDone()
        }
        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) = post {
            opDone(); drain()
        }
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, v: ByteArray, st: Int) = post { read(v, st) }
        @Deprecated("API < 33")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, st: Int) { val v = c.value; post { read(v, st) } }
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, v: ByteArray) = post { drain() }
        @Deprecated("API < 33")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) = post { drain() }
    }
    private fun read(v: ByteArray?, st: Int) { handle(if (st == BluetoothGatt.GATT_SUCCESS) v else null); opDone() }
    private fun post(f: () -> Unit) { h.post(f) }
}
