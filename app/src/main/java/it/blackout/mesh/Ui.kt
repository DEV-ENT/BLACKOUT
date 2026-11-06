package it.blackout.mesh

import androidx.annotation.DrawableRes
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * DarkProof's look, the same as the iPhone (ios/Blackout/Theme.swift): white on pure black (black pixels are off on
 * OLED screens, which saves battery), soft charcoal cards, white capsule buttons. Color only means something:
 * green = safe or connected, red = help. The logo's outline is the one signature shape.
 */
object Theme {
    val bg = Color.Black
    val card = Color(0xFF131313)
    val tile = Color(0xFF212121)
    val line = Color(0xFF2B2B2B)
    val text = Color.White
    val dim = Color(0xFF949494)
    val faint = Color(0xFF888888) // at least 4.5:1 on black, cards and tiles: it still carries information
    val safe = Color(0xFF33D64A)
    val help = Color(0xFFFF453B)
}

/** The logo's silhouette: cut top-left corner, round right side, near-square bottom-left. */
fun vaultShape(cut: Dp = 42.dp, radius: Dp = 46.dp, small: Dp = 8.dp): Shape = object : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val c = with(density) { cut.toPx() }; val r = with(density) { radius.toPx() }; val s = with(density) { small.toPx() }
        val w = size.width; val h = size.height
        return Outline.Generic(Path().apply {
            moveTo(c, 0f)
            lineTo(w - r, 0f)
            arcTo(Rect(w - 2 * r, 0f, w, 2 * r), -90f, 90f, false)
            lineTo(w, h - r)
            arcTo(Rect(w - 2 * r, h - 2 * r, w, h), 0f, 90f, false)
            lineTo(s, h)
            arcTo(Rect(0f, h - 2 * s, 2 * s, h), 90f, 90f, false)
            lineTo(0f, c)
            close()
        })
    }
}

@Composable fun Ic(@DrawableRes id: Int, tint: Color = Theme.text, size: Dp = 22.dp, modifier: Modifier = Modifier) =
    Image(painterResource(id), null, modifier.size(size), colorFilter = ColorFilter.tint(tint))

@Composable fun Logo(size: Dp) =
    Image(painterResource(R.drawable.logo), "DarkProof", Modifier.size(size), colorFilter = ColorFilter.tint(Theme.text))

@Composable fun Txt(
    text: String, size: Int = 16, weight: FontWeight = FontWeight.Normal, color: Color = Theme.text,
    modifier: Modifier = Modifier, maxLines: Int = Int.MAX_VALUE, lineHeight: Int = 0,
) = Text(
    text, modifier, color = color, fontSize = size.sp, fontWeight = weight, maxLines = maxLines, overflow = TextOverflow.Ellipsis,
    lineHeight = if (lineHeight > 0) lineHeight.sp else (size * 1.3).sp,
)

/** Small section label above a field or group, in sentence case. */
@Composable fun Kicker(text: String, color: Color = Theme.dim) = Txt(text, 14, FontWeight.SemiBold, color)

/** Section title with an optional action on the right, e.g. "Your people · See all". */
@Composable fun SectionTitle(title: String, action: String? = null, tap: () -> Unit = {}) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Txt(title, 20, FontWeight.Bold, modifier = Modifier.weight(1f))
        if (action != null) Txt(action, 15, FontWeight.SemiBold, Theme.dim, Modifier.clickable(onClick = tap))
    }
}

/** Big title at the top of a tab. */
@Composable fun ScreenTitle(title: String, subtitle: String) {
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Txt(title, 32, FontWeight.Black, maxLines = 1, lineHeight = 38)
        Txt(subtitle, 15, FontWeight.Medium, Theme.dim)
    }
}

/** Filled capsule tag, e.g. "Here". */
@Composable fun Chip(text: String, color: Color = Theme.dim) =
    Txt(text, 13, FontWeight.SemiBold, color, Modifier
        .background(if (color == Theme.dim) Theme.tile else color.copy(alpha = 0.14f), CircleShape)
        .padding(horizontal = 10.dp, vertical = 5.dp))

