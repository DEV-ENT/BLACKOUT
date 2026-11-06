package it.blackout.mesh

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

@Composable
fun DarkProofApp(s: AppState, a: MainActivity) {
    MaterialTheme(colorScheme = darkColorScheme(background = Theme.bg, surface = Theme.bg, primary = Theme.text, onPrimary = Color.Black)) {
        Box(Modifier.fillMaxSize().background(Theme.bg)) {
            val g = s.group
            if (g == null) {
                SetupFlow(s.invite, askName = true, modifier = Modifier.statusBarsPadding().navigationBarsPadding()) { name, group, created ->
                    a.started(name, group); s.invite = null
                    if (created) s.tab = TAB_INVITE_ONCE
                }
            } else {
                MainView(s, a)
                s.invite?.let { i ->
                    Confirm("Join ${i.name}?", "You'll see ${i.name}'s messages instead of ${g.name}'s. You can switch back in Settings.", "Join",
                        onYes = { a.switchTo(i); s.invite = null }, onNo = { s.invite = null })
                }
            }
        }
    }
}

private const val TAB_INVITE_ONCE = -1 // after creating a group: Home, with the invite sheet open

// MARK: - Setup

/** Welcome, then create or join a group. [askName] is false when adding another group later. */
@Composable
fun SetupFlow(invite: SavedGroup?, askName: Boolean, modifier: Modifier = Modifier, inSheet: Boolean = false, done: (name: String, group: SavedGroup, created: Boolean) -> Unit) {
    var mode by remember(invite) { mutableStateOf(if (invite != null) "join" else if (askName) "welcome" else "choose") }
    var name by remember { mutableStateOf("") }
    var groupName by remember(invite) { mutableStateOf(invite?.name ?: "") }
    var code by remember(invite) { mutableStateOf(invite?.code ?: "") }
    val ctx = LocalContext.current
    // In a sheet, the sheet scrolls: a second vertical scroll inside it would crash.
    val frame = if (inSheet) modifier.fillMaxWidth() else modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 24.dp, vertical = 16.dp)
    Column(frame, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        when (mode) {
            "welcome", "choose" -> {
                Spacer(Modifier.height(if (askName) 56.dp else 8.dp))
                Logo(96.dp)
                Spacer(Modifier.height(8.dp))
                Txt("Stay connected when everything goes dark.", 36, FontWeight.Black, lineHeight = 40)
                Txt("Messages travel phone to phone over Bluetooth and Wi-Fi. No internet, no signal, no account.", 17, color = Theme.dim)
                Spacer(Modifier.height(24.dp))
                PrimaryButton("Create a new group") { mode = "create" }
                SecondaryButton("Join with code") { mode = "join" }
                Txt("Free and private. No servers, ever.", 14, color = Theme.faint, modifier = Modifier.align(Alignment.CenterHorizontally))
            }
            "create" -> {
                FormTitle("Create a group", "For your family, friends or building. DarkProof makes a secret code for it, then you invite people with a QR code.") { mode = if (askName) "welcome" else "choose" }
                if (askName) InputField("Your name", name, { name = it.take(40) }, "Anna", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                InputField("Group name", groupName, { groupName = it.take(Invite.MAX_GROUP_NAME) }, "Family", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                PrimaryButton("Create group", enabled = (!askName || name.isNotBlank()) && groupName.isNotBlank()) {
                    done(name.trim(), SavedGroup(groupName.trim(), Invite.newCode()), true)
                }
            }
            else -> {
                if (invite != null) FormTitle("You're invited", "Join ${invite.name} to message each other without internet.", null)
                else FormTitle("Join a group", "Point your phone camera at your friend's invite QR and open the DarkProof link. Or type their code here.") { mode = if (askName) "welcome" else "choose" }
                if (askName) InputField("Your name", name, { name = it.take(40) }, "Anna", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                if (invite == null) {
                    InputField("Group code", code, { code = it.take(64) }, "XXXX-XXXX-XXXX-XXXX", keyboard = KeyboardOptions(KeyboardCapitalization.Characters))
                    InputField("Group name", groupName, { groupName = it.take(Invite.MAX_GROUP_NAME) }, "Family", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                }
                PrimaryButton(if (invite != null) "Join ${invite.name}" else "Join", enabled = (!askName || name.isNotBlank()) && code.trim().length >= 8) {
                    if (code.trim().length < 8) Toast.makeText(ctx, "The code has at least 8 characters", Toast.LENGTH_LONG).show()
                    else done(name.trim(), SavedGroup(groupName.trim().ifEmpty { "Group" }, code.trim()), false)
                }
            }
        }
    }
}

@Composable private fun FormTitle(title: String, sub: String, back: (() -> Unit)?) {
    if (back != null) Txt("Back", 16, FontWeight.SemiBold, Theme.dim, Modifier.clickable(onClick = back).padding(vertical = 8.dp))
    else Spacer(Modifier.height(24.dp))
    Txt(title, 32, FontWeight.Black, lineHeight = 38)
    Txt(sub, 16, color = Theme.dim)
    Spacer(Modifier.height(4.dp))
}

// MARK: - Main

sealed class Sheet {
    object Invite : Sheet(); object Groups : Sheet(); object Settings : Sheet(); object Radio : Sheet(); object NewGroup : Sheet()
    data class Find(val title: String, val spot: Spot, val ts: Long) : Sheet()
    object AddPlace : Sheet()
    data class SendPhoto(val jpeg: ByteArray) : Sheet()
    data class ViewPhoto(val jpeg: ByteArray) : Sheet()
}

/** Phones linked directly right now (not the LoRa radio). */
fun phonesInRange(): Int = (MeshEngine.router?.peerCount() ?: 0) - (if (MeshEngine.lora?.connected == true) 1 else 0)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MainView(s: AppState, a: MainActivity) {
    val tick = s.tick
    val messages = remember(tick) { MeshEngine.snapshot() }
    val phones = remember(tick) { phonesInRange() }
    var sheet by remember { mutableStateOf<Sheet?>(null) }
    LaunchedEffect(s.tab) { if (s.tab == TAB_INVITE_ONCE) { s.tab = 0; sheet = Sheet.Invite } }
    val g = s.group ?: return
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().statusBarsPadding()) {
            when (s.tab) {
                1 -> ChatTab(s, g, messages, phones) { sheet = it }
                2 -> PlacesTab(messages) { sheet = it }
                3 -> PeopleTab(s, a, g, messages, phones) { sheet = it }
                4 -> AskTab(g, messages)
                else -> HomeTab(s, a, g, messages, phones) { sheet = it }
            }
        }
        if (!((s.tab == 1 || s.tab == 4) && WindowInsets.isImeVisible)) TabBar(s.tab, Modifier.align(Alignment.BottomCenter)) { s.tab = it } // hidden while typing
    }
    val close = { sheet = null }
    when (val sh = sheet) {
        Sheet.Invite -> InviteSheet(g, close)
        Sheet.Groups -> GroupsSheet(g, a, { sheet = Sheet.Invite }, { sheet = Sheet.NewGroup }, close)
        Sheet.NewGroup -> SheetPage("Another group", close) {
            SetupFlow(null, askName = false, inSheet = true) { _, group, created -> a.switchTo(group); sheet = if (created) Sheet.Invite else null }
        }
        Sheet.Settings -> SettingsSheet(s, a, { sheet = Sheet.NewGroup }, close)
        Sheet.Radio -> RadioSheet(close)
        is Sheet.Find -> FindSheet(sh, close)
        Sheet.AddPlace -> AddPlaceSheet(close)
        is Sheet.SendPhoto -> SendPhotoSheet(sh.jpeg, close)
        is Sheet.ViewPhoto -> ViewPhotoSheet(sh.jpeg, close)
        null -> {}
    }
}

@Composable
private fun TabBar(selected: Int, modifier: Modifier, pick: (Int) -> Unit) {
    val tabs = listOf("Home" to R.drawable.ic_home, "Chat" to R.drawable.ic_chat, "Places" to R.drawable.ic_location_on,
        "People" to R.drawable.ic_group, "Ask" to R.drawable.ic_auto_awesome)
    Row(modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth()
        .clip(CircleShape).background(Theme.card).border(1.dp, Theme.line, CircleShape).padding(6.dp)) {
        tabs.forEachIndexed { i, (label, icon) ->
            val on = i == selected
            Column(Modifier.weight(1f).clip(CircleShape).background(if (on) Theme.tile else Color.Transparent)
                .clickable(role = Role.Tab) { pick(i) }.padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Ic(icon, if (on) Theme.text else Theme.dim, 24.dp)
                Txt(label, 12, FontWeight.SemiBold, if (on) Theme.text else Theme.dim, maxLines = 1)
            }
        }
    }
}

/** False (after telling the user) while the message store is still opening, so nothing is silently lost. */
fun meshReady(c: android.content.Context): Boolean {
    if (MeshEngine.router != null) return true
    Toast.makeText(c, "DarkProof is still starting. Try again in a moment.", Toast.LENGTH_LONG).show()
    return false
}

/** Sends a check-in with battery and, if the user turned it on, position. False if it couldn't be sent. */
fun checkIn(a: MainActivity, s: AppState, c: CheckIn): Boolean {
    if (!meshReady(a)) return false
    val battery = batteryPercent(a)
    fun go(spot: Spot?) = Thread { MeshEngine.send(c.text(battery, spot)) }.start()
    if (s.shareLocation && Locator.allowed(a)) Locator.fix(a) { go(it) } else go(null)
    Toast.makeText(a, if (c == CheckIn.HELP) "Sending to ${s.group?.name ?: "your group"}" else "Sent to ${s.group?.name ?: "your group"}", Toast.LENGTH_SHORT).show()
    return true
}

@Composable
private fun HomeTab(s: AppState, a: MainActivity, g: SavedGroup, messages: List<Message>, phones: Int, open: (Sheet) -> Unit) {
    var details by remember { mutableStateOf(false) }
    var confirmHelp by remember { mutableStateOf(false) }
    val people = remember(messages) { Person.all(messages, MeshEngine.deviceId) }
    val mine = remember(messages) { messages.lastOrNull { !it.public && it.sender == MeshEngine.deviceId && CheckIn.of(it.text) != null } }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).clickable { open(Sheet.Groups) }, verticalAlignment = Alignment.CenterVertically) {
                Logo(36.dp); Spacer(Modifier.width(12.dp))
                Txt(g.name, 26, FontWeight.Black, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                Ic(R.drawable.ic_expand_more, Theme.dim, 26.dp)
            }
            RoundIcon(R.drawable.ic_settings, desc = "Settings") { open(Sheet.Settings) }
        }
        if (s.permissionsMissing) Card {
            Txt("Nearby devices permission needed", 18, FontWeight.Bold, Theme.help)
            Txt("Without it DarkProof can't connect to other phones. Your messages are kept and go out once you allow it in Settings.", 15, color = Theme.dim)
            GhostButton("Open Settings") { a.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", a.packageName, null))) }
        } else if (s.locationMissing) Card {
            Txt("Precise location is off", 18, FontWeight.Bold)
            Txt("Android uses it to find nearby phones over Bluetooth and Wi-Fi, so DarkProof may find fewer phones. Check-ins and places go out without your position.", 15, color = Theme.dim)
            GhostButton("Open Settings") { a.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", a.packageName, null))) }
        }
        // Hero: the logo's shape, the number of phones in range.
        Column(Modifier.fillMaxWidth().clip(vaultShape()).background(Theme.card).clickable { details = !details }.padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(10.dp).background(if (phones > 0) Theme.safe else Theme.dim, CircleShape))
                Spacer(Modifier.width(10.dp))
                Txt(if (phones > 0) "Connected" else "Looking for phones", 17, FontWeight.SemiBold, if (phones > 0) Theme.safe else Theme.dim, Modifier.weight(1f))
                Ic(R.drawable.ic_expand_more, Theme.dim, 24.dp)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt("$phones", 88, FontWeight.Black, lineHeight = 96)
                Spacer(Modifier.width(14.dp))
                Txt(if (phones == 1) "phone\nin range" else "phones\nin range", 26, FontWeight.Bold, Theme.dim, lineHeight = 28)
            }
            Txt(if (phones > 0) "Your messages hop from phone to phone." else "Keep DarkProof open. Your messages wait and go out as soon as a phone is in range.", 15, color = Theme.dim)
            if (details) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
                val lines = listOfNotNull("Nearby: " + MeshEngine.transportStatus, MeshEngine.ble?.statusLine() ?: "Bluetooth LE: off",
                    MeshEngine.lora?.status ?: "LoRa: no radio", LanTest.statusLine())
                lines.forEach { Txt(it, 13, color = Theme.dim) }
            }
        }
        if (phones == 0) Card {
            Txt("No one in range yet", 20, FontWeight.Bold)
            Tip(R.drawable.ic_wifi, "Open DarkProof on both phones and stay within about 10–50 m. Walls cut the range: try outside or by a window.")
            Tip(R.drawable.ic_group, "Farther away? Messages hop through any phone with DarkProof in between. For kilometers, pair a LoRa radio.")
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ActionTile("I'm safe", R.drawable.ic_verified_user, Theme.safe, true, Modifier.weight(1f)) { checkIn(a, s, CheckIn.SAFE) }
            ActionTile("Need help", R.drawable.ic_sos, Theme.help, true, Modifier.weight(1f)) { confirmHelp = true }
            ActionTile("Invite", R.drawable.ic_qr_code_2, Theme.text, false, Modifier.weight(1f)) { open(Sheet.Invite) }
            ActionTile("Radio", R.drawable.ic_settings_input_antenna, Theme.text, false, Modifier.weight(1f)) { open(Sheet.Radio) }
        }
        mine?.let { m -> Txt("Your last check-in: ${if (CheckIn.of(m.text) == CheckIn.HELP) "need help" else "safe"}, ${ago(m.ts)}.", 15, color = Theme.dim) }
        SectionTitle("Your people", if (people.size > 3) "See all" else null) { s.tab = 3 }
        if (people.isEmpty()) Card {
            Txt("No one from ${g.name} yet", 18, FontWeight.Bold)
            Txt("Invite friends with a QR code, then keep DarkProof open near each other. People show up here once they write.", 15, color = Theme.dim)
            GhostButton("Invite") { open(Sheet.Invite) }
        } else Card(padding = 12.dp) {
            people.take(3).forEach { p -> PersonRow(p) { sp -> open(Sheet.Find(p.name, sp, p.spotTs)) } }
        }
    }
    if (confirmHelp) Confirm("Send “I need help”?", "Your group sees it right away${if (s.shareLocation) ", with where you are" else ""}. Then write in Chat what you need and where you are.",
        "Send", danger = true, onYes = { confirmHelp = false; if (checkIn(a, s, CheckIn.HELP)) s.tab = 1 }, onNo = { confirmHelp = false })
}

