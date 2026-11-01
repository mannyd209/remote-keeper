// Remote Keeper web app. Talks to the Remote Keeper app on each of your computers through the
// relay. Everything sent is sealed with keys derived from that computer's QR code secret (see
// crypto.js), so the relay only ever sees ciphertext.

import { channelFor, deriveKeys, seal, open, b64u, saveSecretsForWorker } from "/crypto.js";

const RELAY = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/v1/ws`;
const STORE = "rk.computers";
const CURRENT = "rk.current";
const ALERTS = "rk.alerts";
const FORGOTTEN = "rk.forgotten"; // channels you forgot, so the Home Screen link doesn't add them back

const $ = (selector) => document.querySelector(selector);
const app = $("#app");

const standalone = matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;

const state = {
  computers: [], // [{ secret, channel, name, offline }], stored on this phone only
  links: new Map(), // channel → Link, one live connection per computer
  current: null, // channel of the computer on screen
  view: "main", // "main", "pick" (choosing sessions) or "scan" (adding a computer)
  choices: null, // sessions you can choose from, while picking
  picked: new Set(),
};

// MARK: - Computers

function loadComputers() {
  try {
    return JSON.parse(localStorage.getItem(STORE)) || [];
  } catch {
    return [];
  }
}

function saveComputers() {
  try {
    localStorage.setItem(STORE, JSON.stringify(state.computers));
    if (state.current) localStorage.setItem(CURRENT, state.current);
  } catch {}
  // The service worker reads these to open alerts and total up the badge.
  saveSecretsForWorker(state.computers).catch(() => {});
}

function forgotten() {
  try {
    return JSON.parse(localStorage.getItem(FORGOTTEN)) || [];
  } catch {
    return [];
  }
}

function setForgotten(list) {
  try {
    localStorage.setItem(FORGOTTEN, JSON.stringify(list.slice(-50)));
  } catch {}
}

/** Adds the computer behind a QR code link or secret, if it's new. Returns its channel.
 *  `scanned`: you just scanned or pasted it, so it counts even if you forgot it before. */
async function addComputer(secret, scanned = false) {
  if (!/^[A-Za-z0-9_-]{43}$/.test(secret)) return null;
  const channel = await channelFor(b64u.decode(secret));
  if (forgotten().includes(channel)) {
    if (!scanned) return null;
    setForgotten(forgotten().filter((c) => c !== channel));
  }
  if (!state.computers.some((c) => c.channel === channel)) {
    state.computers.push({ secret, channel, name: "", offline: 0 });
    saveComputers();
  }
  if (!state.links.has(channel)) await startLink(state.computers.find((c) => c.channel === channel));
  return channel;
}

function secretFromLink(text) {
  try {
    const url = new URL(text.trim(), location.origin);
    return new URLSearchParams(url.hash.slice(1)).get("k");
  } catch {
    return null;
  }
}

function computer(channel = state.current) {
  return state.computers.find((c) => c.channel === channel);
}

// Your own name and label for a computer (Work, Personal or Hobby), kept on this phone.
const LABELS = { work: ["Work", "#0a84ff"], personal: ["Personal", "#30d158"], hobby: ["Hobby", "#ff9f0a"] };
const REPO = "https://github.com/mannyd209/remote-keeper";

function displayName(c) {
  return c?.customName || c?.name || "Your computer";
}

function labelTag(c) {
  const label = LABELS[c?.label];
  return label ? `<span class="tag" style="--tag:${label[1]}">${label[0]}</span>` : "";
}

function link(channel = state.current) {
  return state.links.get(channel);
}

function select(channel) {
  state.current = channel;
  state.view = "main";
  saveComputers();
  render();
  link()?.hello();
}

function forgetComputer() {
  const c = computer();
  if (!confirm(`Forget ${displayName(c)} on this phone? You can link it again by scanning its QR code.`)) return;
  link()?.close();
  state.links.delete(c.channel);
  state.computers = state.computers.filter((x) => x.channel !== c.channel);
  setForgotten([...forgotten(), c.channel]);
  state.current = state.computers[0]?.channel || null;
  saveComputers();
  try {
    if (!state.current) localStorage.removeItem(CURRENT);
  } catch {}
  // Drop the secret from the address too, so a reload doesn't add it back.
  history.replaceState(null, "", "/");
  updateBadge();
  render();
}

// MARK: - One connection per computer

class Link {
  constructor(computer, keys) {
    this.channel = computer.channel;
    this.keys = keys;
    this.socket = null;
    this.macOnline = null;
    this.snapshot = null; // latest {t:"state"}: your chosen sessions on that computer
    this.pending = new Set(); // session ids we asked to reconnect, until the computer reports back
    this.retry = 0;
    this.closed = false;
    this.connect();
  }

  connect() {
    if (this.closed) return;
    const socket = new WebSocket(`${RELAY}?c=${this.channel}&role=phone`);
    this.socket = socket;
    let heartbeat, refresh;
    socket.onopen = () => {
      this.retry = 0;
      heartbeat = setInterval(() => socket.readyState === 1 && socket.send('{"t":"ping"}'), 25000);
      // Keep the list fresh while it's on screen (sessions run, Claude restarts).
      refresh = setInterval(() => document.visibilityState === "visible" && this.channel === state.current && this.hello(), 15000);
      resubscribe(this);
    };
    socket.onmessage = async (event) => {
      let frame;
      try {
        frame = JSON.parse(event.data);
      } catch {
        return;
      }
      if (frame.relay === "mac") {
        this.macOnline = frame.online;
        if (frame.online) this.hello();
        render();
      } else if (typeof frame.m === "string") {
        const message = await open(this.keys.toPhone, frame.m);
        if (message) this.handle(message);
      }
    };
    socket.onclose = () => {
      clearInterval(heartbeat);
      clearInterval(refresh);
      if (this.socket !== socket) return;
      this.socket = null;
      this.macOnline = null;
      render();
      const delay = Math.min(10000, 1000 * 2 ** this.retry++);
      setTimeout(() => !this.socket && document.visibilityState === "visible" && this.connect(), delay);
    };
  }

  close() {
    this.closed = true;
    this.socket?.close();
  }

  async send(message) {
    if (this.socket?.readyState !== 1) return false;
    this.socket.send(JSON.stringify({ m: await seal(this.keys.toMac, message) }));
    return true;
  }

  hello() {
    return this.send({ t: "hello" });
  }

  handle(message) {
    const here = this.channel === state.current;
    switch (message.t) {
      case "state": {
        this.snapshot = message;
        for (const id of [...this.pending]) {
          const s = message.sessions.find((x) => x.id === id);
          if (!s || !s.waking) this.pending.delete(id);
        }
        const c = computer(this.channel);
        const offline = message.sessions.filter((s) => !s.on).length;
        if (c && (c.name !== message.mac?.name || c.offline !== offline)) {
          c.name = message.mac?.name || c.name;
          c.offline = offline;
          saveComputers();
        }
        updateBadge();
        render();
        break;
      }
      case "choices":
        if (here) {
          state.choices = message.sessions;
          render();
        }
        break;
      case "result":
        this.pending.delete(message.id);
        toast(state.computers.length > 1 ? `${computer(this.channel)?.name}: ${message.text}` : message.text);
        break;
    }
  }
}

async function startLink(c) {
  state.links.set(c.channel, new Link(c, await deriveKeys(b64u.decode(c.secret))));
}

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  for (const l of state.links.values()) {
    if (!l.socket) l.connect();
    else l.hello();
  }
});

// The app icon's badge: how many of your chosen sessions are offline, on all your computers.
// (iPhone shows badges for Home Screen apps once alerts are allowed.) Restart alerts set it too,
// from the service worker.
function updateBadge() {
  const count = state.computers.reduce((n, c) => n + (c.offline || 0), 0);
  try {
    if (count > 0) navigator.setAppBadge?.(count)?.catch?.(() => {});
    else navigator.clearAppBadge?.()?.catch?.(() => {});
  } catch {}
}

// MARK: - Actions

async function reconnect(ids) {
  const l = link();
  ids.forEach((id) => l.pending.add(id));
  render();
  if (!(await l.send({ t: "wake", ids }))) {
    ids.forEach((id) => l.pending.delete(id));
    toast("That computer isn't connected right now.");
    render();
  }
}

function openPicker() {
  state.view = "pick";
  state.choices = null;
  state.picked = new Set((link()?.snapshot?.sessions || []).map((s) => s.id));
  render();
  scrollTo(0, 0);
  link()?.send({ t: "choices" });
}

function savePicker() {
  link()?.send({ t: "set", ids: [...state.picked] });
  state.view = "main";
  render();
  scrollTo(0, 0);
}

// MARK: - Rendering

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function ago(ms) {
  if (!ms) return "never";
  const s = Math.max(0, (Date.now() - ms) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.floor(s / 60)}m ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

const pin = (s) => (s.pinned ? '<span class="pin" title="Pinned">★</span>' : "");

function row(s, l) {
  const waking = s.waking || l.pending.has(s.id);
  const cls = waking ? "waking" : s.on ? "on" : "";
  const meta = waking ? "Reconnecting…" : `${s.on ? "Remote Control on" : "Remote Control off"} · ${ago(s.last)}`;
  const action = waking || s.on ? "" : `<button class="pill" data-wake="${esc(s.id)}">Reconnect</button>`;
  return `<li class="row ${cls}">
    <span class="dot" aria-hidden="true"></span>
    <div class="body"><div class="name">${esc(s.title)}${pin(s)}</div><div class="meta">${meta}</div></div>
    ${action}
  </li>`;
}

/** The row of computers at the top: tap one to switch to it. */
function switcher() {
  const chips = state.computers
    .map((c) => {
      const l = link(c.channel);
      const online = l?.macOnline === true;
      const count = online && c.offline ? `<span class="chip-count">${c.offline}</span>` : "";
      return `<button class="chip" data-computer="${c.channel}" aria-pressed="${c.channel === state.current}">
        <span class="dot ${online ? "online" : ""}"></span>${esc(displayName(c))}${labelTag(c)}${count}</button>`;
    })
    .join("");
  return `<div class="chips" role="tablist">${chips}<button class="chip add" id="add-computer" aria-label="Add a computer">＋</button></div>`;
}

function header(l) {
  const online = l?.macOnline === true;
  const statusText = l?.macOnline === null ? "Connecting…" : online ? "Online" : "Offline";
  return `<div class="eyebrow">Remote Keeper</div>
    <div class="title-row"><h1>${esc(displayName(computer()))}</h1><span class="status ${online ? "online" : ""}"><span class="dot"></span>${statusText}</span></div>
    <div class="name-row">${labelTag(computer())}<button class="text-button small" id="rename">${computer()?.customName || computer()?.label ? "Rename or label" : "Rename or add a label"}</button></div>`;
}

function render() {
  if (state.view === "scan") return; // the scanner draws itself
  if (!state.computers.length) return renderWelcome();
  if (state.view === "pick") return renderPicker();
  if (state.view === "edit") return renderEditor();
  const l = link();
  const snap = l?.snapshot;
  let html = (state.computers.length > 1 ? switcher() : "") + header(l);

  if (l?.macOnline !== true) {
    html += `<p class="subline">${
      l?.macOnline === false
        ? "Remote Keeper isn't running on this computer, or it's asleep. Your sessions show up here when it's back."
        : "Reaching your computer…"
    }</p>`;
  } else if (!snap) {
    html += `<p class="subline">Loading your sessions…</p>`;
  } else {
    html += `<p class="subline">${
      snap.claude.running ? `Claude started ${ago(snap.claude.since)}` : "The Claude app isn't running. Reconnecting a session opens it."
    }</p>`;
    const notices = [];
    const settings = [];
    if (!snap.ax) settings.push("<b>Allow typing</b> (Accessibility) is off for Remote Keeper on this computer.");
    if (snap.claudeSetting === false) settings.push("Claude's <b>Connect new sessions to Remote Control</b> setting is off.");
    if (settings.length) {
      notices.push(`${settings.join(" ")} <button class="notice-button" id="show-settings">Show on ${esc(displayName(computer()))}</button>`);
    }
    if (snap.locked) notices.push("This computer is locked, so sessions can't be reconnected until it's unlocked.");
    html += notices.map((n) => `<div class="notice">${n}</div>`).join("");

    const mine = snap.sessions;
    const offline = mine.filter((s) => !s.on && !s.waking && !l.pending.has(s.id));
    if (!mine.length) {
      html += `<div class="card intro"><strong>Choose the sessions to keep connected</strong>
        <p>Pick up to ${snap.max} sessions on this computer. Remote Keeper watches them, alerts you when one goes offline, and reconnects them when you tap.</p>
        <button class="primary" id="choose">Choose Sessions</button></div>`;
    } else {
      if (offline.length) html += `<button class="primary" id="wake-offline">Reconnect ${offline.length === 1 ? "1 Session" : `All ${offline.length}`}</button>`;
      else if (!mine.some((s) => s.waking || l.pending.has(s.id))) html += `<div class="all-good">All your sessions are connected.</div>`;
      html += `<div class="list-head"><h2>Your sessions <span>${mine.length} of ${snap.max}</span></h2><button class="text-button" id="choose">Edit</button></div>`;
      html += `<ul class="list">${mine.map((s) => row(s, l)).join("")}</ul>`;
      html += `<p class="hint">Green means Remote Control is on. Reconnecting runs Claude's own /remote-control command on your computer, which uses none of your Claude usage.</p>`;
    }
  }

  html += `<div class="section"><h2>Settings</h2><div class="card">${alertsSetting()}
    <div class="setting"><span>Add another computer<small>Scan the QR code in Remote Keeper on that computer</small></span><button class="text-button" id="add-computer">Add</button></div>
    <div class="setting"><span>Forget ${esc(displayName(computer()))}</span><button class="link-danger" id="forget">Forget</button></div></div></div>
    ${aboutSection(snap)}
    <p class="foot">Remote Keeper by MannyD Labs · not affiliated with Anthropic<br>The relay only passes along encrypted messages.</p>`;
  app.innerHTML = html;
}

