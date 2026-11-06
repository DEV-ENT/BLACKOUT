package it.blackout.mesh

import android.content.Context
import android.content.Intent
import android.widget.Toast
import androidx.activity.compose.BackHandler
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning

/**
 * QR codes and shared invites use the app link (darkproof://) for now. Set to true once darkproof.app serves its App
 * Links / Universal Links files, so invites also work for people who don't have the app yet (Invite.webUrl).
 */
const val INVITE_WEB_LINKS = false
fun inviteLink(g: SavedGroup) = if (INVITE_WEB_LINKS) Invite.webUrl(g.name, g.code) else Invite.url(g.name, g.code)

@Composable
fun DarkProofApp(s: AppState, a: MainActivity) {
    MaterialTheme(colorScheme = darkColorScheme(background = Theme.bg, surface = Theme.bg, primary = Theme.text, onPrimary = Color.Black)) {
        Box(Modifier.fillMaxSize().background(Theme.bg)) {
            val g = s.group
            if (g == null) {
                SetupFlow(s.invite, askName = true, modifier = Modifier.statusBarsPadding().navigationBarsPadding(), dropInvite = { s.invite = null }) { name, group, created ->
                    a.started(name, group); s.invite = null
                    if (created) s.sheet = Sheet.Invite
                }
            } else if (s.introPermissions) {
                PermissionIntro(a)
            } else {
                MainView(s, a)
                s.invite?.let { i ->
                    val saved = Groups.find(a, i.code) != null
                    Confirm(if (saved) "Switch to ${i.name}?" else "Join ${i.name}?",
                        "You'll see ${i.name}'s messages instead of ${g.name}'s. To switch back, tap the group name on Home.", if (saved) "Switch" else "Join",
                        onYes = { a.switchTo(Groups.find(a, i.code) ?: i); s.invite = null; s.tab = 0 }, onNo = { s.invite = null })
                }
            }
        }
    }
}

// MARK: - Setup

/**
 * Welcome, then create or join a group. [askName] is false when adding another group later ([myName] is known then).
 * [dropInvite]: back from an invite that was opened, to the welcome screen.
 */
