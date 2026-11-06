package it.blackout.mesh

import android.widget.Toast
import androidx.annotation.DrawableRes
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.ConcurrentHashMap

// Asking for help, practising it, checking in for someone else, one person's page, "Get ready", and the group check.

/** Needs as a saveable text ("injured,water"), so a half-filled form survives. */
private fun needsOf(s: String) = Need.parse(s)
private fun needsText(n: Set<Need>) = Need.text(n).replace(" ", "")

/** What is needed (toggles) and how many people, for "I need help" and reports about others. */
@Composable
fun NeedsForm(needs: Set<Need>, setNeeds: (Set<Need>) -> Unit, people: Int, setPeople: (Int) -> Unit, showNeeds: Boolean = true,
              peopleLabel: String = "How many people, you included?", needsLabel: String? = "What do you need?") {
    if (showNeeds) {
        needsLabel?.let { Kicker(it) }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Need.entries.chunked(2).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    row.forEach { n -> ToggleTile(n.label, n in needs, Modifier.weight(1f)) { setNeeds(if (n in needs) needs - n else needs + n) } }
                }
            }
        }
    }
    Kicker(peopleLabel)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(18.dp)) {
        RoundIcon(R.drawable.ic_remove, 48.dp, desc = "One less") { setPeople((people - 1).coerceAtLeast(1)) }
        Txt("$people", 30, FontWeight.Black, modifier = Modifier.widthIn(min = 44.dp).semantics { contentDescription = "$people people" })
        RoundIcon(R.drawable.ic_add, 48.dp, desc = "One more") { setPeople((people + 1).coerceAtMost(99)) }
    }
}

@Composable
fun ToggleTile(label: String, on: Boolean, modifier: Modifier = Modifier, tap: () -> Unit) =
    Row(modifier.heightIn(min = 52.dp).clip(RoundedCornerShape(20.dp)).background(if (on) Color.White else Theme.card)
        .toggleable(on, role = Role.Checkbox) { tap() }.padding(horizontal = 14.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        if (on) { Ic(R.drawable.ic_check_circle, Color.Black, 20.dp); Spacer(Modifier.width(8.dp)) }
        Txt(label, 16, FontWeight.SemiBold, if (on) Color.Black else Theme.text, maxLines = 1)
    }

/**
 * "I need help": one tap on the red button sends it to [group]; what is needed and how many people are optional and go
 * in the same message (one check-in, like the iPhone, so the group doesn't get two help cards).
 */
@Composable
fun HelpDetailsSheet(s: AppState, a: MainActivity, group: String?, close: () -> Unit) {
    var needs by rememberSaveable { mutableStateOf("") }
    var people by rememberSaveable { mutableIntStateOf(1) }
    val to = Groups.find(a, group)?.name ?: s.group?.name ?: "your group"
    val links = remember(s.tick) { Links.now() }
    val where = if (s.shareLocation) ", with where you are" else ""
    fun sent() { close(); s.everyone = false; s.tab = 1 }
    SheetPage("I need help", close) {
        Txt(if (links.any) "Goes to $to now and hops from phone to phone$where."
            else "No phone or internet is in reach right now. It waits on this phone$where and goes out as soon as one is.", 16, color = Theme.dim)
        DangerButton("Send “I need help”", icon = R.drawable.ic_sos) {
            if (checkIn(a, s, CheckIn.HELP, needsOf(needs), people.takeIf { it > 1 }, group)) sent()
        }
        NeedsForm(needsOf(needs), { needs = needsText(it) }, people, { people = it }, needsLabel = "Optional: what do you need?")
        SecondaryButton("Cancel") { close() }
        Txt("Then write in Chat where you are and what happened.", 14, color = Theme.dim)
    }
}

/** A walk through asking for help, clearly marked: nothing is sent. */
@Composable
fun PracticeSheet(a: MainActivity, close: () -> Unit) {
    var step by rememberSaveable { mutableIntStateOf(0) }
    var needs by rememberSaveable { mutableStateOf("") }
    var people by rememberSaveable { mutableIntStateOf(1) }
    SheetPage("Practice", close) {
        Row(Modifier.fillMaxWidth().clip(CircleShape).background(Theme.help.copy(alpha = 0.16f)).padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Ic(R.drawable.ic_schedule, Theme.help, 20.dp); Spacer(Modifier.width(10.dp))
            Txt("Practice · nothing is sent · step ${step + 1} of 4", 15, FontWeight.Bold, Theme.help)
        }
        when (step) {
            0 -> {
                Txt("When you need help, tap “Need help” on Home or “I need help” in People. Try it here:", 17)
                Column(Modifier.fillMaxWidth().height(150.dp).clip(vaultShape(34.dp, 40.dp, 8.dp)).background(Theme.help)
                    .clickable(role = Role.Button) { step = 1 }.padding(20.dp), verticalArrangement = Arrangement.Bottom) {
                    Ic(R.drawable.ic_sos, Color.White, 48.dp); Spacer(Modifier.height(8.dp))
                    Txt("I need help", 22, FontWeight.Black, Color.White)
                }
            }
            1 -> {
                Txt("DarkProof asks first, so it is never sent by mistake:", 17)
                Card {
                    Txt("Send “I need help”?", 20, FontWeight.Bold)
                    Txt("It goes out now and hops from phone to phone to your group. Next you can say what you need.", 15, color = Theme.dim)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        GhostButton("Cancel") { step = 0 }
                        CapsuleChoice("Send", Theme.help, Color.White, Modifier.weight(1f)) { step = 2 }
                    }
                }
            }
            2 -> {
                Txt("It's out. Now say what you need, with a few taps:", 17)
                NeedsForm(needsOf(needs), { needs = needsText(it) }, people, { people = it })
                PrimaryButton("Send details") { step = 3 }
                SecondaryButton("Skip") { step = 3 }
            }
            else -> {
                Txt("Done. In a real emergency your group would now see:", 17)
                val n = needsOf(needs)
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(24.dp)).background(Theme.help.copy(alpha = 0.12f)).padding(18.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Ic(R.drawable.ic_sos, Theme.help, 26.dp); Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Txt("${a.state.name.ifBlank { "You" }} needs help", 18, FontWeight.SemiBold)
                        val extra = (n.sortedBy { it.ordinal }.map { it.label } + listOfNotNull(people.takeIf { it > 1 }?.let { "$it people" })).joinToString(" · ")
                        if (extra.isNotEmpty()) Txt(extra, 15, color = Theme.text)
                    }
                    batteryPercent(a)?.let { BatteryLabel(it) }
                }
                Tip("Then write in Chat where you are and what happened.")
                Tip("Phones nearby pass it on, with no internet. DarkProof keeps doing it when the app is closed.")
                Tip("Someone in your group can then find you with the compass, if you share your location (Settings).")
                PrimaryButton("Done") { Ready.mark(a, Ready.PRACTICE); a.state.tick++; close() }
            }
        }
    }
}

