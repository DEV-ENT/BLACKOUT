package it.blackout.mesh

import android.content.Intent
import android.graphics.BitmapFactory
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.material3.Text
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import java.util.Locale

// MARK: - Chat

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ChatTab(s: AppState, g: SavedGroup, messages: List<Message>, phones: Int, open: (Sheet) -> Unit) {
    val ctx = LocalContext.current
    var everyone by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    val shown = remember(messages, everyone) { messages.filter { it.public == everyone } }
    // Receipts change no message, so the list above stays the same: delivery states are read again on every update.
    val tick = s.tick
    val deliveries = remember(tick, shown) { shown.filter { it.sender == MeshEngine.deviceId }.associate { it.id to MeshEngine.delivery(it) } }
    val list = rememberLazyListState()
    LaunchedEffect(shown.size, everyone) { if (shown.isNotEmpty()) list.scrollToItem(shown.size - 1, 100_000) } // the offset is clamped: the very end
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) Thread {
            val jpeg = PhotoShrinker.jpeg(ctx, uri)
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                if (jpeg == null) Toast.makeText(ctx, "This photo can't be read", Toast.LENGTH_LONG).show() else open(Sheet.SendPhoto(jpeg))
            }
        }.start()
    }
    val typing = WindowInsets.isImeVisible
    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding().padding(bottom = if (typing) 0.dp else 84.dp)) { // room for the tab bar
        Column(Modifier.padding(horizontal = 20.dp).padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ScreenTitle(g.name, if (phones == 1) "1 phone in range" else "$phones phones in range")
            PillSwitch(g.name, "Everyone", everyone) { everyone = it }
            Txt(if (everyone) "Everyone nearby can read these, from any group." else "Only people in ${g.name} can read these.", 14, color = Theme.dim)
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp)) {
            if (shown.isEmpty()) item {
                Column(Modifier.fillMaxWidth().padding(top = 40.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Txt("No messages yet", 20, FontWeight.Bold)
                    Txt(if (everyone) "Messages here reach everyone nearby." else "Say hi, or tap I'm safe on Home.", 15, color = Theme.dim)
                }
            }
            itemsIndexed(shown, key = { _, m -> m.id }) { i, m ->
                val firstOfRun = i == 0 || shown[i - 1].sender != m.sender || CheckIn.of(shown[i - 1].text) != null
                MessageRow(m, firstOfRun, deliveries[m.id], open)
            }
        }
        Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            if (!everyone) RoundIcon(R.drawable.ic_photo_camera, 52.dp, desc = "Send a photo") {
                pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
            TextBox(draft, { draft = it.take(1000) }, if (everyone) "Message everyone" else "Message ${g.name}", singleLine = false,
                keyboard = KeyboardOptions(KeyboardCapitalization.Sentences), modifier = Modifier.weight(1f), shape = RoundedCornerShape(26.dp))
            RoundIcon(R.drawable.ic_arrow_upward, 52.dp, tint = if (draft.isBlank()) Theme.dim else Color.Black,
                bg = if (draft.isBlank()) Theme.tile else Color.White, desc = "Send") {
                val t = draft.trim()
                if (t.isNotEmpty() && meshReady(ctx)) {
                    draft = ""
                    val pub = everyone
                    Thread {
                        val fits = MeshEngine.send(t, pub)
                        if (!fits && MeshEngine.lora?.connected == true) android.os.Handler(android.os.Looper.getMainLooper()).post {
                            Toast.makeText(ctx, "Too long for LoRa: it will travel only over Bluetooth and Wi-Fi", Toast.LENGTH_LONG).show()
                        }
                    }.start()
                }
            }
        }
    }
}