// MARK: - About: version, updates, support

let latestRelease = null; // newest Mac version on GitHub

async function checkLatestRelease() {
  try {
    const release = await (await fetch("https://api.github.com/repos/mannyd209/remote-keeper/releases/latest")).json();
    if (release.tag_name) {
      latestRelease = release.tag_name.replace(/^v/, "");
      render();
    }
  } catch {}
}

function isNewer(a, b) {
  const x = a.split(".").map(Number), y = b.split(".").map(Number);
  for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] || 0) !== (y[i] || 0)) return (x[i] || 0) > (y[i] || 0);
  return false;
}

function aboutSection(snap) {
  const version = snap?.mac?.version;
  let line = version ? `Version ${esc(version)} on ${esc(displayName(computer()))}` : "Version shows when this computer is online";
  let action = "";
  if (version && latestRelease) {
    if (isNewer(latestRelease, version)) {
      line += ` · <b>${esc(latestRelease)} is available</b>`;
      action = `<button class="pill" id="update-mac">Update</button>`;
    } else {
      line += " · Up to date";
    }
  }
  return `<div class="section"><h2>About</h2><div class="card">
    <div class="setting"><span>Remote Keeper for Mac<small>${line}</small></span>${action}</div>
    <a class="setting link-row" href="${REPO}/issues/new/choose" target="_blank" rel="noopener"><span>Support &amp; report an issue</span><span aria-hidden="true">↗</span></a>
    <a class="setting link-row" href="${REPO}" target="_blank" rel="noopener"><span>Remote Keeper on GitHub<small>Open source, MIT license</small></span><span aria-hidden="true">↗</span></a>
    <a class="setting link-row" href="https://ko-fi.com/mannydlabs" target="_blank" rel="noopener"><span>Buy me a coffee ☕</span><span aria-hidden="true">↗</span></a>
  </div></div>`;
}