@Composable private fun Tip(@DrawableRes icon: Int, text: String) = Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
    Ic(icon, Theme.dim, 24.dp); Txt(text, 15, color = Theme.dim)
}

@Composable
private fun ActionTile(label: String, @DrawableRes icon: Int, color: Color, signature: Boolean, modifier: Modifier, tap: () -> Unit) {
    val shape = if (signature) vaultShape(18.dp, 26.dp, 6.dp) else RoundedCornerShape(26.dp)
    Column(modifier.clip(shape).background(Theme.card).clickable(role = Role.Button, onClick = tap).padding(vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.size(52.dp).background(if (color == Theme.text) Theme.tile else color.copy(alpha = 0.16f), CircleShape), contentAlignment = Alignment.Center) {
            Ic(icon, color, 28.dp)
        }
        Txt(label, 14, FontWeight.SemiBold, maxLines = 1)
    }
}

// MARK: - Sheets

@Composable
private fun InviteSheet(g: SavedGroup, close: () -> Unit) {
    val ctx = LocalContext.current
    val link = remember(g) { Invite.url(g.name, g.code) }
    val qr = remember(link) { qrBitmap(link).asImageBitmap() }
    var showCode by remember { mutableStateOf(false) }
    SheetPage("Invite", close) {
        Txt("Invite to ${g.name}", 20, FontWeight.Bold)
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Image(qr, "Invite QR code", Modifier.size(260.dp).clip(RoundedCornerShape(24.dp)).background(Color.White).padding(14.dp))
        }
        Txt("Your friend points their phone camera at this code, then opens the DarkProof link.", 15, color = Theme.dim)
        PrimaryButton("Share invite link", icon = R.drawable.ic_share) {
            ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, "Join my group ${g.name} on DarkProof: $link"), "Invite"))
        }
        Kicker("Or tell them the code")
        if (!showCode) GhostButton("Show code") { showCode = true }
        else Card {
            Txt(g.code, 22, FontWeight.Bold).also { }
            GhostButton("Copy code") {
                ctx.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Group code", g.code))
                Toast.makeText(ctx, "Code copied", Toast.LENGTH_SHORT).show()
            }
        }
    }
}