@Composable
fun SetupFlow(invite: SavedGroup?, askName: Boolean, modifier: Modifier = Modifier, inSheet: Boolean = false, myName: String = "",
              dropInvite: () -> Unit = {}, done: (name: String, group: SavedGroup, created: Boolean) -> Unit) {
    val start = if (askName) "welcome" else "choose"
    var mode by rememberSaveable(invite) { mutableStateOf(if (invite != null) "join" else start) }
    var name by rememberSaveable { mutableStateOf("") }
    var groupName by rememberSaveable(invite) { mutableStateOf(invite?.name ?: "") }
    var code by rememberSaveable(invite) { mutableStateOf(invite?.code ?: "") }
    val ctx = LocalContext.current
    fun back() { if (invite != null) dropInvite() else mode = start }
    BackHandler(enabled = mode != start) { back() } // the system Back goes back a step, not out of the app
    // In a sheet, the sheet scrolls: a second vertical scroll inside it would crash.
    val frame = if (inSheet) modifier.fillMaxWidth() else modifier.fillMaxSize().verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 24.dp, vertical = 16.dp)
    Column(frame, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        when (mode) {
            "welcome", "choose" -> {
                Spacer(Modifier.height(if (askName) 56.dp else 8.dp))
                Logo(96.dp)
                Spacer(Modifier.height(8.dp))
                Txt("Stay connected when everything goes dark.", 36, FontWeight.Black, lineHeight = 40)
                Txt("Messages travel phone to phone over Bluetooth and Wi-Fi, and over the internet when there is some. No account.", 17, color = Theme.dim)
                Spacer(Modifier.height(24.dp))
                PrimaryButton("Create a group") { mode = "create" }
                SecondaryButton("Join a group") { mode = "join" }
                Txt("Free and private. No servers of ours.", 14, color = Theme.dim, modifier = Modifier.align(Alignment.CenterHorizontally))
            }
            "create" -> {
                FormTitle("Create a group", "For your family, friends or building. DarkProof makes a secret code for it, then you invite people with a QR code.") { back() }
                if (askName) InputField("Your name", name, { name = it.take(40) }, "Anna", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                val who = (if (askName) name else myName).trim()
                val fallback = remember(who) { // "Ana's group", or "Ana's group 2" when that name is taken
                    val base = (if (who.isNotEmpty()) "$who's group" else "My group").take(Invite.MAX_GROUP_NAME - 2)
                    val taken = Groups.all(ctx).map { it.name }.toSet()
                    generateSequence(1) { it + 1 }.map { if (it == 1) base else "$base $it" }.first { it !in taken }
                }
                InputField("Group name (you can leave it)", groupName, { groupName = it.take(Invite.MAX_GROUP_NAME) }, fallback, keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                PrimaryButton("Create group", enabled = !askName || name.isNotBlank()) {
                    done(name.trim(), SavedGroup(groupName.trim().ifEmpty { fallback }, Invite.newCode()), true)
                }
                if (askName && name.isBlank()) Txt("Type your name first. Your group sees it next to your messages.", 14, color = Theme.dim)
            }
            else -> {
                if (invite != null) FormTitle("You're invited", "Join ${invite.name} to message each other without internet.") { back() }
                else FormTitle("Join a group", "Scan the invite QR code on your friend's phone, or type the code they tell you.") { back() }
                if (askName) InputField("Your name", name, { name = it.take(40) }, "Anna", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                if (invite == null) {
                    SecondaryButton("Scan invite QR code", icon = R.drawable.ic_qr_code_2) {
                        scanInvite(ctx) { (n, c) -> code = c; groupName = n }
                    }
                    // A pasted invite link works too: its code is used and its name filled in.
                    InputField("Group code", code, { v -> Invite.parse(v)?.let { (n, c) -> code = c; if (groupName.isBlank() || groupName == "Group") groupName = n } ?: run { code = v.take(64) } },
                        "XXXX-XXXX-XXXX-XXXX", keyboard = KeyboardOptions(KeyboardCapitalization.Characters))
                    InputField("Group name (you can leave it)", groupName, { groupName = it.take(Invite.MAX_GROUP_NAME) }, "Family", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
                }
                val clean = Invite.normalizeCode(code)
                val why = when {
                    askName && name.isBlank() -> "Type your name first. Your group sees it next to your messages."
                    code.isBlank() -> "Scan the QR code, or type or paste the group code."
                    clean.length < Invite.MIN_CODE_LENGTH -> "A group code has at least ${Invite.MIN_CODE_LENGTH} characters."
                    else -> null
                }
                PrimaryButton(if (invite != null) "Join ${invite.name}" else "Join", enabled = why == null) {
                    done(name.trim(), SavedGroup(groupName.trim().ifEmpty { invite?.name ?: "Group" }, clean), false)
                }
                if (why != null) Txt(why, 14, color = Theme.dim)
                else if (!Invite.isGeneratedCode(clean)) Txt("This isn't a code DarkProof made. Short or simple codes can be guessed, and anyone who guesses it can read the group.",
                    14, color = Theme.help)
            }
        }
    }
}

/** Opens Google's QR scanner (no camera permission needed) and passes on the group name and code of a DarkProof invite. */
fun scanInvite(c: Context, got: (Pair<String, String>) -> Unit) {
    val opts = GmsBarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build()
    runCatching {
        GmsBarcodeScanning.getClient(c, opts).startScan()
            .addOnSuccessListener { b ->
                val invite = b.rawValue?.let(Invite::parse)
                if (invite != null) got(invite) else Toast.makeText(c, "This QR code isn't a DarkProof invite.", Toast.LENGTH_LONG).show()
            }
            .addOnFailureListener { Toast.makeText(c, "The scanner isn't ready on this phone. Point the camera app at the code, or type it.", Toast.LENGTH_LONG).show() }
    }.onFailure { Toast.makeText(c, "The scanner isn't ready on this phone. Point the camera app at the code, or type it.", Toast.LENGTH_LONG).show() }
}

@Composable private fun FormTitle(title: String, sub: String, back: (() -> Unit)?) {
    if (back != null) Txt("Back", 16, FontWeight.SemiBold, Theme.dim, Modifier.clickable(role = Role.Button, onClick = back).padding(vertical = 8.dp))
    else Spacer(Modifier.height(24.dp))
    Txt(title, 32, FontWeight.Black, lineHeight = 38)
    Txt(sub, 16, color = Theme.dim)
    Spacer(Modifier.height(4.dp))
}

/** The last setup step: what Android is about to ask, and why, before it asks. */
@Composable
private fun PermissionIntro(a: MainActivity) {
    Column(Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Spacer(Modifier.height(40.dp))
        Logo(64.dp)
        Txt("One more step", 32, FontWeight.Black, lineHeight = 38)
        Txt("DarkProof will ask for nearby devices, location and notifications so phones can find each other and you get alerts.", 17, color = Theme.dim)
        IntroRow(R.drawable.ic_wifi, "Nearby devices", "Connects to phones around you over Bluetooth and Wi-Fi. Without it DarkProof can't reach anyone.")
        IntroRow(R.drawable.ic_location_on, "Location", "Android needs it to find phones nearby. Others see where you are only if you turn that on.")
        IntroRow(R.drawable.ic_notifications, "Notifications", "Tells you when someone in your group needs help or writes.")
        Spacer(Modifier.height(8.dp))
        PrimaryButton("Continue") { a.permissions() }
    }
}

@Composable private fun IntroRow(@DrawableRes icon: Int, title: String, text: String) = Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
    Box(Modifier.size(44.dp).background(Theme.tile, CircleShape), contentAlignment = Alignment.Center) { Ic(icon, Theme.text, 22.dp) }
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Txt(title, 17, FontWeight.SemiBold); Txt(text, 15, color = Theme.dim)
    }
}

// MARK: - Main

sealed class Sheet {
    object Invite : Sheet(); object Groups : Sheet(); object Settings : Sheet(); object Radio : Sheet(); object NewGroup : Sheet()
    data class Find(val title: String, val spot: Spot, val ts: Long) : Sheet()
    object AddPlace : Sheet()
    data class SendPhoto(val jpeg: ByteArray) : Sheet()
    data class ViewPhoto(val jpeg: ByteArray) : Sheet()
    /** After "I need help" went out: what is needed, how many people. [group]: where it went (null: the group in use). */
    data class HelpDetails(val group: String?) : Sheet()
    object Practice : Sheet()
    object Vouch : Sheet()
    data class Person(val id: String) : Sheet()

    companion object {
        /** As text, to come back after Android ended the app in the background (photos are not kept). */
        fun save(s: Sheet): String? = when (s) {
            Invite -> "invite"; Groups -> "groups"; Settings -> "settings"; Radio -> "radio"; NewGroup -> "newgroup"; AddPlace -> "addplace"
            Practice -> "practice"; Vouch -> "vouch"
            is Person -> "person\n${s.id}"
            is HelpDetails -> "help\n${s.group ?: ""}"
            is Find -> "find\n${s.title}\n${s.spot.lat}\n${s.spot.lon}\n${s.spot.accuracy ?: ""}\n${s.ts}"
            is SendPhoto, is ViewPhoto -> null
        }
        fun restore(t: String): Sheet? {
            val p = t.split("\n")
            return when (p[0]) {
                "invite" -> Invite; "groups" -> Groups; "settings" -> Settings; "radio" -> Radio; "newgroup" -> NewGroup; "addplace" -> AddPlace
                "practice" -> Practice; "vouch" -> Vouch
                "person" -> p.getOrNull(1)?.let(::Person)
                "help" -> HelpDetails(p.getOrNull(1)?.ifEmpty { null })
                "find" -> runCatching { Find(p[1], Spot(p[2].toDouble(), p[3].toDouble(), p[4].toIntOrNull()), p[5].toLong()) }.getOrNull()
                else -> null
            }
        }
    }
}

/** Phones linked directly right now (Nearby, Bluetooth LE, Wi-Fi network), each once; not radios or relays. */
fun phonesInRange(): Int = MeshEngine.linkedNodes().size

/** Every way out of this phone right now, so texts say truthfully where a message goes. */
data class Links(val phones: Int, val relays: Int, val radio: Boolean) {
    val any get() = phones > 0 || relays > 0 || radio
    companion object {
        fun now() = Links(phonesInRange(), MeshEngine.nostr?.connected ?: 0, MeshEngine.lora?.connected == true || MeshEngine.meshcore?.connected == true)
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MainView(s: AppState, a: MainActivity) {
    val tick = s.tick
    val moderated = s.moderated
    val messages = remember(tick, moderated) { MeshEngine.snapshot().filter { Moderation.visible(a, it) } } // blocked and reported hidden everywhere
    val all = remember(tick, moderated) { MeshEngine.snapshotAll().filter { Moderation.visible(a, it) } }
    val phones = remember(tick) { phonesInRange() }
    val g = s.group ?: return
    // Read: the group's chat on screen. Unread: the Chat tab's badge.
    LaunchedEffect(s.tab, s.everyone, all, g) {
        if (s.tab == 1 && !s.everyone) all.lastOrNull { it.group == g.code }?.let { ReadMarks.markRead(a, g.code, it.ts) }
    }
    val unread = remember(all, s.tab, s.everyone, g) { if (s.tab == 1 && !s.everyone) 0 else ReadMarks.unread(a, all, g.code) }
    BackHandler(enabled = s.tab != 0) { s.tab = 0 } // Back from another tab goes Home first
    Box(Modifier.fillMaxSize()) {
        Box(Modifier.fillMaxSize().statusBarsPadding()) {
            when (s.tab) {
                1 -> ChatTab(s, g, messages, phones) { s.sheet = it }
                2 -> PlacesTab(s, messages) { s.sheet = it }
                3 -> PeopleTab(s, a, g, messages, phones) { s.sheet = it }
                4 -> AskTab(g, messages)
                else -> HomeTab(s, a, g, messages, all) { s.sheet = it }
            }
        }
        if (!((s.tab == 1 || s.tab == 4) && WindowInsets.isImeVisible)) TabBar(s.tab, unread, Modifier.align(Alignment.BottomCenter)) { s.tab = it } // hidden while typing
        s.banner?.let { AlertBanner(it, s, a, Modifier.align(Alignment.TopCenter)) }
    }
    val close = { s.sheet = null }
    when (val sh = s.sheet) {
        Sheet.Invite -> { LaunchedEffect(Unit) { Ready.mark(a, Ready.INVITE) }; InviteSheet(g, a, close) }
        Sheet.Groups -> GroupsSheet(g, a, all, { s.sheet = Sheet.Invite }, { s.sheet = Sheet.NewGroup }, close)
        Sheet.NewGroup -> SheetPage("Another group", close) {
            SetupFlow(null, askName = false, inSheet = true, myName = s.name) { _, group, created -> a.switchTo(group); s.tab = 0; s.sheet = if (created) Sheet.Invite else null }
        }
        Sheet.Settings -> SettingsSheet(s, a, { s.sheet = Sheet.NewGroup }, close)
        Sheet.Radio -> ConnectionsSheet(s, a, close)
        is Sheet.Find -> FindSheet(sh, close)
        Sheet.AddPlace -> AddPlaceSheet(close)
        is Sheet.SendPhoto -> SendPhotoSheet(sh.jpeg, close)
        is Sheet.ViewPhoto -> ViewPhotoSheet(sh.jpeg, close)
        is Sheet.HelpDetails -> HelpDetailsSheet(s, a, sh.group, close)
        Sheet.Practice -> PracticeSheet(a, close)
        Sheet.Vouch -> VouchSheet(s, a, close)
        is Sheet.Person -> PersonSheet(s, a, messages, sh.id, close)
        null -> {}
    }
    if (s.askHelp) HelpConfirm(s, a)
    if (s.tileHowTo) Info("Add the “I'm safe” tile", "Swipe down twice from the top of the screen, tap the pencil, then drag “I'm safe” into your tiles. " +
        "One tap then tells your group you're safe, without opening DarkProof.") { s.tileHowTo = false; Ready.mark(a, Ready.TILE) }
}

/**
 * "I need help" from Home, People, a shortcut, a tile, a banner or a notification: opens the help sheet, where one tap
 * sends it, with what is needed if the user adds it first. One message, like the iPhone (the old confirm dialog is unused).
 */
@Composable
private fun HelpConfirm(s: AppState, a: MainActivity) {
    LaunchedEffect(Unit) { s.askHelp = false; s.sheet = Sheet.HelpDetails(s.helpGroup) }
}

@Suppress("unused")
@Composable
private fun HelpConfirmDialog(s: AppState, a: MainActivity) {
    val links = remember(s.tick) { Links.now() }
    val to = Groups.find(a, s.helpGroup)?.name ?: s.group?.name ?: "your group"
    val where = if (s.shareLocation) ", with where you are" else ""
    Confirm("Send “I need help” to $to?",
        (if (links.any) "It goes out now and hops from phone to phone to your group$where."
         else "No phone or internet is in reach right now. It waits on this phone$where and goes out as soon as one is.") + " Next you can say what you need.",
        "Send", danger = true,
        onYes = { s.askHelp = false; if (checkIn(a, s, CheckIn.HELP, group = s.helpGroup)) s.sheet = Sheet.HelpDetails(s.helpGroup) },
        onNo = { s.askHelp = false })
}

/** While DarkProof is open: someone needs help, asks if I'm safe, or another group wrote. */
@Composable
private fun AlertBanner(al: Notifier.Alert, s: AppState, a: MainActivity, modifier: Modifier) {
    LaunchedEffect(al) { if (!al.urgent) { kotlinx.coroutines.delay(6_000); if (s.banner == al) s.banner = null } }
    fun openChat() {
        s.banner = null
        Groups.find(a, al.group)?.takeIf { it.code != s.group?.code }?.let(a::switchTo)
        s.everyone = false; s.tab = 1
    }
    val color = if (al.urgent && !al.ask) Theme.help else Theme.text
    Column(modifier.statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp).fillMaxWidth().clip(RoundedCornerShape(24.dp))
        .background(Theme.tile).border(1.dp, if (al.urgent) color.copy(alpha = 0.6f) else Theme.line, RoundedCornerShape(24.dp))
        .clickable(role = Role.Button) { openChat() }.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Ic(if (al.ask) R.drawable.ic_notifications else if (al.urgent) R.drawable.ic_sos else R.drawable.ic_chat, color, 24.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Txt(al.title, 17, FontWeight.Bold, color, maxLines = 2)
                Txt(al.body, 14, color = Theme.dim, maxLines = 2)
            }
            RoundIcon(R.drawable.ic_close, 34.dp, desc = "Close") { s.banner = null }
        }
        if (al.ask) Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            CapsuleChoice("I'm safe", Theme.safe, Color.Black, Modifier.weight(1f)) { s.banner = null; checkIn(a, s, CheckIn.SAFE, group = al.group) }
            CapsuleChoice("I need help", Theme.help, Color.White, Modifier.weight(1f)) { s.banner = null; s.helpGroup = al.group; s.askHelp = true }
        }
    }
}