/** A soft charcoal card, no border. */
@Composable fun Card(modifier: Modifier = Modifier, padding: Dp = 20.dp, content: @Composable ColumnScope.() -> Unit) =
    Column(modifier.fillMaxWidth().background(Theme.card, RoundedCornerShape(24.dp)).padding(padding),
        verticalArrangement = Arrangement.spacedBy(14.dp), content = content)

@Composable private fun Pressable(enabled: Boolean, onClick: () -> Unit, content: @Composable (Modifier) -> Unit) {
    val source = remember { MutableInteractionSource() }
    val pressed by source.collectIsPressedAsState()
    // One layer whose values are read when it draws: a button that turns on while it is under the keyboard is still
    // drawn once the keyboard goes away (separate scale and alpha layers were sometimes left blank).
    val look by rememberUpdatedState(if (!enabled) 0.35f else if (pressed) 0.8f else 1f)
    val size by rememberUpdatedState(if (pressed) 0.97f else 1f)
    content(Modifier
        .graphicsLayer { scaleX = size; scaleY = size; alpha = look }
        .clickable(source, null, enabled, role = Role.Button, onClick = onClick))
}

/** The one main action on a screen: full-width white capsule, black text. */
@Composable fun PrimaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, @DrawableRes icon: Int? = null, onClick: () -> Unit) =
    CapsuleButton(text, modifier, enabled, icon, Color.White, Color.Black, onClick)

/** An urgent main action ("Send “I need help”"): full-width red capsule, white text. */
@Composable fun DangerButton(text: String, modifier: Modifier = Modifier, @DrawableRes icon: Int? = null, onClick: () -> Unit) =
    CapsuleButton(text, modifier, true, icon, Theme.help, Color.White, onClick)

/** A second full-width action: dark capsule, white text. */
@Composable fun SecondaryButton(text: String, modifier: Modifier = Modifier, enabled: Boolean = true, @DrawableRes icon: Int? = null, onClick: () -> Unit) =
    CapsuleButton(text, modifier, enabled, icon, Theme.tile, Theme.text, onClick)

@Composable private fun CapsuleButton(text: String, modifier: Modifier, enabled: Boolean, icon: Int?, bg: Color, fg: Color, onClick: () -> Unit) =
    Pressable(enabled, onClick) { m ->
        Row(modifier.fillMaxWidth().heightIn(min = 56.dp).clip(CircleShape).background(bg).then(m).padding(horizontal = 20.dp),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            if (icon != null) { Ic(icon, fg, 20.dp); Spacer(Modifier.width(8.dp)) }
            Txt(text, 17, FontWeight.SemiBold, fg, maxLines = 1)
        }
    }

/** A small inline action, e.g. "Switch" in a row: compact dark capsule. */
@Composable fun GhostButton(text: String, enabled: Boolean = true, onClick: () -> Unit) =
    Pressable(enabled, onClick) { m ->
        Box(Modifier.heightIn(min = 36.dp).clip(CircleShape).background(Theme.tile).then(m).padding(horizontal = 14.dp),
            contentAlignment = Alignment.Center) { Txt(text, 15, FontWeight.SemiBold, maxLines = 1) }
    }

/** Round icon button, e.g. settings in a header. */
@Composable fun RoundIcon(@DrawableRes id: Int, size: Dp = 42.dp, tint: Color = Theme.text, bg: Color = Theme.tile, desc: String, onClick: () -> Unit) =
    Pressable(true, onClick) { m ->
        Box(Modifier.size(size).clip(CircleShape).background(bg).then(m).semantics { contentDescription = desc }, // TalkBack reads it
            contentAlignment = Alignment.Center) { Ic(id, tint, size * 0.45f) }
    }

/** Two-way switch in a capsule, e.g. List | Map. */
@Composable fun PillSwitch(left: String, right: String, isRight: Boolean, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().background(Theme.tile, CircleShape).padding(4.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        for ((title, r) in listOf(left to false, right to true)) {
            val on = isRight == r
            Box(Modifier.weight(1f).heightIn(min = 36.dp).clip(CircleShape).background(if (on) Color.White else Color.Transparent)
                .clickable(role = Role.Tab) { set(r) }, contentAlignment = Alignment.Center) {
                Txt(title, 15, FontWeight.SemiBold, if (on) Color.Black else Theme.dim, maxLines = 1)
            }
        }
    }
}