@Composable
private fun MessageRow(m: Message, firstOfRun: Boolean, delivery: Delivery?, open: (Sheet) -> Unit) {
    val ctx = LocalContext.current
    val me = m.sender == MeshEngine.deviceId
    val check = if (!m.public) CheckIn.of(m.text) else null
    val place = if (m.public) Place.of(m.text) else null
    val time = clock(ctx, m.ts)
    Column(Modifier.fillMaxWidth().padding(top = if (firstOfRun) 8.dp else 0.dp), horizontalAlignment = if (me && check == null && place == null) Alignment.End else Alignment.Start) {
        when {
            check != null -> {
                val c = if (check == CheckIn.HELP) Theme.help else Theme.safe
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(c.copy(alpha = 0.12f)).padding(horizontal = 18.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Ic(if (check == CheckIn.HELP) R.drawable.ic_sos else R.drawable.ic_verified_user, c, 26.dp)
                    Spacer(Modifier.width(14.dp))
                    val who = if (me) (if (check == CheckIn.HELP) "You need help" else "You're safe") else (if (check == CheckIn.HELP) "${m.name} needs help" else "${m.name} is safe")
                    Txt(who, 18, FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 2)
                    CheckIn.battery(m.text)?.let { BatteryLabel(it); Spacer(Modifier.width(12.dp)) }
                    Txt(time, 15, color = Theme.dim)
                }
                CheckIn.spot(m.text)?.let { sp ->
                    if (!me) Txt("Find ${m.name}", 14, FontWeight.SemiBold, Theme.dim, Modifier.clickable { open(Sheet.Find(m.name, sp, m.ts)) }.padding(start = 18.dp, top = 6.dp))
                }
                if (me) Status(delivery, null)
            }
            place != null -> {
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Theme.card).clickable(enabled = place.spot != null) {
                    place.spot?.let { open(Sheet.Find(place.kind.word, it, m.ts)) } }.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    KindIcon(place.kind)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Txt("${if (me) "You" else m.name} shared ${place.kind.word.lowercase()}", 16, FontWeight.SemiBold)
                        if (place.note.isNotEmpty()) Txt(place.note, 15, color = Theme.dim)
                    }
                    Txt(time, 14, color = Theme.dim)
                }
            }
            else -> {
                if (!me && firstOfRun) Txt(m.name, 14, FontWeight.SemiBold, Theme.dim, Modifier.padding(start = 14.dp, bottom = 4.dp))
                val bubble = if (me) Color.White else Theme.tile
                val fg = if (me) Color.Black else Theme.text
                Column(Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(22.dp)).background(bubble)) {
                    m.photo?.let { jpeg ->
                        val img = remember(m.id) { decodePhoto(jpeg)?.asImageBitmap() }
                        if (img != null) Image(img, "Photo", Modifier.fillMaxWidth().aspectRatio(img.width.toFloat() / img.height.coerceAtLeast(1))
                            .clickable { open(Sheet.ViewPhoto(jpeg)) }, contentScale = ContentScale.Crop)
                    }
                    val text = if (m.photo != null) Photo.caption(m.text) else m.text
                    if (text.isNotEmpty()) Txt(text, 17, color = fg, modifier = Modifier.padding(horizontal = 16.dp, vertical = 11.dp))
                }
                if (me) Status(delivery, time) else Txt(time, 13, color = Theme.dim, modifier = Modifier.padding(start = 14.dp, top = 3.dp))
            }
        }
    }
}

/** Under my messages: still waiting, given to a phone, or confirmed by group members. */
@Composable
private fun Status(d: Delivery?, time: String?) {
    val label = when (d) {
        is Delivery.Delivered -> {
            val n = d.readers.map { it.name }
            "Delivered to " + when (n.size) { 1 -> n[0]; 2 -> "${n[0]} and ${n[1]}"; else -> "${n.size} people" }
        }
        Delivery.Sent -> "Sent to a phone nearby"
        Delivery.Waiting -> "Waiting for a phone in range"
        null -> null
    }
    Row(Modifier.padding(end = 12.dp, top = 3.dp).fillMaxWidth(), horizontalArrangement = Arrangement.End, verticalAlignment = Alignment.CenterVertically) {
        if (time != null) Txt(time + if (label != null) " · " else "", 13, color = Theme.dim)
        if (d is Delivery.Delivered) { Ic(R.drawable.ic_check_circle, Theme.dim, 14.dp); Spacer(Modifier.width(4.dp)) }
        if (label != null) Txt(label, 13, color = Theme.dim, maxLines = 1)
    }
}

// MARK: - Places

private data class Shared(val place: Place, val by: String, val ts: Long, val id: String)

@DrawableRes fun kindIcon(k: PlaceKind) = when (k) {
    PlaceKind.WATER -> R.drawable.ic_water_drop; PlaceKind.SHELTER -> R.drawable.ic_house
    PlaceKind.CHARGING -> R.drawable.ic_bolt; PlaceKind.MEDICAL -> R.drawable.ic_medical_services
}