/** A colored capsule button for the one-tap answers. */
@Composable fun CapsuleChoice(text: String, bg: Color, fg: Color, modifier: Modifier = Modifier, tap: () -> Unit) =
    Box(modifier.heightIn(min = 48.dp).clip(CircleShape).background(bg).clickable(role = Role.Button, onClick = tap), contentAlignment = Alignment.Center) {
        Txt(text, 16, FontWeight.Bold, fg, maxLines = 1)
    }

@Composable
private fun TabBar(selected: Int, unread: Int, modifier: Modifier, pick: (Int) -> Unit) {
    val tabs = listOf("Home" to R.drawable.ic_home, "Chat" to R.drawable.ic_chat, "Places" to R.drawable.ic_location_on,
        "People" to R.drawable.ic_group, "Ask" to R.drawable.ic_auto_awesome)
    Row(modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 8.dp).fillMaxWidth()
        .clip(CircleShape).background(Theme.card).border(1.dp, Theme.line, CircleShape).padding(6.dp)) {
        tabs.forEachIndexed { i, (label, icon) ->
            val on = i == selected
            val badge = if (i == 1 && unread > 0) unread else 0
            Column(Modifier.weight(1f).clip(CircleShape).background(if (on) Theme.tile else Color.Transparent)
                .clickable(role = Role.Tab) { pick(i) }.padding(vertical = 8.dp)
                .semantics { if (badge > 0) contentDescription = "$label, $badge new" }, horizontalAlignment = Alignment.CenterHorizontally) {
                Box {
                    Ic(icon, if (on) Theme.text else Theme.dim, 24.dp)
                    if (badge > 0) Txt(if (badge > 99) "99+" else "$badge", 11, FontWeight.Bold, Color.Black,
                        Modifier.align(Alignment.TopEnd).offset(x = 12.dp, y = (-6).dp).background(Color.White, CircleShape).padding(horizontal = 5.dp), maxLines = 1)
                }
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

/**
 * Sends a check-in with battery and, if the user turned it on, position (waiting up to 10 s for one), to [group] or
 * the group in use. Says truthfully whether it went out and whether the position is in it. False if it couldn't be sent.
 */
fun checkIn(a: MainActivity, s: AppState, c: CheckIn, needs: Set<Need> = emptySet(), people: Int? = null, group: String? = null): Boolean {
    if (!meshReady(a)) return false
    val battery = batteryPercent(a)
    val to = Groups.find(a, group)?.name ?: s.group?.name ?: "your group"
    var answered = false
    fun go(spot: Spot?, lost: Boolean) {
        answered = true
        Thread { MeshEngine.send(c.text(battery, spot, needs, people), group = group) }.start()
        val pos = if (lost) " without your position: no GPS fix yet" else ""
        Toast.makeText(a, if (Links.now().any) "Sent to $to$pos" else "Saved$pos. It goes out when a phone or the internet is in reach.", Toast.LENGTH_LONG).show()
    }
    if (s.shareLocation && Locator.allowed(a)) {
        Locator.fix(a) { go(it, it == null) }
        if (!answered) Toast.makeText(a, "Finding your position…", Toast.LENGTH_SHORT).show()
    } else go(null, false)
    return true
}

@Composable
private fun HomeTab(s: AppState, a: MainActivity, g: SavedGroup, messages: List<Message>, all: List<Message>, open: (Sheet) -> Unit) {
    var details by rememberSaveable { mutableStateOf(false) }
    val tick = s.tick
    val links = remember(tick) { Links.now() }
    val people = remember(messages) { Person.all(messages, MeshEngine.deviceId) }
    val mine = remember(messages) { messages.lastOrNull { !it.public && it.sender == MeshEngine.deviceId && CheckIn.of(it.text) != null } }
    val others = remember(all) { Groups.others(a).map { o -> ReadMarks.unread(a, all, o.code) to groupNeedsHelp(all, o.code) } }
    val hours = remember(tick / 20) { BatteryLife.hoursLeft(a) }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(top = 8.dp, bottom = 120.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).clickable(role = Role.Button) { open(Sheet.Groups) }.semantics { contentDescription = "${g.name}. Switch group" },
                verticalAlignment = Alignment.CenterVertically) {
                Logo(36.dp); Spacer(Modifier.width(12.dp))
                Txt(g.name, 26, FontWeight.Black, maxLines = 1, modifier = Modifier.weight(1f, fill = false))
                Ic(R.drawable.ic_expand_more, Theme.dim, 26.dp)
                // Something new in another group: a dot (red if someone there needs help).
                if (others.any { it.second }) Box(Modifier.size(10.dp).background(Theme.help, CircleShape))
                else if (others.any { it.first > 0 }) Box(Modifier.size(10.dp).background(Theme.text, CircleShape))
            }
            RoundIcon(R.drawable.ic_settings, desc = "Settings") { open(Sheet.Settings) }
        }
        PhoneProblems(s, a)
        // Hero: the logo's shape, the number of phones in range, and every other way out.
        Column(Modifier.fillMaxWidth().clip(vaultShape()).background(Theme.card).clickable { details = !details }.padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            val (label, on) = when {
                links.phones > 0 -> "Connected" to true
                links.relays > 0 -> "Online" to true
                links.radio -> "LoRa radio linked" to true
                s.permissionsMissing -> "Not looking for phones" to false
                else -> "Looking for phones" to false
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(10.dp).background(if (on) Theme.safe else Theme.dim, CircleShape))
                Spacer(Modifier.width(10.dp))
                Txt(label, 17, FontWeight.SemiBold, if (on) Theme.safe else Theme.dim, Modifier.weight(1f))
                Ic(R.drawable.ic_expand_more, Theme.dim, 24.dp)
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt("${links.phones}", 88, FontWeight.Black, lineHeight = 96)
                Spacer(Modifier.width(14.dp))
                Txt(if (links.phones == 1) "phone\nin range" else "phones\nin range", 26, FontWeight.Bold, Theme.dim, lineHeight = 28)
            }
            if (links.phones > 0) Txt("Your messages hop from phone to phone.", 15, color = Theme.dim)
            if (links.relays > 0) Txt("Online · your messages also travel over the internet (${links.relays} ${if (links.relays == 1) "relay" else "relays"}).", 15, color = Theme.dim)
            if (links.radio) Txt("LoRa radio linked · short messages also reach radios kilometers away.", 15, color = Theme.dim)
            if (!links.any) Txt(if (s.permissionsMissing) "Your messages wait on this phone. DarkProof can look for phones once you allow Nearby devices."
                else "Your messages wait on this phone and go out as soon as a phone is in range. DarkProof keeps looking, also when the app is closed.", 15, color = Theme.dim)
            if (details) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Theme.line))
                linkLines().forEach { Txt(it, 14, color = Theme.dim) }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ActionTile("I'm safe", R.drawable.ic_verified_user, Theme.safe, true, Modifier.weight(1f)) { checkIn(a, s, CheckIn.SAFE) }
            ActionTile("Need help", R.drawable.ic_sos, Theme.help, true, Modifier.weight(1f)) { s.helpGroup = null; s.askHelp = true }
            ActionTile("Invite", R.drawable.ic_qr_code_2, Theme.text, false, Modifier.weight(1f)) { open(Sheet.Invite) }
            ActionTile("Connect", R.drawable.ic_settings_input_antenna, Theme.text, false, Modifier.weight(1f)) { open(Sheet.Radio) }
        }
        mine?.let { m -> Txt("Your last check-in: ${if (CheckIn.of(m.text) == CheckIn.HELP) "need help" else "safe"}, ${ago(m.ts)}.", 15, color = Theme.dim) }
        hours?.let { h -> batteryPercent(a)?.let { p -> Txt("Battery $p% · about $h h left at this rate.", 15, color = if (h <= 3) Theme.help else Theme.dim) } }
        ReadyCard(s, a, people.isNotEmpty())
        if (!links.any) Card {
            Txt("No one in range yet", 20, FontWeight.Bold)
            Tip(R.drawable.ic_wifi, "Open DarkProof on both phones and stay within about 10–50 m. Walls cut the range: try outside or by a window.")
            Tip(R.drawable.ic_group, "Farther away? Messages hop through any phone with DarkProof in between. For kilometers, pair a LoRa radio.")
        }
        SectionTitle("Your people", if (people.size > 3) "See all" else null) { s.tab = 3 }
        if (people.isEmpty()) Card {
            Txt("No one from ${g.name} yet", 18, FontWeight.Bold)
            Txt("Invite friends with a QR code. People show up here once they write or check in.", 15, color = Theme.dim)
            GhostButton("Invite") { open(Sheet.Invite) }
        } else Card(padding = 12.dp) {
            people.take(3).forEach { p -> PersonRow(p, { open(Sheet.Person(p.id)) }) { sp -> open(Sheet.Find(p.name, sp, p.spotTs)) } }
        }
    }
}

