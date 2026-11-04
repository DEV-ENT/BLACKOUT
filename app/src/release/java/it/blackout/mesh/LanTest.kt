package it.blackout.mesh

import android.content.Context
import android.view.View

/** Release build: no LAN test mode. The real one lives in src/debug and has the same API. */
object LanTest {
    fun owns(peer: String) = false
    fun send(peer: String, p: Packet) {}
    fun linkCount() = 0
    fun statusLine(): String? = null
    fun panel(c: Context): View? = null
}