@Composable fun KindIcon(k: PlaceKind) = Box(Modifier.size(48.dp).background(Theme.tile, CircleShape), contentAlignment = Alignment.Center) { Ic(kindIcon(k), Theme.text, 24.dp) }

/** My position while a screen that needs it is open. */
/**
 * Runs [start] while the app is on screen, and the stop function it returns when the app goes to the background or this
 * part of the screen goes away: GPS and the compass sensor must not keep running behind a closed app.
 */
@Composable fun WhileOnScreen(start: () -> (() -> Unit)) {
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        var stop: (() -> Unit)? = null
        val obs = androidx.lifecycle.LifecycleEventObserver { _, e ->
            if (e == androidx.lifecycle.Lifecycle.Event.ON_START && stop == null) stop = start()
            if (e == androidx.lifecycle.Lifecycle.Event.ON_STOP) { stop?.invoke(); stop = null }
        }
        lifecycle.addObserver(obs) // replays ON_START if the app is already on screen
        onDispose { lifecycle.removeObserver(obs); stop?.invoke(); stop = null }
    }
}

@Composable fun rememberMySpot(): Spot? {
    val ctx = LocalContext.current
    var spot by remember { mutableStateOf<Spot?>(null) }
    WhileOnScreen { Locator.watch(ctx) { spot = it } }
    return spot
}

@Composable
fun PlacesTab(messages: List<Message>, open: (Sheet) -> Unit) {
    var filter by remember { mutableStateOf<PlaceKind?>(null) }
    val me = rememberMySpot()
    val all = remember(messages) {
        messages.filter { it.public }.mapNotNull { m -> Place.of(m.text)?.let { Shared(it, if (m.sender == MeshEngine.deviceId) "you" else m.name, m.ts, m.id) } }
    }
    val shown = remember(all, filter, me) {
        val f = all.filter { filter == null || it.place.kind == filter }
        if (me == null) f.sortedByDescending { it.ts }
        else f.sortedWith(compareBy<Shared> { it.place.spot?.let { s -> Geo.distance(me, s) } ?: Double.MAX_VALUE }.thenByDescending { it.ts })
    }
    var onMap by remember { mutableStateOf(false) }
    if (onMap) {
        val people = remember(messages) { Person.all(messages, MeshEngine.deviceId) }
        val pins = remember(all, people) {
            all.mapNotNull { sh -> sh.place.spot?.let { Pin(sh.place.kind.word + if (sh.place.note.isNotEmpty()) ": " + sh.place.note.take(40) else "", it, sh.ts, "#FFFFFF") } } +
                people.mapNotNull { p -> p.spot?.let { Pin(p.name, it, p.spotTs, when (p.checkIn) { CheckIn.HELP -> "#FF453B"; CheckIn.SAFE -> "#33D64A"; null -> "#949494" }) } }
        }
        Column(Modifier.fillMaxSize().padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 100.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            ScreenTitle("Places", "Shared by everyone nearby, from any group")
            PillSwitch("List", "Map", onMap) { onMap = it }
            StreetMap(pins, me, Modifier.fillMaxWidth().weight(1f), open)
            Txt("Map data © OpenStreetMap contributors · OpenFreeMap · OpenMapTiles", 12, color = Theme.faint)
            OfflineMapCard(me)
        }
        return
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        ScreenTitle("Places", "Shared by everyone nearby, from any group")
        PillSwitch("List", "Map", onMap) { onMap = it }
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilterChip("All", null, filter == null) { filter = null }
            PlaceKind.entries.forEach { k -> FilterChip(k.word, kindIcon(k), filter == k) { filter = k } }
        }
        PrimaryButton("Share a place", icon = R.drawable.ic_add) { open(Sheet.AddPlace) }
        if (shown.isEmpty()) Card {
            Txt("Nothing shared yet", 18, FontWeight.Bold)
            Txt("Know where there is water, shelter, a place to charge phones or medical help? Share it so people nearby can find it.", 15, color = Theme.dim)
        } else Card(padding = 8.dp) {
            shown.forEach { sh ->
                val sp = sh.place.spot
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).clickable(enabled = sp != null) { sp?.let { open(Sheet.Find(sh.place.kind.word, it, sh.ts)) } }
                    .padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    KindIcon(sh.place.kind)
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Txt(sh.place.kind.word, 18, FontWeight.Bold)
                        if (sh.place.note.isNotEmpty()) Txt(sh.place.note, 16, color = Theme.text.copy(alpha = 0.85f))
                        Txt("By ${sh.by} · ${ago(sh.ts)}", 14, color = Theme.faint)
                    }
                    if (sp != null) Column(horizontalAlignment = Alignment.End) {
                        if (me != null) {
                            val d = Geo.distance(me, sp)
                            if (d <= maxOf(15, me.accuracy ?: 0, sp.accuracy ?: 0)) Chip("Here", Theme.safe)
                            else { Txt(Geo.meters(d), 15, FontWeight.SemiBold); Txt(Geo.compassWord(Geo.bearing(me, sp)), 13, color = Theme.dim) }
                        } else Ic(R.drawable.ic_navigation, Theme.dim, 26.dp)
                    }
                }
            }
        }
        if (me == null && all.any { it.place.spot != null }) Txt("Finding your position to sort places by distance…", 14, color = Theme.dim)
    }
}