// MARK: - Renaming and labeling a computer (on this phone)

let editLabel = null;

function renderEditor() {
  const c = computer();
  const options = [["", "None", "#8e8e93"], ...Object.entries(LABELS).map(([k, [name, color]]) => [k, name, color])];
  app.innerHTML = `<div class="picker-bar"><button class="text-button" id="edit-cancel">Cancel</button><strong>Computer</strong><button class="text-button bold" id="edit-save">Save</button></div>
    <div class="section" style="margin-top:6px"><h2>Name</h2>
      <div class="card field"><input id="edit-name" type="text" maxlength="40" autocomplete="off" value="${esc(c.customName || "")}" placeholder="${esc(c.name || "Computer")}"></div>
      <p class="hint">Leave it empty to use the computer's own name${c.name ? `, ${esc(c.name)}` : ""}.</p></div>
    <div class="section"><h2>Label</h2>
      <div class="labels">${options.map(([key, name, color]) =>
        `<button class="label-option" data-label="${key}" aria-pressed="${(editLabel ?? c.label ?? "") === key}" style="--tag:${color}"><span class="swatch"></span>${name}</button>`).join("")}</div>
      <p class="hint">Names and labels are kept on this phone.</p></div>`;
}

function saveEditor() {
  const c = computer();
  const name = $("#edit-name").value.trim();
  if (name && name !== c.name) c.customName = name;
  else delete c.customName;
  const label = editLabel ?? c.label ?? "";
  if (label) c.label = label;
  else delete c.label;
  editLabel = null;
  saveComputers();
  state.view = "main";
  render();
}