/** Whether someone in the saved group [code] needs help (their latest check-in, or a report). */
fun groupNeedsHelp(all: List<Message>, code: String) =
    Person.all(all.filter { it.group == code }, MeshEngine.deviceId).any { it.checkIn == CheckIn.HELP }

/** Each way messages travel, in plain words (Home details, Connections). */
fun linkLines(): List<String> = listOfNotNull(
    "Nearby: " + MeshEngine.transportStatus.replaceFirstChar { it.lowercase() },
    MeshEngine.ble?.statusLine() ?: "Bluetooth: not started",
    MeshEngine.wifi?.links?.statusLine() ?: "Wi-Fi network: off",
    MeshEngine.nostr?.statusLine() ?: "Internet: off",
    MeshEngine.lora?.takeIf { it.paired || it.connected }?.status,
    MeshEngine.meshcore?.takeIf { it.paired || it.connected }?.status,
)

/** Missing permissions and phone switches that stop DarkProof from working well, each with the button that fixes it. */
@Composable
private fun PhoneProblems(s: AppState, a: MainActivity) {
    if (s.permissionsMissing) Card {
        Txt("Nearby devices permission needed", 18, FontWeight.Bold, Theme.help)
        Txt("Without it DarkProof can't connect to phones nearby. Your messages are kept and go out once you allow it.", 15, color = Theme.dim)
        GhostButton("Allow") { a.askNearby() }
    } else if (s.bluetoothOff) Card {
        Txt("Bluetooth is off", 18, FontWeight.Bold, Theme.help)
        Txt("Phones nearby can't reach you. Turn it on to send and receive without internet.", 15, color = Theme.dim)
        GhostButton("Turn on Bluetooth") { a.turnOnBluetooth() }
    } else if (s.locationMissing) Card {
        Txt("Location isn't allowed", 18, FontWeight.Bold)
        Txt("Android uses it to find nearby phones over Bluetooth and Wi-Fi, so DarkProof may find fewer phones. Check-ins and places go out without your position.", 15, color = Theme.dim)
        GhostButton("Allow location") { a.askLocation() }
    } else if (s.locationOff && (android.os.Build.VERSION.SDK_INT < 31 || s.shareLocation)) Card {
        Txt("Location is off", 18, FontWeight.Bold)
        Txt(if (android.os.Build.VERSION.SDK_INT < 31) "This phone needs it on to find other phones. Turn it on in the phone's settings."
            else "Your check-ins go out without your position until you turn it on.", 15, color = Theme.dim)
        GhostButton("Turn on location") { a.openLocationSettings() }
    }
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
private fun InviteSheet(g: SavedGroup, a: MainActivity, close: () -> Unit) {
    val link = remember(g) { inviteLink(g) }
    val qr = remember(link) { qrBitmap(link).asImageBitmap() }
    var showCode by rememberSaveable { mutableStateOf(false) }
    SheetPage("Invite", close) {
        Txt("Invite to ${g.name}", 20, FontWeight.Bold)
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Image(qr, "Invite QR code", Modifier.size(260.dp).clip(RoundedCornerShape(24.dp)).background(Color.White).padding(14.dp))
        }
        Txt("Your friend points their phone camera at this code, or scans it in DarkProof.", 15, color = Theme.dim)
        PrimaryButton("Share invite link", icon = R.drawable.ic_share) {
            a.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, "Join my group ${g.name} on DarkProof: $link\n\nDon't have DarkProof? https://darkproof.app"), "Invite"))
        }
        FingerprintCard(g.code, "Check together", "Once your friend has joined, compare these with their phone. The same emoji mean the same group.")
        Kicker("Or tell them the code")
        if (!showCode) GhostButton("Show code") { showCode = true }
        else Card {
            Txt(g.code, 22, FontWeight.Bold)
            GhostButton("Copy code") { copyText(a, "Group code", g.code, sensitive = true, done = "Code copied") }
        }
        Kicker("Friend doesn't have DarkProof?")
        SecondaryButton("Share the app", icon = R.drawable.ic_share) { ApkShare.share(a) }
        Txt("Sends DarkProof to an Android phone nearby with Quick Share or Bluetooth, no internet needed.", 14, color = Theme.dim)
    }
}