@Composable private fun FilterChip(label: String, @DrawableRes icon: Int?, on: Boolean, tap: () -> Unit) =
    Row(Modifier.clip(CircleShape).background(if (on) Color.White else Theme.tile).clickable(role = Role.Tab, onClick = tap)
        .padding(horizontal = 16.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Ic(icon, if (on) Color.Black else Theme.text, 18.dp); Spacer(Modifier.width(6.dp)) }
        Txt(label, 16, FontWeight.SemiBold, if (on) Color.Black else Theme.text)
    }

@Composable
fun AddPlaceSheet(close: () -> Unit) {
    val ctx = LocalContext.current
    var kind by remember { mutableStateOf(PlaceKind.WATER) }
    var note by remember { mutableStateOf("") }
    var withSpot by remember { mutableStateOf(true) }
    var sending by remember { mutableStateOf(false) }
    SheetPage("Share a place", close) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PlaceKind.entries.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    row.forEach { k ->
                        val on = k == kind
                        Row(Modifier.weight(1f).clip(RoundedCornerShape(20.dp)).background(if (on) Color.White else Theme.card).clickable { kind = k }
                            .padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Ic(kindIcon(k), if (on) Color.Black else Theme.text, 24.dp); Spacer(Modifier.width(10.dp))
                            Txt(k.word, 17, FontWeight.SemiBold, if (on) Color.Black else Theme.text)
                        }
                    }
                }
            }
        }
        InputField("Details", note, { note = it.take(Place.MAX_NOTE) }, "Tap at the school gym, bring bottles", singleLine = false,
            keyboard = KeyboardOptions(KeyboardCapitalization.Sentences))
        Card { SwitchRow("Add my current position", withSpot, { withSpot = it }, "So people can find it with the compass. Share it only if you are at the place.") }
        if (withSpot && !Locator.allowed(ctx)) Txt("Location is off for DarkProof: the place will be shared without a position.", 14, color = Theme.help)
        Txt("Everyone nearby can see it, from any group. It stays on phones for up to 7 days.", 14, color = Theme.dim)
        PrimaryButton(if (sending) "Finding your position…" else "Share", enabled = !sending) {
            if (!meshReady(ctx)) return@PrimaryButton
            fun go(sp: Spot?) { Thread { MeshEngine.send(Place(kind, note, sp).text, public = true) }.start(); close() }
            if (withSpot && Locator.allowed(ctx)) { sending = true; Locator.fix(ctx) { go(it) } } else go(null)
        }
    }
}

// MARK: - People