function renderPicker() {
  const max = link()?.snapshot?.max || 10;
  const full = state.picked.size >= max;
  let html = `<div class="picker-bar"><button class="text-button" id="pick-cancel">Cancel</button>
    <strong>Choose Sessions</strong><button class="text-button bold" id="pick-done">Done</button></div>
    <p class="subline">${state.picked.size} of ${max} chosen on ${esc(displayName(computer()))}. Remote Keeper only watches and reconnects the sessions you choose.</p>`;
  if (!state.choices) {
    html += `<div class="list empty">Loading sessions…</div>`;
  } else if (!state.choices.length) {
    html += `<div class="list empty">No sessions on this computer yet.</div>`;
  } else {
    html += `<ul class="list">${state.choices
      .map((s) => {
        const on = state.picked.has(s.id);
        return `<li><button class="row pick" data-pick="${esc(s.id)}" aria-pressed="${on}" ${!on && full ? "disabled" : ""}>
          <span class="check" aria-hidden="true">${on ? "✓" : ""}</span>
          <span class="body"><span class="name">${esc(s.title)}${pin(s)}</span><span class="meta">${ago(s.last)}</span></span>
        </button></li>`;
      })
      .join("")}</ul>`;
  }
  app.innerHTML = html;
}

function alertsSetting() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    return `<div class="setting"><span>Restart alerts<small>${
      /iPhone|iPad/.test(navigator.userAgent) && !standalone ? "Add Keeper to your Home Screen to turn these on." : "This browser can't show alerts."
    }</small></span></div>`;
  }
  const on = localStorage.getItem(ALERTS) === "1" && Notification.permission === "granted";
  return `<div class="setting"><span>Restart alerts<small>When Claude restarts on any of your computers and your sessions go offline</small></span>
    <button class="switch" role="switch" id="alerts" aria-checked="${on}" aria-label="Restart alerts"></button></div>`;
}

