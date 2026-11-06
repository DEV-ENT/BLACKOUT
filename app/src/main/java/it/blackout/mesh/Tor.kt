package it.blackout.mesh

import android.content.Context

/** "Connect through Tor" (Connections screen). Filled in by the Tor step; until then there is no proxy. */
object Tor {
    fun enabled(c: Context) = c.getSharedPreferences("mesh", 0).getBoolean("tor", false)
    fun proxy(c: Context): java.net.Proxy? = null
}
