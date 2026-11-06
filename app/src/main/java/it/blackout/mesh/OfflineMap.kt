package it.blackout.mesh

import android.content.Context
import android.graphics.PointF
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import okhttp3.Dispatcher
import okhttp3.OkHttpClient
import org.json.JSONObject
import org.maplibre.android.MapLibre
import org.maplibre.android.camera.CameraPosition
import org.maplibre.android.geometry.LatLng
import org.maplibre.android.geometry.LatLngBounds
import org.maplibre.android.maps.MapLibreMap
import org.maplibre.android.maps.MapView
import org.maplibre.android.maps.Style
import org.maplibre.android.module.http.HttpRequestUtil
import org.maplibre.android.offline.OfflineManager
import org.maplibre.android.offline.OfflineRegion
import org.maplibre.android.offline.OfflineRegionError
import org.maplibre.android.offline.OfflineRegionStatus
import org.maplibre.android.offline.OfflineTilePyramidRegionDefinition
import org.maplibre.android.style.expressions.Expression
import org.maplibre.android.style.layers.CircleLayer
import org.maplibre.android.style.layers.PropertyFactory
import org.maplibre.android.style.sources.GeoJsonSource
import org.maplibre.geojson.Feature
import org.maplibre.geojson.FeatureCollection
import org.maplibre.geojson.Point
import kotlin.math.*

/**
 * Street maps from OpenFreeMap (OpenStreetMap data, dark style), saved on the phone for offline use while there is
 * internet, like the iPhone's OfflineMap.swift. OpenFreeMap's terms (openfreemap.org/tos, "Offline Downloads") allow an
 * app to download areas if each download is at most 3,000 tiles or 50 MB, uses at most 4 parallel requests, and sends a
 * User-Agent naming the app.
 */
object OfflineMap {
    const val STYLE = "https://tiles.openfreemap.org/styles/dark"
    private const val RADIUS_KM = 10.0 // the saved area is about 20 km across
    private const val MAX_ZOOM = 14.0  // OpenFreeMap's tiles stop at 14; the map zooms further by enlarging them
    private const val MAX_TILES = 3_000
    private const val MAX_BYTES = 50_000_000L

    sealed class State {
        object None : State()
        data class Downloading(val progress: Float) : State()
        data class Ready(val bytes: Long, val center: Spot, val ts: Long) : State()
        data class Failed(val why: String) : State()
    }
    var state by mutableStateOf<State>(State.None); private set
    private var region: OfflineRegion? = null
    private var ready = false

    /** Call once at launch, before any map is shown. */
    fun setUp(c: Context) {
        if (ready) return; ready = true
        MapLibre.getInstance(c.applicationContext)
        val version = runCatching { c.packageManager.getPackageInfo(c.packageName, 0).versionName }.getOrNull() ?: "0"
        val ua = "DarkProof/$version (Android; +https://github.com/DEV-ENT/DarkProof)"
        HttpRequestUtil.setOkHttpClient(OkHttpClient.Builder()
            .dispatcher(Dispatcher().apply { maxRequests = 4; maxRequestsPerHost = 4 })
            .addInterceptor { ch -> ch.proceed(ch.request().newBuilder().header("User-Agent", ua).build()) }
            .build())
        OfflineManager.getInstance(c).listOfflineRegions(object : OfflineManager.ListOfflineRegionsCallback {
            override fun onList(offlineRegions: Array<OfflineRegion>?) { offlineRegions?.firstOrNull()?.let { watch(it, resume = true) } }
            override fun onError(error: String) {}
        })
    }

    /** The saved area as a box around [c]. */
    fun bounds(c: Spot): LatLngBounds {
        val dLat = RADIUS_KM / 111.32; val dLon = RADIUS_KM / (111.32 * max(0.1, cos(Math.toRadians(c.lat))))
        return LatLngBounds.from(c.lat + dLat, c.lon + dLon, c.lat - dLat, c.lon - dLon)
    }

    /** Tiles a download of [b] from zoom 0 to MAX_ZOOM needs (standard web map tiling). */
    fun tileCount(b: LatLngBounds): Int = (0..MAX_ZOOM.toInt()).sumOf { z ->
        val n = (1 shl z).toDouble()
        fun x(lon: Double) = floor((lon + 180) / 360 * n).toInt()
        fun y(lat: Double) = Math.toRadians(lat).let { r -> floor((1 - ln(tan(r) + 1 / cos(r)) / PI) / 2 * n).toInt() }
        (x(b.longitudeEast) - x(b.longitudeWest) + 1) * (y(b.latitudeSouth) - y(b.latitudeNorth) + 1)
    }