function renderWelcome() {
  app.innerHTML = `<div class="welcome">
    <img src="/icons/icon-192.png" alt="">
    <h1>Remote Keeper</h1>
    <p>When the Claude desktop app restarts or updates, your Claude Code sessions lose Remote Control. Remote Keeper lets you reconnect them from your phone.</p>
    <ol class="steps">
      <li>Install Remote Keeper on your Mac and open it.</li>
      <li>Scan the QR code it shows with your phone's camera.</li>
      <li>Add this page to your Home Screen, so it opens like an app and can alert you.</li>
    </ol>
    ${standalone ? '<button class="primary" id="add-computer">Scan a QR Code</button>' : ""}
    <p class="foot">Remote Keeper by MannyD Labs · not affiliated with Anthropic</p>
  </div>`;
}

let toastTimer;
function toast(text) {
  const el = $("#toast");
  el.textContent = text;
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (el.hidden = true), 4500);
}

app.addEventListener("click", async (event) => {
  const target = event.target.closest("button");
  if (!target || target.disabled) return;
  if (target.dataset.wake) {
    reconnect([target.dataset.wake]);
  } else if (target.dataset.computer) {
    select(target.dataset.computer);
  } else if (target.dataset.pick) {
    const id = target.dataset.pick;
    if (state.picked.has(id)) state.picked.delete(id);
    else if (state.picked.size < (link()?.snapshot?.max || 10)) state.picked.add(id);
    render();
  } else if (target.id === "choose") {
    openPicker();
  } else if (target.id === "pick-done") {
    savePicker();
  } else if (target.id === "pick-cancel") {
    state.view = "main";
    render();
  } else if (target.id === "add-computer") {
    startScanner();
  } else if (target.id === "show-settings") {
    toast((await link()?.send({ t: "settings" })) ? "Opened the settings popup on your computer." : "That computer isn't connected right now.");
  } else if (target.id === "wake-offline") {
    reconnect(link().snapshot.sessions.filter((s) => !s.on && !s.waking).map((s) => s.id));
  } else if (target.id === "alerts") {
    await toggleAlerts(target.getAttribute("aria-checked") !== "true");
  } else if (target.id === "rename") {
    editLabel = null;
    state.view = "edit";
    render();
  } else if (target.dataset.label !== undefined) {
    editLabel = target.dataset.label;
    for (const b of document.querySelectorAll(".label-option")) b.setAttribute("aria-pressed", b.dataset.label === editLabel);
  } else if (target.id === "edit-save") {
    saveEditor();
  } else if (target.id === "edit-cancel") {
    editLabel = null;
    state.view = "main";
    render();
  } else if (target.id === "update-mac") {
    const sent = await link()?.send({ t: "update" });
    toast(sent ? `Updating Remote Keeper on ${displayName(computer())}. It restarts in a minute.` : "That computer isn't connected right now.");
  } else if (target.id === "forget") {
    forgetComputer();
  }
});