@Composable
fun PeopleTab(s: AppState, a: MainActivity, g: SavedGroup, messages: List<Message>, phones: Int, open: (Sheet) -> Unit) {
    val people = remember(messages) { Person.all(messages, MeshEngine.deviceId) }
    val mine = remember(messages) { messages.lastOrNull { !it.public && it.sender == MeshEngine.deviceId && CheckIn.of(it.text) != null } }
    var confirmHelp by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { ScreenTitle("People", "${g.name} · ${people.size} ${if (people.size == 1) "person" else "people"} · $phones nearby") }
            RoundIcon(R.drawable.ic_settings, desc = "Settings") { open(Sheet.Settings) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
            BigCheckIn("I'm safe", R.drawable.ic_verified_user, Theme.safe, Color.Black, Modifier.weight(1f)) {
                checkIn(a, s, CheckIn.SAFE)
            }
            BigCheckIn("I need help", R.drawable.ic_sos, Theme.help, Color.White, Modifier.weight(1f)) { confirmHelp = true }
        }
        mine?.let { m -> Txt("Your last check-in: ${if (CheckIn.of(m.text) == CheckIn.HELP) "need help" else "safe"}, ${ago(m.ts)}.", 15, color = Theme.dim) }
        if (people.isEmpty()) Card {
            Txt("No one from ${g.name} yet", 18, FontWeight.Bold)
            Txt("Invite friends with a QR code, then keep DarkProof open near each other. People show up here once they write.", 15, color = Theme.dim)
        } else Card(padding = 12.dp) { people.forEach { p -> PersonRow(p) { sp -> open(Sheet.Find(p.name, sp, p.spotTs)) } } }
        SecondaryButton("Invite friends", icon = R.drawable.ic_qr_code_2) { open(Sheet.Invite) }
    }
    if (confirmHelp) Confirm("Send “I need help”?", "Your group sees it right away${if (s.shareLocation) ", with where you are" else ""}. Then write in Chat what you need and where you are.",
        "Send", danger = true, onYes = { confirmHelp = false; if (checkIn(a, s, CheckIn.HELP)) s.tab = 1 }, onNo = { confirmHelp = false })
}

/** The big check-in tiles, in the logo's shape. */
@Composable
private fun BigCheckIn(label: String, @DrawableRes icon: Int, bg: Color, fg: Color, modifier: Modifier, tap: () -> Unit) {
    Column(modifier.height(176.dp).clip(vaultShape(34.dp, 40.dp, 8.dp)).background(bg).clickable(role = Role.Button, onClick = tap).padding(20.dp),
        verticalArrangement = Arrangement.Bottom) {
        Ic(icon, fg, if (icon == R.drawable.ic_sos) 56.dp else 40.dp)
        Spacer(Modifier.height(10.dp))
        Txt(label, 22, FontWeight.Black, fg, maxLines = 1)
    }
}

// MARK: - Find (compass)

@Composable
fun FindSheet(f: Sheet.Find, close: () -> Unit) {
    val ctx = LocalContext.current
    val me = rememberMySpot()
    var heading by remember { mutableStateOf<Float?>(null) }
    var compass by remember { mutableStateOf(true) }
    WhileOnScreen { Compass.watch(ctx) { h -> if (h == null) compass = false else heading = h } }
    SheetPage(f.title, close) {
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (me == null) {
                Spacer(Modifier.height(40.dp))
                Txt(if (Locator.allowed(ctx)) "Finding your position…" else "Allow location to see how far", 18, FontWeight.SemiBold, Theme.dim)
            } else {
                val d = Geo.distance(me, f.spot); val b = Geo.bearing(me, f.spot)
                val near = d <= maxOf(15, me.accuracy ?: 0, f.spot.accuracy ?: 0)
                Box(Modifier.size(240.dp).background(Theme.card, CircleShape), contentAlignment = Alignment.Center) {
                    if (near) Ic(R.drawable.ic_my_location, Theme.safe, 96.dp)
                    else Ic(R.drawable.ic_navigation, Theme.text, 120.dp, Modifier.rotate((b - (heading ?: 0f)).toFloat()))
                }
                Txt(if (near) "Very close" else Geo.meters(d), 44, FontWeight.Black)
                Txt(if (near) "Within about ${Geo.meters(maxOf(15.0, (me.accuracy ?: 15).toDouble()))}. Look around or call out." else "${Geo.compassWord(b)} of you", 18, color = Theme.dim)
            }
            Txt("Position from ${ago(f.ts)}", 15, color = Theme.faint)
            if (!compass) Txt("This phone has no compass right now, so the arrow assumes the top of the phone points north.", 14, color = Theme.dim)
        }
        SecondaryButton("Open in a map app", icon = R.drawable.ic_map) {
            val geo = String.format(Locale.ROOT, "geo:%.5f,%.5f?q=%.5f,%.5f", f.spot.lat, f.spot.lon, f.spot.lat, f.spot.lon)
            runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(geo))) }.onFailure { Toast.makeText(ctx, "No map app on this phone", Toast.LENGTH_LONG).show() }
        }
    }
}