@Composable
private fun GroupsSheet(g: SavedGroup, a: MainActivity, invite: () -> Unit, add: () -> Unit, close: () -> Unit) {
    val others = remember(g) { Groups.others(a) }
    SheetPage("Groups", close) {
        Card {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt(g.name, 18, FontWeight.Bold, modifier = Modifier.weight(1f)); Chip("In use", Theme.safe)
            }
            GhostButton("Invite people") { invite() }
        }
        if (others.isNotEmpty()) {
            Kicker("Your other groups")
            Card(padding = 16.dp) {
                others.forEach { o ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Txt(o.name, 17, FontWeight.SemiBold, modifier = Modifier.weight(1f)); GhostButton("Switch") { a.switchTo(o); close() }
                    }
                }
            }
            Txt("Switching shows the other group's messages. This group's messages stay on the phone.", 14, color = Theme.dim)
        }
        SecondaryButton("Join or start another group", icon = R.drawable.ic_add) { add() }
    }
}

@Composable
private fun SettingsSheet(s: AppState, a: MainActivity, add: () -> Unit, close: () -> Unit) {
    var name by remember { mutableStateOf(s.name) }
    val debugPanel = remember { LanTest.panel(a) }
    val tick = s.tick
    SheetPage("Settings", close) {
        InputField("Your name", name, { name = it.take(40) }, keyboard = KeyboardOptions(KeyboardCapitalization.Words))
        if (name.trim() != s.name && name.isNotBlank()) GhostButton("Save") {
            s.name = name.trim(); a.getSharedPreferences("mesh", 0).edit().putString("name", s.name).apply(); MeshEngine.rename(s.name)
        }
        Card {
            SwitchRow("Share my location in check-ins", s.shareLocation, { s.setShareLocation(a, it) },
                "When you tap I'm safe or I need help, your group also sees where you are, and can find you with a compass. It works without internet. Only your group can read it.")
            if (s.shareLocation && !Locator.allowed(a)) Txt("Location is off for DarkProof. Allow it in Settings, or your check-ins go out without it.", 14, color = Theme.help)
        }
        Card {
            Txt("Notifications", 16, FontWeight.SemiBold)
            Txt("Alerts when your group writes or checks in, even when DarkProof is in the background. Someone asking for help always gets an alert of their own. Made on your phone: no internet needed.", 14, color = Theme.dim)
            if (android.os.Build.VERSION.SDK_INT >= 33 && a.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED)
                GhostButton("Turn on notifications") { a.askNotifications() }
        }
        Card {
            Txt("Share DarkProof", 16, FontWeight.SemiBold)
            Txt("Give the app to another Android phone without internet, with Quick Share or Bluetooth.", 14, color = Theme.dim)
            GhostButton("Share the app") { ApkShare.share(a) }
        }
        Card {
            Txt("Wi-Fi board", 16, FontWeight.SemiBold)
            Txt("People without the app join this phone's Wi-Fi network and read and post Public messages in their browser.", 14, color = Theme.dim)
            key(tick) {
                GhostButton(if (WifiBoard.running) "Stop the Wi-Fi board" else "Start the Wi-Fi board") {
                    if (WifiBoard.running) WifiBoard.stop() else WifiBoard.start(a) { MeshEngine.notifyUi() }
                    s.tick++
                }
                WifiBoard.status.takeIf { it != "Off" }?.let { Txt(it, 14, color = Theme.safe) }
            }
        }
        SecondaryButton("Join or start another group", icon = R.drawable.ic_add) { add() }
        if (debugPanel != null) Card {
            Txt("LAN test (debug build only)", 16, FontWeight.SemiBold)
            AndroidView({ debugPanel }, Modifier.fillMaxWidth())
        }
    }
}