@Composable private fun Tip(text: String) = Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
    Ic(R.drawable.ic_check_circle, Theme.dim, 20.dp); Txt(text, 15, color = Theme.dim)
}

/** A check-in for someone without a phone or signal (spec "Reports about others"): shown as reported by me. */
@Composable
fun VouchSheet(s: AppState, a: MainActivity, close: () -> Unit) {
    var name by rememberSaveable { mutableStateOf("") }
    var help by rememberSaveable { mutableStateOf(false) }
    var needs by rememberSaveable { mutableStateOf("") }
    var people by rememberSaveable { mutableIntStateOf(1) }
    var withSpot by rememberSaveable { mutableStateOf(false) }
    var sending by remember { mutableStateOf(false) }
    var cancel by remember { mutableStateOf<(() -> Unit)?>(null) }
    DisposableEffect(Unit) { onDispose { cancel?.invoke() } } // closed while finding the position: nothing is sent
    val g = s.group ?: return
    Perms.version
    SheetPage("Check in for someone", close) {
        Txt("For someone without a phone or signal, for example a neighbour you found at the shelter. ${g.name} sees it as reported by you.", 15, color = Theme.dim)
        InputField("Their name", name, { name = it.take(Vouch.MAX_NAME) }, "Grandma Rosa", keyboard = KeyboardOptions(KeyboardCapitalization.Words))
        PillSwitch("Is safe", "Needs help", help) { help = it }
        NeedsForm(needsOf(needs), { needs = needsText(it) }, people, { people = it }, showNeeds = help,
            peopleLabel = "How many people, them included?", needsLabel = "What do they need?")
        Card { SwitchRow("Add my position", withSpot, { withSpot = it }, "Only if you are with them right now, so people can find them.") }
        if (withSpot && !Locator.allowed(a)) GhostButton("Allow location") { a.askLocation() }
        PrimaryButton(if (sending) "Finding your position…" else "Send to ${g.name}", enabled = name.isNotBlank() && !sending) {
            if (!meshReady(a)) return@PrimaryButton
            fun go(sp: Spot?) {
                val v = Vouch(name, if (help) CheckIn.HELP else CheckIn.SAFE, if (help) needsOf(needs) else emptySet(), people.takeIf { it > 1 }, sp)
                Thread { MeshEngine.send(v.text) }.start()
                val pos = if (withSpot && sp == null) " without a position: no GPS fix yet" else ""
                Toast.makeText(a, if (Links.now().any) "Sent to ${g.name}$pos" else "Saved$pos. It goes out when a phone or the internet is in reach.", Toast.LENGTH_LONG).show()
                close()
            }
            if (withSpot && Locator.allowed(a)) { sending = true; cancel = Locator.fix(a) { go(it) } } else go(null)
        }
    }
}