    /** Saves the map around [c], replacing any saved area. */
    fun download(ctx: Context, c: Spot) {
        if (state is State.Downloading) return
        val b = bounds(c)
        if (tileCount(b) > MAX_TILES) { state = State.Failed("This area needs too many map tiles."); return }
        state = State.Downloading(0f)
        val def = OfflineTilePyramidRegionDefinition(STYLE, b, 0.0, MAX_ZOOM, ctx.resources.displayMetrics.density)
        val meta = JSONObject().put("lat", c.lat).put("lon", c.lon).put("ts", System.currentTimeMillis()).toString().toByteArray()
        removeAll(ctx) {
            OfflineManager.getInstance(ctx).createOfflineRegion(def, meta, object : OfflineManager.CreateOfflineRegionCallback {
                override fun onCreate(offlineRegion: OfflineRegion) = watch(offlineRegion, resume = true)
                override fun onError(error: String) { state = State.Failed(error) }
            })
        }
    }

    fun delete(ctx: Context) = removeAll(ctx) { state = State.None }

    private fun removeAll(ctx: Context, done: () -> Unit) {
        region?.let { it.setObserver(null); it.setDownloadState(OfflineRegion.STATE_INACTIVE) }; region = null
        OfflineManager.getInstance(ctx).listOfflineRegions(object : OfflineManager.ListOfflineRegionsCallback {
            override fun onList(offlineRegions: Array<OfflineRegion>?) {
                val all = offlineRegions.orEmpty().toMutableList()
                fun next() { if (all.isEmpty()) done() else all.removeAt(0).delete(object : OfflineRegion.OfflineRegionDeleteCallback {
                    override fun onDelete() = next()
                    override fun onError(error: String) = next()
                }) }
                next()
            }
            override fun onError(error: String) = done()
        })
    }

    private fun center(r: OfflineRegion): Pair<Spot, Long> = runCatching {
        JSONObject(String(r.metadata)).let { Spot(it.getDouble("lat"), it.getDouble("lon")) to it.getLong("ts") }
    }.getOrDefault(Spot(0.0, 0.0) to 0L)

    private fun watch(r: OfflineRegion, resume: Boolean) {
        region = r
        r.setObserver(object : OfflineRegion.OfflineRegionObserver {
            override fun onStatusChanged(status: OfflineRegionStatus) {
                if (region !== r) return
                if (status.completedResourceSize > MAX_BYTES) { // over OpenFreeMap's limit: stop and remove it
                    r.setObserver(null); r.setDownloadState(OfflineRegion.STATE_INACTIVE); region = null
                    r.delete(object : OfflineRegion.OfflineRegionDeleteCallback { override fun onDelete() {}; override fun onError(error: String) {} })
                    state = State.Failed("This area is bigger than 50 MB."); return
                }
                state = if (status.isComplete) {
                    r.setDownloadState(OfflineRegion.STATE_INACTIVE)
                    val (c, ts) = center(r); State.Ready(status.completedResourceSize, c, ts)
                } else State.Downloading(if (status.requiredResourceCount > 0) min(0.99f, status.completedResourceCount.toFloat() / status.requiredResourceCount) else 0f)
            }
            override fun onError(error: OfflineRegionError) { if (region === r) state = State.Failed(error.message) }
            override fun mapboxTileCountLimitExceeded(limit: Long) { if (region === r) state = State.Failed("This area needs too many map tiles.") }
        })
        r.getStatus(object : OfflineRegion.OfflineRegionStatusCallback {
            override fun onStatus(status: OfflineRegionStatus?) {
                if (status == null) return
                if (status.isComplete) { val (c, ts) = center(r); state = State.Ready(status.completedResourceSize, c, ts) }
                else if (resume) { state = State.Downloading(0f); r.setDownloadState(OfflineRegion.STATE_ACTIVE) } // cut off earlier: carry on
            }
            override fun onError(error: String?) {}
        })
    }
}

/** A pin on the map: a place, a person, or me. */
data class Pin(val title: String, val spot: Spot, val ts: Long, val color: String)

/**
 * The street map with pins. Tapping a pin opens the compass to it. [onCenter] gets the middle of the map after each
 * move, or null while the map shows too large an area to save (zoomed out).
 */