@Composable
private fun RadioSheet(close: () -> Unit) {
    val found = remember { mutableStateListOf<Pair<String, String>>() }
    var scanning by remember { mutableStateOf(false) }
    var searched by remember { mutableStateOf(false) }
    LaunchedEffect(scanning) { if (scanning) { kotlinx.coroutines.delay(15_500); scanning = false; searched = true } } // LoraLink scans for 15 s
    val ctx = LocalContext.current
    SheetPage("LoRa radio", close) {
        Card {
            Txt(MeshEngine.lora?.status?.removePrefix("LoRa: ")?.replaceFirstChar { it.uppercase() } ?: "No radio", 18, FontWeight.Bold,
                if (MeshEngine.lora?.connected == true) Theme.safe else Theme.text)
            Txt("A Meshtastic radio carries messages for kilometers. Use one with the region already set (EU_868 in Europe). Turn it on near the phone.", 15, color = Theme.dim)
        }
        PrimaryButton(if (scanning) "Searching…" else "Search for radios", enabled = !scanning) {
            if (MeshEngine.lora == null) { Toast.makeText(ctx, "DarkProof is still starting. Try again in a moment.", Toast.LENGTH_LONG).show(); return@PrimaryButton }
            scanning = true; searched = false; found.clear()
            MeshEngine.lora?.scan { addr, nm -> if (found.none { it.first == addr }) found += addr to nm }
        }
        if (scanning && found.isEmpty()) Txt("Looking for radios nearby… Turn the radio on and keep it next to the phone.", 15, color = Theme.dim)
        if (searched && found.isEmpty()) Txt("No radio found. Turn it on, keep it next to the phone and search again.", 15, color = Theme.dim)
        if (found.isNotEmpty()) Card(padding = 16.dp) {
            found.forEach { (addr, nm) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Txt(nm, 17, FontWeight.SemiBold, modifier = Modifier.weight(1f))
                    GhostButton("Connect") {
                        MeshEngine.lora?.select(addr)
                        Toast.makeText(ctx, "Connecting: if asked, enter the PIN shown on the radio", Toast.LENGTH_LONG).show()
                        close()
                    }
                }
            }
        }
    }
}