// MARK: - Photos

@Composable
fun SendPhotoSheet(jpeg: ByteArray, close: () -> Unit) {
    val ctx = LocalContext.current
    var caption by remember { mutableStateOf("") }
    val img = remember(jpeg) { decodePhoto(jpeg)?.asImageBitmap() }
    SheetPage("Send photo", close) {
        if (img != null) Image(img, "Photo", Modifier.fillMaxWidth().aspectRatio(img.width.toFloat() / img.height).clip(RoundedCornerShape(22.dp)), contentScale = ContentScale.Crop)
        Txt("${jpeg.size / 1000} KB, small enough to hop phone to phone.", 14, color = Theme.dim)
        InputField("Caption", caption, { caption = it.take(200) }, "Bridge is out", keyboard = KeyboardOptions(KeyboardCapitalization.Sentences))
        Txt("Only your group can see it. Phones without the newest DarkProof show “📷 Photo” instead.", 14, color = Theme.dim)
        PrimaryButton("Send photo") { if (!meshReady(ctx)) return@PrimaryButton; Thread { MeshEngine.send(Photo.text(caption), photo = jpeg) }.start(); close() }
    }
}

@Composable
fun ViewPhotoSheet(jpeg: ByteArray, close: () -> Unit) {
    val img = remember(jpeg) { decodePhoto(jpeg)?.asImageBitmap() }
    SheetPage("Photo", close) {
        if (img != null) Image(img, "Photo", Modifier.fillMaxWidth().aspectRatio(img.width.toFloat() / img.height).clip(RoundedCornerShape(16.dp)), contentScale = ContentScale.Fit)
    }
}

// MARK: - Ask

/** What the app knows right now, as plain text for the assistant, the same as the iPhone's Situation.swift. */
fun situation(g: SavedGroup, messages: List<Message>, me: Spot? = null): String {
    val lines = ArrayList<String>()
    val people = Person.all(messages, MeshEngine.deviceId)
    val phones = phonesInRange()
    lines += "Group \"${g.name}\": ${people.size} other ${if (people.size == 1) "person" else "people"} have written; $phones phone(s) in range right now."
    for (p in people.take(15)) {
        val parts = ArrayList<String>()
        parts += when (p.checkIn) {
            CheckIn.SAFE -> "safe (checked in ${ago(p.checkInTs)})"; CheckIn.HELP -> "NEEDS HELP (checked in ${ago(p.checkInTs)})"; null -> "has not checked in"
        }
        parts += "last heard ${ago(p.lastTs)}"
        p.battery?.let { parts += "battery $it%" }
        p.spot?.let { sp ->
            parts += if (me != null) "was ${Geo.meters(Geo.distance(me, sp))} ${Geo.compassWord(Geo.bearing(me, sp)).lowercase()} of you ${ago(p.spotTs)}"
            else "shared a position ${ago(p.spotTs)}"
        }
        lines += "- ${p.name}: " + parts.joinToString(", ")
    }
    val mine = messages.lastOrNull { !it.public && it.sender == MeshEngine.deviceId && CheckIn.of(it.text) != null }
    lines += if (mine != null) "You (the person asking) last checked in as ${if (CheckIn.of(mine.text) == CheckIn.HELP) "needing help" else "safe"}, ${ago(mine.ts)}."
        else "You (the person asking) have not checked in yet."
    val places = messages.filter { it.public }.mapNotNull { m -> Place.of(m.text)?.let { Triple(it, if (m.sender == MeshEngine.deviceId) "you" else m.name, m.ts) } }
        .let { l -> if (me == null) l.reversed() else l.sortedBy { it.first.spot?.let { sp -> Geo.distance(me, sp) } ?: Double.MAX_VALUE } }.take(10)
    lines += if (places.isEmpty()) "Shared places: none yet." else "Shared places (nearest first):"
    for ((pl, by, ts) in places) {
        val d = if (pl.spot != null && me != null) ", ${Geo.meters(Geo.distance(me, pl.spot))} ${Geo.compassWord(Geo.bearing(me, pl.spot)).lowercase()}" else ""
        lines += "- ${pl.kind.word}${if (pl.note.isEmpty()) "" else ": " + pl.note.take(120)} (by $by, ${ago(ts)}$d)"
    }
    val recent = messages.filter { !it.public && CheckIn.of(it.text) == null }.takeLast(8)
    if (recent.isNotEmpty()) {
        lines += "Latest group messages, oldest first:"
        for (m in recent) {
            val who = if (m.sender == MeshEngine.deviceId) "You" else m.name
            val text = if (m.photo != null) "[photo] " + Photo.caption(m.text) else m.text
            lines += "- $who, ${ago(m.ts)}: ${text.take(160)}"
        }
    }
    return lines.joinToString("\n")
}