@Composable
private fun GroupsSheet(g: SavedGroup, a: MainActivity, all: List<Message>, invite: () -> Unit, add: () -> Unit, close: () -> Unit) {
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
                    val unread = remember(all, o) { ReadMarks.unread(a, all, o.code) }
                    val help = remember(all, o) { groupNeedsHelp(all, o.code) }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Txt(o.name, 17, FontWeight.SemiBold, modifier = Modifier.weight(1f), maxLines = 1)
                        if (help) Chip("Needs help", Theme.help)
                        if (unread > 0) Chip("$unread new", Theme.text)
                        GhostButton("Switch") { a.switchTo(o); close() }
                    }
                }
            }
            Txt("Switching shows the other group's messages. You still get alerts from every group, and their messages stay on the phone.", 14, color = Theme.dim)
        }
        SecondaryButton("Join or start another group", icon = R.drawable.ic_add) { add() }
    }
}

@Composable
private fun SettingsSheet(s: AppState, a: MainActivity, add: () -> Unit, close: () -> Unit) {
    var name by rememberSaveable { mutableStateOf(s.name) }
    val tick = s.tick
    val g = s.group
    Perms.version // re-read permissions when they change
    SheetPage("Settings", close) {
        InputField("Your name", name, { name = it.take(40) }, keyboard = KeyboardOptions(KeyboardCapitalization.Words))
        if (name.trim() != s.name && name.isNotBlank()) GhostButton("Save") {
            s.name = name.trim(); a.getSharedPreferences("mesh", 0).edit().putString("name", s.name).apply(); MeshEngine.rename(s.name)
        }
        Card {
            SwitchRow("Share my location in check-ins", s.shareLocation, { a.shareLocation(it) },
                "When you tap I'm safe or I need help, your group also sees where you are, and can find you with a compass. It works without internet. Only your group can read it.")
            if (s.shareLocation && !Locator.allowed(a)) {
                Txt("Location isn't allowed for DarkProof, so check-ins go out without it.", 14, color = Theme.help)
                GhostButton("Allow location") { a.askLocation() }
            }
        }
        Card {
            Txt("Notifications", 16, FontWeight.SemiBold)
            Txt("Alerts when any of your groups writes or checks in, also when DarkProof is closed. While it is open, someone needing help or asking if you're safe shows at the top of the screen. Made on your phone: no internet needed.",
                14, color = Theme.dim)
            if (s.notificationsOff) GhostButton("Turn on notifications") { a.askNotifications() }
        }
        if (g != null) FingerprintCard(g.code, "Check your group", "Compare these with the other phone. The same emoji mean you're in the same group; different ones mean a wrong code.")
        Card {
            Txt("Practice", 16, FontWeight.SemiBold)
            Txt("Walk through asking for help, step by step. Nothing is sent.", 14, color = Theme.dim)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GhostButton("Practice now") { s.sheet = Sheet.Practice }
                if (Ready.done(a, Ready.HIDDEN)) GhostButton("Show “Get ready”") { a.getSharedPreferences("ready", 0).edit().remove(Ready.HIDDEN).apply(); s.tick++; close() }
            }
        }
        Card {
            Txt("Share DarkProof", 16, FontWeight.SemiBold)
            Txt("Give the app to another Android phone without internet, with Quick Share or Bluetooth.", 14, color = Theme.dim)
            GhostButton("Share the app") { ApkShare.share(a) }
        }
        Card {
            Txt("Wi-Fi board", 16, FontWeight.SemiBold)
            Txt("People without the app join this phone's Wi-Fi network, then read and post Everyone messages in their browser. Android users can also download DarkProof there.", 14, color = Theme.dim)
            key(tick) {
                GhostButton(if (WifiBoard.running) "Stop the Wi-Fi board" else "Start the Wi-Fi board") {
                    if (WifiBoard.running) WifiBoard.stop() else WifiBoard.start(a) { MeshEngine.notifyUi() }
                    s.tick++
                }
                WifiBoard.status.takeIf { it != "Off" }?.let { Txt(it, 14, color = if (WifiBoard.running) Theme.safe else Theme.help) }
            }
        }
        SecondaryButton("Join or start another group", icon = R.drawable.ic_add) { add() }
        key(s.moderated) {
            val blocked = Moderation.blocked(a)
            if (blocked.isNotEmpty()) Card {
                Txt("Blocked people", 16, FontWeight.SemiBold)
                Txt("Their messages, places and check-ins are hidden on this phone.", 14, color = Theme.dim)
                blocked.forEach { (id, n) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Txt(n, 16, modifier = Modifier.weight(1f), maxLines = 1)
                        GhostButton("Unblock") { Moderation.unblock(a, id); s.moderated++ }
                    }
                }
            }
        }
        Card {
            Txt("Help and safety", 16, FontWeight.SemiBold)
            Txt("In Everyone, hold a message to report it or block its sender. To report abuse or a problem, write to ${Contact.EMAIL}.", 14, color = Theme.dim)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GhostButton("Email us") { Contact.open(a, Contact.MAIL) }
                GhostButton("Privacy policy") { Contact.open(a, Contact.PRIVACY) }
            }
        }
    }
}