/** Label above a dark rounded text field. */
@Composable fun InputField(
    label: String, value: String, onChange: (String) -> Unit, placeholder: String = "",
    singleLine: Boolean = true, keyboard: KeyboardOptions = KeyboardOptions.Default, modifier: Modifier = Modifier,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Kicker(label)
        TextBox(value, onChange, placeholder, singleLine, keyboard, Modifier.fillMaxWidth())
    }
}

@Composable fun TextBox(
    value: String, onChange: (String) -> Unit, placeholder: String, singleLine: Boolean = true,
    keyboard: KeyboardOptions = KeyboardOptions.Default, modifier: Modifier = Modifier, shape: Shape = RoundedCornerShape(16.dp),
) = BasicTextField(
    value, onChange, modifier, singleLine = singleLine, maxLines = if (singleLine) 1 else 5, keyboardOptions = keyboard,
    textStyle = TextStyle(color = Theme.text, fontSize = 17.sp), cursorBrush = SolidColor(Theme.text),
    decorationBox = { inner ->
        Box(Modifier.background(Theme.tile, shape).padding(horizontal = 16.dp, vertical = 15.dp)) {
            if (value.isEmpty()) Txt(placeholder, 17, color = Theme.faint, maxLines = 1)
            inner()
        }
    },
)

/** On/off row with an explanation under it. */
@Composable fun SwitchRow(title: String, on: Boolean, set: (Boolean) -> Unit, note: String? = null) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Txt(title, 16, FontWeight.SemiBold, modifier = Modifier.weight(1f))
            Switch(on, set, colors = SwitchDefaults.colors(
                checkedThumbColor = Color.White, checkedTrackColor = Theme.safe, checkedBorderColor = Theme.safe,
                uncheckedThumbColor = Theme.dim, uncheckedTrackColor = Theme.tile, uncheckedBorderColor = Theme.line))
        }
        if (note != null) Txt(note, 14, color = Theme.dim)
    }
}

/** A full-height sheet with a title and a close button, like the iPhone's SheetPage. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable fun SheetPage(title: String, onClose: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    ModalBottomSheet(onClose, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
        containerColor = Theme.bg, contentColor = Theme.text, dragHandle = null,
        shape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)) {
        Column(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 20.dp).padding(top = 18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Txt(title, 26, FontWeight.Black, modifier = Modifier.weight(1f), maxLines = 1)
                RoundIcon(R.drawable.ic_close, 36.dp, desc = "Close", onClick = onClose)
            }
            Spacer(Modifier.height(16.dp))
            Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding(),
                verticalArrangement = Arrangement.spacedBy(16.dp), content = content)
            Spacer(Modifier.height(20.dp))
        }
    }
}

/** Simple confirm dialog in the app's colors. */
@Composable fun Confirm(title: String, text: String, yes: String, danger: Boolean = false, onYes: () -> Unit, onNo: () -> Unit) =
    AlertDialog(onNo, containerColor = Theme.card, titleContentColor = Theme.text, textContentColor = Theme.dim,
        title = { Txt(title, 20, FontWeight.Bold) }, text = { Txt(text, 15, color = Theme.dim) },
        confirmButton = { TextButton(onYes) { Txt(yes, 16, FontWeight.Bold, if (danger) Theme.help else Theme.text) } },
        dismissButton = { TextButton(onNo) { Txt("Cancel", 16, FontWeight.SemiBold, Theme.dim) } })

/** A message with one button, in the app's colors. */
@Composable fun Info(title: String, text: String, ok: String = "OK", onOk: () -> Unit) =
    AlertDialog(onOk, containerColor = Theme.card, titleContentColor = Theme.text, textContentColor = Theme.dim,
        title = { Txt(title, 20, FontWeight.Bold) }, text = { Txt(text, 15, color = Theme.dim) },
        confirmButton = { TextButton(onOk) { Txt(ok, 16, FontWeight.Bold) } })

/** Battery level, red at 20% or less. */
@Composable fun BatteryLabel(percent: Int) {
    val low = percent <= 20
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Ic(R.drawable.ic_battery_full, if (low) Theme.help else Theme.dim, 16.dp)
        Txt("$percent%", 15, FontWeight.Medium, if (low) Theme.help else Theme.dim)
    }
}
