// Reads a DarkProof invite from this page's #fragment, in the browser only (spec/FORMAT.md, "Invites"). Nothing is
// sent anywhere: the page's Content-Security-Policy blocks all network requests from scripts (connect-src 'none').
"use strict";

// Same rules as the apps: items separated by "&", the first "=" splits name and value, "%XX" decoded, "+" kept as is,
// the first occurrence counts, the code needs 8 characters, the name defaults to "Group" and is cut to 24.
function readInvite(fragment) {
  var items = {};
  fragment.split("&").forEach(function (kv) {
    var i = kv.indexOf("=");
    if (i < 0) return;
    var k = dec(kv.slice(0, i));
    if (!(k in items)) items[k] = dec(kv.slice(i + 1));
  });
  var code = (items.code || "").trim();
  if (code.length < 8) return null;
  var name = (items.name || "").trim() || "Group";
  return { name: name.slice(0, 24), code: code };
}

function dec(s) {
  try { return decodeURIComponent(s); } catch (e) { return s; }
}

// Percent-encodes every byte that is not a letter, digit, "-", ".", "_" or "~", exactly like the apps.
function enc(s) {
  var out = "";
  new TextEncoder().encode(s).forEach(function (b) {
    var c = String.fromCharCode(b);
    out += /[A-Za-z0-9\-._~]/.test(c) ? c : "%" + (b < 16 ? "0" : "") + b.toString(16).toUpperCase();
  });
  return out;
}

function show() {
  var invite = readInvite(location.hash.slice(1));
  document.getElementById("ok").hidden = !invite;
  document.getElementById("bad").hidden = !!invite;
  if (!invite) { document.getElementById("title").textContent = "Join the group"; return; }
  document.getElementById("title").textContent = "Join “" + invite.name + "”";
  document.title = "Join " + invite.name + " on DarkProof";
  document.getElementById("open").href = "darkproof://join?name=" + enc(invite.name) + "&code=" + enc(invite.code);
}

document.addEventListener("DOMContentLoaded", function () {
  show();
  window.addEventListener("hashchange", show);
  document.getElementById("copy").addEventListener("click", function () {
    var status = document.getElementById("copied");
    if (!navigator.clipboard) { status.textContent = "Copy this page's address instead."; return; }
    navigator.clipboard.writeText(location.href).then(
      function () { status.textContent = "Invite copied. Paste it in DarkProof under “Join a group”."; },
      function () { status.textContent = "Couldn't copy. Copy this page's address instead."; });
  });
});