// MARK: - Adding a computer: scan its QR code in the app
// (A Home Screen app can't receive links the Camera app opens, so it scans for itself.)

let scanner = null;

async function startScanner() {
  state.view = "scan";
  app.innerHTML = `<div class="picker-bar"><button class="text-button" id="scan-cancel">Cancel</button><strong>Add a Computer</strong><span></span></div>
    <p class="subline">Open Remote Keeper on the other computer and point your camera at its QR code.</p>
    <div class="scanner"><video id="scan-video" playsinline muted></video><div class="scan-frame"></div></div>
    <p class="hint">Or copy the link from Remote Keeper on that computer and <button class="text-button" id="scan-paste">paste it</button>.</p>`;
  $("#scan-cancel").onclick = stopScanner;
  $("#scan-paste").onclick = async () => {
    try {
      await finishScan(await navigator.clipboard.readText());
    } catch {
      const text = prompt("Paste the link from Remote Keeper:");
      if (text) await finishScan(text);
    }
  };
  try {
    if (!window.jsQR) await loadScript("/vendor/jsQR.js");
    const stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
    const video = $("#scan-video");
    video.srcObject = stream;
    await video.play();
    const canvas = document.createElement("canvas");
    const context = canvas.getContext("2d", { willReadFrequently: true });
    scanner = { stream, timer: null };
    const tick = async () => {
      if (!scanner) return;
      if (video.videoWidth) {
        canvas.width = video.videoWidth;
        canvas.height = video.videoHeight;
        context.drawImage(video, 0, 0);
        const code = window.jsQR(context.getImageData(0, 0, canvas.width, canvas.height).data, canvas.width, canvas.height, {
          inversionAttempts: "dontInvert",
        });
        if (code?.data && (await finishScan(code.data))) return;
      }
      scanner.timer = setTimeout(tick, 200);
    };
    tick();
  } catch {
    toast("Couldn't open the camera. You can paste the link instead.");
  }
}

async function finishScan(text) {
  const secret = secretFromLink(text);
  const channel = secret && (await addComputer(secret, true));
  if (!channel) {
    toast("That isn't a Remote Keeper QR code.");
    return false;
  }
  stopScanner();
  select(channel);
  toast("Computer added.");
  return true;
}

function stopScanner() {
  if (scanner) {
    clearTimeout(scanner.timer);
    scanner.stream.getTracks().forEach((t) => t.stop());
    scanner = null;
  }
  state.view = "main";
  render();
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.onload = resolve;
    script.onerror = reject;
    document.head.appendChild(script);
  });
}