/** The assistant's instructions and the group's situation, like the iPhone. */
fun aiSystem(g: SavedGroup, messages: List<Message>, me: Spot? = null) =
    LocalAi.instructions + "\n\n" + LocalAi.situationIntro + "\n" + situation(g, messages, me).take(AiContext.MAX_SITUATION_CHARS)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun AskTab(g: SavedGroup, messages: List<Message>) {
    var draft by remember { mutableStateOf("") }
    var choose by remember { mutableStateOf(false) }
    val m = LocalAi.model(LocalAi.selected)
    val ready = m != null && LocalAi.states[m.id] == LocalAi.State.Ready
    val turns = LocalAi.conversation
    val ctx = LocalContext.current
    val list = rememberLazyListState()
    LaunchedEffect(turns.size, turns.lastOrNull()?.text?.length) { if (turns.isNotEmpty()) list.scrollToItem(turns.size - 1) }
    fun send(q: String) { if (q.isNotBlank() && !LocalAi.busy) { LocalAi.ask(q.trim(), aiSystem(g, messages, Locator.lastKnown(ctx))); draft = "" } }
    val typing = WindowInsets.isImeVisible
    Column(Modifier.fillMaxSize().navigationBarsPadding().imePadding().padding(bottom = if (typing) 0.dp else 84.dp)) {
        Column(Modifier.padding(horizontal = 20.dp).padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) { ScreenTitle("Ask", "Offline assistant on this phone") }
                if (ready && turns.isNotEmpty() && !LocalAi.busy) GhostButton("New") { LocalAi.newConversation() }
            }
            if (ready) Row(Modifier.fillMaxWidth().clip(CircleShape).background(Theme.tile).clickable { choose = true }.padding(horizontal = 16.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically) {
                Ic(R.drawable.ic_auto_awesome, Theme.text, 18.dp); Spacer(Modifier.width(8.dp))
                Txt("${m!!.title} · " + (LocalAi.typicalSeconds(m)?.let { "about $it s per answer here" } ?: "speed shown after the first answer"),
                    14, FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 1)
                Txt("Change", 14, FontWeight.SemiBold, Theme.dim)
            }
        }
        if (!ready) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp)) {
                Card {
                    Txt("No AI model on this phone", 18, FontWeight.Bold)
                    Txt("Download one while you still have internet. It stays on the phone and works offline afterwards.", 15, color = Theme.dim)
                }
                ModelList()
            }
        } else {
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = PaddingValues(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp)) {
                if (turns.isEmpty()) item {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Txt("Ask anything: first aid, water, power, repairs, or what is happening in your group.", 15, color = Theme.dim)
                        listOf("Who in my group needs help, and who has not checked in?", "How do I make water safe to drink?",
                            "How do I stop heavy bleeding?", "How do I keep warm without power?").forEach { q ->
                            Txt(q, 15, FontWeight.SemiBold, modifier = Modifier.clip(RoundedCornerShape(18.dp)).background(Theme.card)
                                .clickable { send(q) }.padding(horizontal = 16.dp, vertical = 12.dp))
                        }
                    }
                }
                items(turns.size) { i ->
                    val t = turns[i]; val me = t.role == "user"
                    Box(Modifier.fillMaxWidth(), contentAlignment = if (me) Alignment.CenterEnd else Alignment.CenterStart) {
                        Text(if (t.text == "…") AnnotatedString("Thinking…") else if (me) AnnotatedString(t.text) else markdown(t.text),
                            Modifier.widthIn(max = 320.dp).clip(RoundedCornerShape(22.dp)).background(if (me) Color.White else Theme.tile)
                                .padding(horizontal = 16.dp, vertical = 11.dp),
                            color = when { me -> Color.Black; t.isError -> Theme.help; t.text == "…" -> Theme.dim; else -> Theme.text },
                            fontSize = 16.sp, lineHeight = 23.sp)
                    }
                }
                item { Txt("It works with no internet and can be wrong. Double-check anything important.", 13, color = Theme.faint, modifier = Modifier.padding(top = 4.dp)) }
            }
            Row(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                TextBox(draft, { draft = it.take(1000) }, "Ask anything", singleLine = false, keyboard = KeyboardOptions(KeyboardCapitalization.Sentences),
                    modifier = Modifier.weight(1f), shape = RoundedCornerShape(26.dp))
                if (LocalAi.busy) RoundIcon(R.drawable.ic_close, 52.dp, desc = "Stop") { LocalAi.stop() }
                else RoundIcon(R.drawable.ic_arrow_upward, 52.dp, tint = if (draft.isBlank()) Theme.dim else Color.Black,
                    bg = if (draft.isBlank()) Theme.tile else Color.White, desc = "Ask") { send(draft) }
            }
        }
    }
    if (choose) SheetPage("AI model", { choose = false }) { ModelList() }
}