/** Every way messages travel, in one place: what is linked now, switches, pairing, and other apps. */
@Composable
private fun ConnectionsSheet(s: AppState, a: MainActivity, close: () -> Unit) {
    val tick = s.tick
    var clock by remember { mutableIntStateOf(0) } // Tor's "can't connect" appears after 2 minutes without other news
    LaunchedEffect(Unit) { while (true) { kotlinx.coroutines.delay(5_000); clock++ } }
    SheetPage("Connections", close) {
        Txt("The ways your messages travel. All but Internet keep working in a blackout.", 15, color = Theme.dim)
        if (s.permissionsMissing) Card {
            Txt("Nearby devices permission needed", 18, FontWeight.Bold, Theme.help)
            Txt("Without it DarkProof can't use Bluetooth or Wi-Fi Direct, so it can't find phones or radios. Wi-Fi networks and the internet still work.", 15, color = Theme.dim)
            GhostButton("Allow") { a.askNearby() }
        }
        // Read here so the cards below are drawn again with fresh link states; no key(), which would reset their searches.
        tick; clock
        run {
            val phones = phonesInRange()
            Card {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Txt("Nearby phones", 18, FontWeight.Bold, modifier = Modifier.weight(1f))
                    Chip(if (phones > 0) "$phones linked" else if (s.permissionsMissing || s.bluetoothOff) "Off" else "Searching", if (phones > 0) Theme.safe else Theme.dim)
                }
                Txt("Phones with DarkProof within about 10–50 m connect by themselves, over Bluetooth and Wi-Fi Direct.", 15, color = Theme.dim)
                if (!s.permissionsMissing) {
                    Txt("Nearby: ${MeshEngine.transportStatus.replaceFirstChar { it.lowercase() }} · ${MeshEngine.ble?.statusLine() ?: "Bluetooth: not started"}", 14, color = Theme.dim)
                    if (s.bluetoothOff) GhostButton("Turn on Bluetooth") { a.turnOnBluetooth() }
                }
            }
            WifiCard()
            InternetCard()
            Card {
                SwitchRow("Battery saver", MeshEngine.batterySaver(a), { MeshEngine.setBatterySaver(it); s.tick++ },
                    "Searches for phones less often, so the battery lasts longer. Linked phones stay linked; new ones can take up to 2 minutes to show up.")
            }
            val blocked = if (s.permissionsMissing) "Allow Nearby devices first: DarkProof needs it to use Bluetooth." else if (s.bluetoothOff) "Turn on Bluetooth first." else null
            RadioCard("LoRa radio · Meshtastic",
                "Reaches other radios kilometers away: about 2–10 km in a city, more from high places. Short messages only. Use a Meshtastic radio with the region set (EU_868 in Europe).",
                MeshEngine.lora?.status?.removePrefix("LoRa: "), MeshEngine.lora?.connected == true, MeshEngine.lora?.paired == true, blocked,
                MeshEngine.lora?.let { l -> { found: (String, String) -> Unit -> l.scan(found) } }, { MeshEngine.lora?.select(it) }, { MeshEngine.lora?.forget() })
            RadioCard("LoRa radio · MeshCore",
                "The same kind of radio with MeshCore firmware, version 1.15 or newer. DarkProof adds a #darkproof channel to the radio and every MeshCore repeater passes it on. Short messages only. The radio's PIN is often 123456 or shown on its screen.",
                MeshEngine.meshcore?.status?.removePrefix("MeshCore: "), MeshEngine.meshcore?.connected == true, MeshEngine.meshcore?.paired == true, blocked,
                MeshEngine.meshcore?.let { l -> { found: (String, String) -> Unit -> l.scan(found) } }, { MeshEngine.meshcore?.select(it) }, { MeshEngine.meshcore?.forget() })
        }
        Card {
            Txt("Send via another app", 18, FontWeight.Bold)
            Txt("For satellite messengers such as Garmin inReach or Zoleo, text messages once the network is back, or any app. It includes your battery and, if location is on, where you are. It leaves DarkProof: that app decides who can read it.", 15, color = Theme.dim)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GhostButton("Share “I'm safe”") { shareStatus(a, s, CheckIn.SAFE) }
                GhostButton("Share “I need help”") { shareStatus(a, s, CheckIn.HELP) }
            }
        }
    }
}