// MARK: - Restart alerts (Web Push), one subscription shared by all your computers

async function pushSubscription() {
  const registration = await navigator.serviceWorker.ready;
  return registration.pushManager.getSubscription();
}

/** A computer added after alerts were turned on gets the same subscription. */
async function resubscribe(l) {
  if (localStorage.getItem(ALERTS) !== "1" || !("serviceWorker" in navigator)) return;
  try {
    const subscription = await pushSubscription();
    if (subscription) l.socket?.send(JSON.stringify({ push: "subscribe", sub: subscription.toJSON() }));
  } catch {}
}

async function toggleAlerts(on) {
  try {
    const registration = await navigator.serviceWorker.ready;
    let subscription = await registration.pushManager.getSubscription();
    if (on) {
      if ((await Notification.requestPermission()) !== "granted") {
        toast("Alerts are blocked. You can allow them in Settings → Notifications.");
        return;
      }
      if (!subscription) {
        const { key: vapid } = await (await fetch("/v1/vapid")).json();
        subscription = await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64u.decode(vapid) });
      }
      for (const l of state.links.values()) l.socket?.send(JSON.stringify({ push: "subscribe", sub: subscription.toJSON() }));
      localStorage.setItem(ALERTS, "1");
      updateBadge();
      toast("You'll get an alert when Claude restarts and your sessions go offline.");
    } else {
      if (subscription) for (const l of state.links.values()) l.socket?.send(JSON.stringify({ push: "unsubscribe", endpoint: subscription.endpoint }));
      localStorage.removeItem(ALERTS);
    }
  } catch (error) {
    toast(
      error.name === "NotAllowedError"
        ? "This device didn't allow alerts. Check Settings → Notifications → Keeper."
        : `Couldn't change alerts: ${error.message}`,
    );
  }
  render();
}

// MARK: - Add to Home Screen

let installPrompt = null;
addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  installPrompt = event;
  showInstall();
});

function showInstall() {
  if (standalone) return;
  const ua = navigator.userAgent;
  const iPad = /iPad/.test(ua) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  const iPhone = /iPhone|iPod/.test(ua);
  const chrome = /CriOS/.test(ua);
  const firefox = /FxiOS/.test(ua);
  const safari = /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS|GSA\//.test(ua);
  // Safari 26 moved Share into the ☰ page menu in the address bar; older Safari has a Share button.
  const safariVersion = Number((ua.match(/Version\/(\d+)/) || [])[1] || 0);
  const banner = $("#install");
  const how = $("#install-how");
  const button = $("#install-button");
  let arrow = "none";

  if (installPrompt) {
    how.textContent = "It opens like an app and can alert you when Claude restarts.";
    button.hidden = false;
  } else if (iPhone && safari && safariVersion >= 26) {
    how.innerHTML = "Tap <b>☰</b> in the address bar, then <b>Share</b> → <b>View More</b> → <b>Add to Home Screen</b>.";
    arrow = "bottom-left";
  } else if (iPhone && safari) {
    how.innerHTML = "Tap <b>Share</b> below, then <b>Add to Home Screen</b>.";
    arrow = "bottom-center";
  } else if (iPad && safari) {
    how.innerHTML = "Tap <b>Share</b> at the top, then <b>Add to Home Screen</b>.";
    arrow = "top-right";
  } else if ((iPhone || iPad) && chrome) {
    how.innerHTML = "Tap <b>Share</b> in the address bar, then <b>Add to Home Screen</b>.";
    arrow = "top-right";
  } else if (iPhone && firefox) {
    how.innerHTML = "Tap <b>☰</b> below, then <b>Share</b> → <b>Add to Home Screen</b>.";
    arrow = "bottom-right";
  } else if (iPhone || iPad) {
    how.innerHTML = "Open this page in <b>Safari</b>, then use <b>Share</b> → <b>Add to Home Screen</b>.";
  } else if (/Android/.test(ua)) {
    how.innerHTML = "Tap <b>⋮</b> at the top, then <b>Add to Home screen</b>.";
    arrow = "top-right";
  } else {
    return; // A computer's browser: nothing to add.
  }
  banner.dataset.arrow = arrow;
  document.body.classList.toggle("has-install-top", arrow === "top-right");
  document.body.classList.toggle("has-install-bottom", arrow !== "top-right");
  banner.hidden = false;
}