/** The little Markdown models write: **bold**, and "* " or "- " bullets. */
fun markdown(text: String): AnnotatedString = buildAnnotatedString {
    text.lines().forEachIndexed { i, raw ->
        if (i > 0) append("\n")
        val line = raw.replace(Regex("^(\\s*)[*-] "), "$1• ").replace(Regex("^#{1,4} "), "")
        var bold = false
        line.split("**").forEachIndexed { k, part ->
            if (k > 0) bold = !bold
            if (bold) withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(part) } else append(part)
        }
    }
}

/** The models this phone can run, with download, use and delete. */
@Composable
private fun ModelList() {
    Txt("Models run entirely on this phone. Bigger ones answer better but slower. This phone has ${LocalAi.memoryGB} GB of memory: only models that fit are shown.",
        14, color = Theme.dim)
    if (LocalAi.catalog.isEmpty()) Txt("No model fits a phone with less than 4 GB of memory.", 15, FontWeight.SemiBold, Theme.help)
    LocalAi.catalog.forEach { m ->
        val st = LocalAi.states[m.id] ?: LocalAi.State.Missing
        Card {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt(m.title, 18, FontWeight.Bold, modifier = Modifier.weight(1f))
                if (LocalAi.selected == m.id && st == LocalAi.State.Ready) Chip("In use", Theme.safe)
            }
            Txt(m.detail, 15, color = Theme.dim)
            Txt("${"%.1f".format(m.bytes / 1e9)} GB · ${m.license}" + (LocalAi.typicalSeconds(m)?.let { " · about $it s per answer here" } ?: ""), 13, color = Theme.faint)
            when (st) {
                LocalAi.State.Missing -> PrimaryButton("Download ${"%.1f".format(m.bytes / 1e9)} GB", icon = R.drawable.ic_download) { LocalAi.download(m) }
                is LocalAi.State.Downloading -> {
                    Txt("Downloading ${(st.progress * 100).toInt()}%. Keep the internet on.", 15, FontWeight.SemiBold)
                    Box(Modifier.fillMaxWidth().height(8.dp).clip(CircleShape).background(Theme.tile)) {
                        Box(Modifier.fillMaxWidth(st.progress.coerceIn(0.02f, 1f)).fillMaxHeight().background(Theme.text, CircleShape))
                    }
                    GhostButton("Cancel") { LocalAi.cancel(m) }
                }
                LocalAi.State.Verifying -> Txt("Checking the download…", 15, FontWeight.SemiBold, Theme.dim)
                LocalAi.State.Ready -> Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (LocalAi.selected != m.id) GhostButton("Use this model") { LocalAi.select(m) }
                    GhostButton("Delete", enabled = !LocalAi.busy) { LocalAi.delete(m) }
                }
                is LocalAi.State.Failed -> {
                    Txt(st.why, 15, color = Theme.help)
                    GhostButton("Try again") { LocalAi.download(m) }
                }
            }
        }
    }
}