/** Internet relays: on/off, how many answer, and "Connect through Tor". */
@Composable
private fun InternetCard() {
    val ctx = LocalContext.current
    val n = MeshEngine.nostr
    Card {
        SwitchRow("Internet", n != null, { MeshEngine.setInternet(it) },
            "While there is Wi-Fi or mobile data, messages also travel through free public relays (Nostr), so friends far away get them and this phone passes on its neighbours' messages. In a blackout the other ways keep working. Group messages stay encrypted; relays see your internet address unless you use Tor.")
        if (n != null) {
            when {
                n.torStuck -> Txt("Tor can't connect right now. Nearby links still work. DarkProof keeps trying.", 15, FontWeight.SemiBold, Theme.help)
                n.throughTor == false -> Txt("Starting Tor… the first time can take a minute", 15, FontWeight.SemiBold, Theme.text)
                else -> Txt(if (n.connected > 0) "Connected to ${n.connected} of ${n.total} relays" + (if (n.throughTor == true) " through Tor" else "")
                            else "No internet right now: the other ways keep working",
                    15, FontWeight.SemiBold, if (n.connected > 0) Theme.safe else Theme.dim)
            }
            SwitchRow("Connect through Tor", Tor.enabled(ctx), { MeshEngine.setTor(it) },
                "Relays then can't see your internet address. Tor runs inside DarkProof: nothing else to install. Slower and uses more battery. Nothing goes to the relays until DarkProof has checked that Tor is working.")
        }
    }
}

/** Links over Wi-Fi networks: on/off, what is linked, this phone's address, and an address to dial by hand. */
@Composable
private fun WifiCard() {
    val ctx = LocalContext.current
    val wifi = MeshEngine.wifi
    var address by rememberSaveable { mutableStateOf(wifi?.links?.manual ?: "") }
    Card {
        SwitchRow("Wi-Fi network", wifi != null, { MeshEngine.setWifi(it) },
            "Phones on the same Wi-Fi find each other: a router with no internet, a phone hotspot, a neighbourhood network or a long-range rooftop link.")
        if (wifi != null) {
            val n = wifi.links.linkCount()
            Txt(if (n > 0) "$n phone${if (n == 1) "" else "s"} linked over Wi-Fi" else "Looking on this network", 15, FontWeight.SemiBold, if (n > 0) Theme.safe else Theme.dim)
            localAddress()?.let { ip -> if (wifi.links.port > 0) Txt("This phone: $ip:${wifi.links.port}", 14, color = Theme.dim) }
            InputField("Connect to an address", address, { address = it.trim() }, "192.168.1.20:7777")
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                GhostButton("Connect") {
                    val host = address.substringBeforeLast(':', ""); val port = address.substringAfterLast(':').toIntOrNull()
                    if (host.isEmpty() || port == null || port !in 1..65535) Toast.makeText(ctx, "Type it as address:port, for example 192.168.1.20:7777", Toast.LENGTH_LONG).show()
                    else wifi.links.connectManually(host, port)
                }
                if (wifi.links.manual != null) GhostButton("Stop") { wifi.links.stopManual() }
            }
            Txt("Only needed when phones don't find each other on their own, for example on networks that block it.", 14, color = Theme.dim)
            wifi.links.note.takeIf { it.isNotEmpty() }?.let { Txt(it.replaceFirstChar { c -> c.uppercase() }, 14, color = Theme.dim) }
        }
    }
}