$("#install-button").addEventListener("click", async () => {
  if (!installPrompt) return;
  installPrompt.prompt();
  await installPrompt.userChoice;
  installPrompt = null;
  $("#install").hidden = true;
});

// MARK: - Start

// Opening another computer's link while this page is open only changes the fragment (no reload).
addEventListener("hashchange", async () => {
  const secret = new URLSearchParams(location.hash.slice(1)).get("k");
  const channel = secret && (await addComputer(secret, !standalone));
  if (channel) {
    select(channel);
    showInstall();
  }
});

if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});

// keeper.mannydlabs.com/#demo shows made-up computers and sessions, with no connection at all
// (for screenshots, and to try the app without a Mac).
function startDemo() {
  const now = Date.now();
  const make = (title, minutes, on, pinned = false) => ({ id: title, title, last: now - minutes * 60000, on, pinned, waking: false });
  const demo = [
    { channel: "demo-studio", name: "Studio MacBook Pro", offline: 2, sessions: [make("Weather app: hourly forecast", 4, true, true), make("Landing page redesign", 38, true), make("API rate limiter", 190, false, true), make("Release notes 2.4", 1500, false)] },
    { channel: "demo-home", name: "Home Mac mini", offline: 0, sessions: [make("Recipe box iOS", 12, true, true), make("Photo backup script", 75, true)] },
  ];
  state.computers = demo.map(({ channel, name, offline }) => ({ channel, name, offline, secret: "" }));
  for (const d of demo) {
    const l = { channel: d.channel, macOnline: true, pending: new Set(), hello() {}, close() {}, socket: null };
    l.snapshot = { t: "state", mac: { name: d.name, version: "0.3.1" }, max: 10, locked: false, ax: true, claudeSetting: true, claude: { running: true, since: now - 7 * 60000 }, sessions: d.sessions };
    l.send = async (m) => {
      if (m.t === "choices") {
        const extra = ["Onboarding emails", "Invoice PDF export", "Dark mode polish", "Search indexing", "Docs site", "Bug bash: login"];
        state.choices = [...d.sessions, ...extra.map((t, i) => make(t, 300 + i * 900, false))].sort((a, b) => b.last - a.last);
        setTimeout(render, 0);
      }
      if (m.t === "set") d.sessions = d.sessions.filter((s) => m.ids.includes(s.id));
      if (m.t === "wake") {
        for (const id of m.ids) {
          const s = d.sessions.find((x) => x.id === id);
          if (!s) continue;
          s.waking = true;
          setTimeout(() => {
            Object.assign(s, { waking: false, on: true, last: Date.now() });
            l.pending.delete(id);
            computer(d.channel).offline = d.sessions.filter((x) => !x.on).length;
            render();
          }, 2500);
        }
      }
      return true;
    };
    state.links.set(d.channel, l);
  }
  state.current = demo[0].channel;
  render();
  showInstall();
  checkLatestRelease();
}

(async () => {
  if (location.hash === "#demo") return startDemo();
  state.computers = loadComputers();
  // A QR code opens this page with the secret in the fragment (#k=…), which browsers never send
  // to a server. The fragment stays in the address, so Add to Home Screen carries it along.
  const fromLink = new URLSearchParams(location.hash.slice(1)).get("k");
  // In a browser that link was just scanned; in the Home Screen app it's the saved start link.
  const linked = fromLink ? await addComputer(fromLink, !standalone) : null;
  for (const c of state.computers) if (!state.links.has(c.channel)) await startLink(c);

  // An alert opens the app on the computer it was about (?computer=<first 16 of its channel>).
  const fromAlert = new URLSearchParams(location.search).get("computer");
  let saved = null;
  try {
    saved = localStorage.getItem(CURRENT);
  } catch {}
  state.current =
    (fromAlert && state.computers.find((c) => c.channel.startsWith(fromAlert))?.channel) ||
    linked ||
    (state.computers.some((c) => c.channel === saved) ? saved : state.computers[0]?.channel) ||
    null;
  updateBadge();
  render();
  if (state.computers.length) showInstall();
  checkLatestRelease();
})();