@Composable
fun StreetMap(pins: List<Pin>, me: Spot?, modifier: Modifier, open: (Sheet) -> Unit, onCenter: (Spot?) -> Unit = {}) {
    val centerNow by rememberUpdatedState(onCenter)
    val ctx = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    var map by remember { mutableStateOf<MapLibreMap?>(null) }
    var centered by remember { mutableStateOf(false) }
    val view = remember {
        MapView(ctx).apply {
            onCreate(null)
            getMapAsync { m ->
                m.uiSettings.isRotateGesturesEnabled = false
                m.setStyle(Style.Builder().fromUri(OfflineMap.STYLE)) { style ->
                    style.addSource(GeoJsonSource("pins"))
                    style.addLayer(CircleLayer("pins", "pins").withProperties(
                        PropertyFactory.circleRadius(9f), PropertyFactory.circleColor(Expression.toColor(Expression.get("color"))),
                        PropertyFactory.circleStrokeColor("#000000"), PropertyFactory.circleStrokeWidth(2.5f)))
                    map = m
                }
                m.addOnCameraIdleListener {
                    val cp = m.cameraPosition
                    centerNow(cp.target?.takeIf { cp.zoom >= 9 }?.let { t -> Spot(t.latitude, t.longitude) })
                }
                m.addOnMapClickListener { ll ->
                    val f = m.queryRenderedFeatures(m.projection.toScreenLocation(ll), "pins").firstOrNull() ?: return@addOnMapClickListener false
                    val p = f.geometry() as? Point ?: return@addOnMapClickListener false
                    if (f.getStringProperty("title") == "You") return@addOnMapClickListener false
                    open(Sheet.Find(f.getStringProperty("title"), Spot(p.latitude(), p.longitude()), f.getNumberProperty("ts").toLong())); true
                }
            }
        }
    }
    DisposableEffect(lifecycle) {
        val obs = LifecycleEventObserver { _, e ->
            when (e) {
                Lifecycle.Event.ON_START -> view.onStart(); Lifecycle.Event.ON_RESUME -> view.onResume()
                Lifecycle.Event.ON_PAUSE -> view.onPause(); Lifecycle.Event.ON_STOP -> view.onStop()
                else -> {}
            }
        }
        lifecycle.addObserver(obs)
        onDispose { lifecycle.removeObserver(obs); view.onPause(); view.onStop(); view.onDestroy() }
    }
    LaunchedEffect(map, pins, me) {
        val m = map ?: return@LaunchedEffect
        val all = pins + listOfNotNull(me?.let { Pin("You", it, 0, "#4C8DFF") })
        m.style?.getSourceAs<GeoJsonSource>("pins")?.setGeoJson(FeatureCollection.fromFeatures(all.map { p ->
            Feature.fromGeometry(Point.fromLngLat(p.spot.lon, p.spot.lat)).apply {
                addStringProperty("title", p.title); addNumberProperty("ts", p.ts); addStringProperty("color", p.color)
            }
        }))
        if (!centered) {
            val c = me ?: (OfflineMap.state as? OfflineMap.State.Ready)?.center ?: pins.firstOrNull()?.spot
            if (c != null) { centered = true; m.cameraPosition = CameraPosition.Builder().target(LatLng(c.lat, c.lon)).zoom(13.0).build() }
        }
    }
    AndroidView({ view }, modifier.clip(RoundedCornerShape(24.dp)))
}

/**
 * Save, update or delete the offline map, like the iPhone's OfflineMapCard. Saves around [me], or without a position
 * fix around [center], the middle of the map on screen (move the map to choose the area).
 */
@Composable
fun OfflineMapCard(me: Spot?, center: Spot? = null) {
    val ctx = LocalContext.current
    val around = me ?: center
    val where = if (me != null) "around you" else "around the middle of the map"
    Card {
        when (val s = OfflineMap.state) {
            OfflineMap.State.None -> {
                Txt("Save this map for the blackout", 18, FontWeight.Bold)
                Txt("Downloads the streets about 10 km $where (up to 50 MB) while you still have internet. Then the map works with none." +
                    if (me == null) " Zoom the map in on your area first." else "", 15, color = Theme.dim)
                PrimaryButton(if (around == null) "Zoom in on your area" else "Download map", enabled = around != null, icon = R.drawable.ic_download) { around?.let { OfflineMap.download(ctx, it) } }
            }
            is OfflineMap.State.Downloading -> {
                Txt("Saving the map… ${(s.progress * 100).toInt()}%", 18, FontWeight.Bold)
                Box(Modifier.fillMaxWidth().height(8.dp).clip(CircleShape).background(Theme.tile)) {
                    Box(Modifier.fillMaxWidth(s.progress.coerceIn(0.02f, 1f)).fillMaxHeight().background(Theme.text, CircleShape))
                }
                Txt("Keep the app open and the internet on.", 14, color = Theme.dim)
                GhostButton("Cancel") { OfflineMap.delete(ctx) }
            }
            is OfflineMap.State.Ready -> {
                Txt("Map saved", 18, FontWeight.Bold, Theme.safe)
                Txt("About 10 km around where you saved it, ${ago(s.ts)} · ${"%.1f".format(s.bytes / 1_000_000.0)} MB. It works with no internet.", 15, color = Theme.dim)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (around != null) GhostButton(if (me != null) "Save around me again" else "Save this area instead") { OfflineMap.download(ctx, around) }
                    GhostButton("Delete") { OfflineMap.delete(ctx) }
                }
            }
            is OfflineMap.State.Failed -> {
                Txt("The map wasn't saved", 18, FontWeight.Bold, Theme.help)
                Txt(s.why, 15, color = Theme.dim)
                GhostButton("Try again", enabled = around != null) { around?.let { OfflineMap.download(ctx, it) } }
            }
        }
    }
}