/** Avatar with a colored ring: green safe, red help. */
@Composable fun Avatar(name: String, check: CheckIn?, size: Int = 56) {
    val ring = when (check) { CheckIn.SAFE -> Theme.safe; CheckIn.HELP -> Theme.help; null -> Theme.line }
    Box(Modifier.size(size.dp).border(3.dp, ring, CircleShape).padding(5.dp).background(Theme.tile, CircleShape), contentAlignment = Alignment.Center) {
        Txt(name.trim().take(1).uppercase().ifEmpty { "?" }, (size * 0.4).toInt(), FontWeight.Bold)
    }
}

@Composable
fun PersonRow(p: Person, find: (Spot) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp, horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
        Avatar(p.name, p.checkIn)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Txt(p.name, 18, FontWeight.SemiBold, maxLines = 1)
            when (p.checkIn) {
                CheckIn.SAFE -> Txt("Safe · ${ago(p.checkInTs)}", 15, FontWeight.Medium, Theme.safe)
                CheckIn.HELP -> Txt("Needs help · ${ago(p.checkInTs)}", 15, FontWeight.Medium, Theme.help)
                null -> Txt("Last seen ${ago(p.lastTs)}", 15, color = Theme.dim)
            }
        }
        p.battery?.let { BatteryLabel(it); Spacer(Modifier.width(12.dp)) }
        p.spot?.let { sp -> RoundIcon(R.drawable.ic_navigation, 46.dp, desc = "Find ${p.name}") { find(sp) } }
    }
}

/** Monospaced text helper for codes. */
val Mono = FontFamily.Monospace