/**
 * Search, pair and forget for one kind of LoRa radio. [scan] is null until the radio link is ready; [blocked] says why
 * it can't search (permission, Bluetooth off).
 */
@Composable
private fun RadioCard(title: String, about: String, status: String?, linked: Boolean, paired: Boolean, blocked: String?,
                      scan: ((found: (String, String) -> Unit) -> Unit)?, select: (String) -> Unit, forget: () -> Unit) {
    val found = remember { mutableStateListOf<Pair<String, String>>() }
    var scanning by remember { mutableStateOf(false) }
    var searched by remember { mutableStateOf(false) }
    LaunchedEffect(scanning) { if (scanning) { kotlinx.coroutines.delay(15_500); scanning = false; searched = true } } // radios scan for 15 s
    val ctx = LocalContext.current
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Txt(title, 18, FontWeight.Bold, modifier = Modifier.weight(1f))
            Chip(if (linked) "Linked" else if (paired) "Paired" else "Not linked", if (linked) Theme.safe else Theme.dim)
        }
        Txt(about, 15, color = Theme.dim)
        status?.takeIf { it != "no radio" }?.let { Txt(it.replaceFirstChar { c -> c.uppercase() }, 14, FontWeight.SemiBold, if (linked) Theme.safe else Theme.text) }
        if (blocked != null) { Txt(blocked, 14, color = Theme.dim); return@Card }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            GhostButton(if (scanning) "Searching…" else "Search for radios", enabled = !scanning) {
                if (scan == null) { Toast.makeText(ctx, "DarkProof is still starting. Try again in a moment.", Toast.LENGTH_LONG).show(); return@GhostButton }
                scanning = true; searched = false; found.clear()
                scan { addr, nm -> if (scanning && found.none { it.first == addr }) found += addr to nm }
            }
            if (paired || linked) GhostButton("Forget radio") { forget(); found.clear(); searched = false }
        }
        if (scanning && found.isEmpty()) Txt("Looking for radios nearby… Turn the radio on and keep it next to the phone.", 14, color = Theme.dim)
        if (searched && found.isEmpty()) Txt("No radios found. Turn the radio on, keep it next to the phone and search again.", 14, color = Theme.dim)
        found.forEach { (addr, nm) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt(nm, 16, FontWeight.SemiBold, modifier = Modifier.weight(1f))
                GhostButton("Connect") {
                    select(addr); scanning = false; searched = false; found.clear()
                    Toast.makeText(ctx, "Connecting: if asked, enter the PIN shown on the radio", Toast.LENGTH_LONG).show()
                }
            }
        }
    }
}

/** This phone's address on its Wi-Fi network, for people who type it on another phone. */
private fun localAddress(): String? = runCatching {
    java.net.NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
        .flatMap { it.inetAddresses.toList() }.firstOrNull { it is java.net.Inet4Address && it.isSiteLocalAddress }?.hostAddress
}.getOrNull()

/** Shares a check-in as plain text through another app (StatusShare), with battery and position when available. */
fun shareStatus(a: MainActivity, s: AppState, c: CheckIn) {
    val battery = batteryPercent(a)
    fun go(spot: Spot?) = a.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain")
        .putExtra(Intent.EXTRA_TEXT, StatusShare.text(c, s.name, battery, spot)), "Send via"))
    val last = Locator.lastKnown(a)
    when {
        last != null || !Locator.allowed(a) -> go(last)
        else -> { Toast.makeText(a, "Finding your position…", Toast.LENGTH_SHORT).show(); Locator.fix(a) { go(it) } }
    }
}

/** Avatar with a colored ring: green safe, red help. A report about someone has a faded ring: it isn't their own check-in. */
@Composable fun Avatar(name: String, check: CheckIn?, size: Int = 56, report: Boolean = false) {
    val ring = when (check) { CheckIn.SAFE -> Theme.safe; CheckIn.HELP -> Theme.help; null -> Theme.line }.let { if (report) it.copy(alpha = 0.45f) else it }
    Box(Modifier.size(size.dp).border(if (report) 2.dp else 3.dp, ring, CircleShape).padding(5.dp).background(Theme.tile, CircleShape), contentAlignment = Alignment.Center) {
        Txt(name.trim().take(1).uppercase().ifEmpty { "?" }, (size * 0.4).toInt(), FontWeight.Bold)
    }
}

/** "Safe · 5 min ago", or for a report "Safe · reported by Anna · 5 min ago" (never as the person's own check-in). */
fun statusLine(p: Person): String? {
    val by = if (p.isReport) " · reported by " + (if (p.reporterId == MeshEngine.deviceId) "you" else p.reportedBy) else ""
    return when (p.checkIn) {
        CheckIn.SAFE -> "Safe$by · ${ago(p.checkInTs)}"
        CheckIn.HELP -> "Needs help$by · ${ago(p.checkInTs)}"
        null -> null
    }
}

/** What someone needs and how many people they speak for: "Injured · Need water · 3 people". */
fun needsLine(p: Person): String? =
    (p.needs.sortedBy { it.ordinal }.map { it.label } + listOfNotNull(p.people?.takeIf { it > 1 }?.let { "$it people" })).joinToString(" · ").ifEmpty { null }

@Composable
fun PersonRow(p: Person, tap: () -> Unit, find: (Spot) -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(18.dp)).clickable(role = Role.Button, onClick = tap).padding(vertical = 6.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Avatar(p.name, p.checkIn, report = p.isReport)
        Spacer(Modifier.width(14.dp))
        Column(Modifier.weight(1f)) {
            Txt(p.name, 18, FontWeight.SemiBold, maxLines = 1)
            val line = statusLine(p)
            when (p.checkIn) {
                CheckIn.SAFE -> Txt(line!!, 15, FontWeight.Medium, Theme.safe, maxLines = 2)
                CheckIn.HELP -> Txt(line!!, 15, FontWeight.Medium, Theme.help, maxLines = 2)
                null -> Txt("Last seen ${ago(p.lastTs)}", 15, color = Theme.dim)
            }
            needsLine(p)?.let { Txt(it, 14, color = if (p.checkIn == CheckIn.HELP) Theme.text else Theme.dim, maxLines = 2) }
        }
        p.battery?.let { BatteryLabel(it); Spacer(Modifier.width(12.dp)) }
        p.spot?.let { sp -> RoundIcon(R.drawable.ic_navigation, 46.dp, desc = "Find ${p.name}") { find(sp) } }
    }
}

/** Monospaced text helper for codes. */
val Mono = FontFamily.Monospace
