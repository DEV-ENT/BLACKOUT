package it.blackout.mesh

import android.content.Context
import android.content.Intent

/** Release build: no test hooks. The real ones live in src/debug and have the same API. */
object DebugTools {
    fun log(s: String) {}
    fun debugIntent(c: Context, i: Intent) {}
}