/** One person: status, needs, battery, where they were (with Plus Code), and "Find" / "Ask if they're safe". */
@Composable
fun PersonSheet(s: AppState, a: MainActivity, messages: List<Message>, id: String, close: () -> Unit) {
    val p = remember(messages, id) { Person.all(messages, MeshEngine.deviceId).firstOrNull { it.id == id } }
    var ask by remember { mutableStateOf(false) }
    if (p == null) { SheetPage("Person", close) { Txt("No news from this person on this phone any more.", 16, color = Theme.dim) }; return }
    val me = remember { Locator.lastKnown(a) }
    SheetPage(p.name, close) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Avatar(p.name, p.checkIn, 72, report = p.isReport)
            Spacer(Modifier.width(16.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Txt(statusLine(p) ?: "No check-in yet", 17, FontWeight.SemiBold,
                    when (p.checkIn) { CheckIn.SAFE -> Theme.safe; CheckIn.HELP -> Theme.help; null -> Theme.dim })
                needsLine(p)?.let { Txt(it, 16) }
            }
        }
        if (p.isReport) Txt("This isn't ${p.name}'s own check-in: ${if (p.reporterId == MeshEngine.deviceId) "you" else p.reportedBy} sent it for them.", 15, color = Theme.dim)
        Card {
            Fact("Last heard", ago(p.lastTs))
            p.battery?.let { Fact("Battery", "$it%") }
            p.spot?.let { sp ->
                Fact("Position", if (me != null) "${Geo.meters(Geo.distance(me, sp))} ${Geo.compassWord(Geo.bearing(me, sp)).lowercase()} of you, ${ago(p.spotTs)}" else "Shared ${ago(p.spotTs)}")
                PlusCodeRow(sp)
            }
        }
        p.spot?.let { sp -> PrimaryButton("Find ${p.name}", icon = R.drawable.ic_navigation) { s.sheet = Sheet.Find(p.name, sp, p.spotTs) } }
        if (!p.isReport) SecondaryButton("Ask if ${p.name} is safe", icon = R.drawable.ic_notifications) { ask = true }
    }
    if (ask) Confirm("Ask ${p.name}?", "${p.name} gets “${AreYouSafe(p.name).text.removePrefix("❓ ")}” with one-tap answers. The whole group sees the question.", "Ask",
        onYes = { ask = false; if (meshReady(a)) { Thread { MeshEngine.send(AreYouSafe(p.name).text) }.start(); Toast.makeText(a, "Asked ${p.name}", Toast.LENGTH_SHORT).show() } },
        onNo = { ask = false })
}

@Composable private fun Fact(label: String, value: String) = Row {
    Txt(label, 15, color = Theme.dim, modifier = Modifier.width(110.dp)); Txt(value, 15, modifier = Modifier.weight(1f))
}

/** A position's Plus Code (map apps understand it, people can read it out), tap to copy. */
@Composable
fun PlusCodeRow(sp: Spot) {
    val ctx = LocalContext.current
    val code = sp.plusCode ?: return
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).clickable(role = Role.Button) { copyText(ctx, "Plus Code", code) }
        .semantics { contentDescription = "Plus Code $code. Tap to copy" }, verticalAlignment = Alignment.CenterVertically) {
        Txt("Plus Code", 15, color = Theme.dim, modifier = Modifier.width(110.dp))
        Txt(code, 16, FontWeight.SemiBold, modifier = Modifier.weight(1f))
        Ic(R.drawable.ic_content_copy, Theme.dim, 18.dp)
    }
}

/** A small "8FQFF57R+M2" label that copies itself, next to a position. */
@Composable
fun PlusCodeLabel(sp: Spot, size: Int = 14) {
    val ctx = LocalContext.current
    val code = sp.plusCode ?: return
    Txt(code, size, FontWeight.SemiBold, Theme.dim, Modifier.clip(CircleShape).clickable(role = Role.Button) { copyText(ctx, "Plus Code", code) }
        .semantics { contentDescription = "Plus Code $code. Tap to copy" }.padding(vertical = 4.dp))
}

/** Fingerprints take a key derivation each (a fraction of a second): worked out once per code, off the main thread. */
object FingerprintCache {
    private val known = ConcurrentHashMap<String, List<Int>>()
    fun get(code: String): List<Int> = known.getOrPut(code) { Fingerprint.forCode(code) }
}

/** The group's five emoji, to compare with another phone (spec "Group fingerprint"). */
@Composable
fun FingerprintCard(code: String, title: String, text: String) {
    val fp by produceState<List<Int>?>(null, code) { value = withContext(Dispatchers.Default) { FingerprintCache.get(code) } }
    Card {
        Txt(title, 16, FontWeight.SemiBold)
        Txt(text, 14, color = Theme.dim)
        val f = fp
        if (f == null) Txt("Working them out…", 15, color = Theme.dim)
        else {
            Txt(Fingerprint.emojiText(f), 34, lineHeight = 44, modifier = Modifier.semantics { contentDescription = Fingerprint.spoken(f) })
            Txt(Fingerprint.spoken(f), 15, color = Theme.dim)
        }
    }
}

/** One "Get ready" step. */
private class Step(val title: String, val sub: String, val done: Boolean, @DrawableRes val icon: Int, val go: () -> Unit)

/** What to do while there is still power and internet, with progress; each step opens the screen that does it. */
@Composable
fun ReadyCard(s: AppState, a: MainActivity, hasPeople: Boolean) {
    s.tick; Perms.version
    if (Ready.done(a, Ready.HIDDEN)) return
    val ai = LocalAi.catalog.firstOrNull()
    val steps = listOfNotNull(
        Step("Invite your people", "So you can reach each other", hasPeople || Ready.done(a, Ready.INVITE), R.drawable.ic_qr_code_2) { s.sheet = Sheet.Invite },
        Step("Save the map of your area", "It then works with no internet", OfflineMap.state is OfflineMap.State.Ready, R.drawable.ic_map) { s.placesMap = true; s.tab = 2 },
        Step("Add the “I'm safe” tile", "One tap from the top of the screen", Ready.done(a, Ready.TILE), R.drawable.ic_verified_user) { a.addTile() },
        Step("Try a practice run", "Ask for help without sending anything", Ready.done(a, Ready.PRACTICE), R.drawable.ic_sos) { s.sheet = Sheet.Practice },
        Step("Turn on notifications", "Know when someone needs help", !s.notificationsOff, R.drawable.ic_notifications) { a.askNotifications() },
        ai?.let { m -> Step("Download the offline AI", "Optional. Big: ${"%.1f".format(m.bytes / 1e9)} GB, use Wi-Fi.",
            LocalAi.states.values.any { it == LocalAi.State.Ready }, R.drawable.ic_auto_awesome) { s.tab = 4 } },
    )
    val done = steps.count { it.done }
    if (done == steps.size) return
    Card {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Txt("Get ready", 20, FontWeight.Bold)
                Txt("$done of ${steps.size} done, while there is power", 14, color = Theme.dim)
            }
            GhostButton("Hide") { Ready.mark(a, Ready.HIDDEN); s.tick++ }
        }
        Box(Modifier.fillMaxWidth().height(8.dp).clip(CircleShape).background(Theme.tile)) {
            Box(Modifier.fillMaxWidth((done.toFloat() / steps.size).coerceAtLeast(0.03f)).fillMaxHeight().background(Theme.safe, CircleShape))
        }
        Column {
            steps.forEach { st ->
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).clickable(enabled = !st.done, role = Role.Button, onClick = st.go)
                    .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(40.dp).background(if (st.done) Theme.safe.copy(alpha = 0.16f) else Theme.tile, CircleShape), contentAlignment = Alignment.Center) {
                        Ic(if (st.done) R.drawable.ic_check_circle else st.icon, if (st.done) Theme.safe else Theme.text, 20.dp)
                    }
                    Spacer(Modifier.width(14.dp))
                    Column(Modifier.weight(1f)) {
                        Txt(st.title, 16, FontWeight.SemiBold, if (st.done) Theme.dim else Theme.text)
                        if (!st.done) Txt(st.sub, 14, color = Theme.dim)
                    }
                    if (!st.done) Ic(R.drawable.ic_expand_more, Theme.dim, 22.dp, Modifier.rotate(-90f)) // ›
                }
            }
        }
    }
}
