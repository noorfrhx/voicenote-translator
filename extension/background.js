// The extension's only link to the outside world: a native messaging
// connection to the VoiceNote Translator Mac app, which does all transcription
// and translation. This worker routes messages between WhatsApp Web tabs and
// the app, and keeps the connection open only while a WhatsApp tab is open.

const HOST = "io.github.voicenote_translator";
const VERSION = chrome.runtime.getManifest().version;
const IDLE_DISCONNECT_MS = 30_000;

let native = null;
let status = { connected: false, ready: false, problem: "Not connected yet." };
let idleTimer = null;
// While a WhatsApp tab is open and the app can't be reached (it was quit or is
// restarting), try again quietly: 3s, 6s, 12s… up to every 30s.
let retryTimer = null;
let retryDelay = 3000;
let nextRetryAt = 0;
const tabPorts = new Set();
const pending = new Map(); // request id -> { port } for tabs, or { resolve } for the popup

function browserName() {
  const brands = navigator.userAgentData?.brands?.map((b) => b.brand) ?? [];
  return brands.find((b) => !/Chromium|Not.?A.?Brand/i.test(b)) || "Chromium";
}

function friendly(error) {
  if (/not found/i.test(error)) return "The VoiceNote Translator app isn't installed, or hasn't been opened once yet.";
  if (/forbidden/i.test(error)) return "The app doesn't recognise this extension's ID. Update the app.";
  return error || "Lost the connection to the VoiceNote Translator app.";
}

// `auto` connections are background retries: the app's host won't start the app
// for those, so quitting the app on purpose keeps it quit.
function connect(auto = false) {
  if (native) return native;
  clearTimeout(idleTimer);
  clearTimeout(retryTimer);
  retryTimer = null;
  const port = chrome.runtime.connectNative(HOST);
  native = port;
  let offline = false;
  port.onMessage.addListener((msg) => {
    if (msg.offline) offline = true;
    onNativeMessage(msg);
  });
  port.onDisconnect.addListener(() => {
    const error = chrome.runtime.lastError?.message;
    if (native === port) native = null;
    if (!offline) setStatus({ connected: false, ready: false, problem: friendly(error) });
    for (const [id, p] of pending) deliver(id, p, { type: "error", message: status.problem });
    pending.clear();
    scheduleRetry();
  });
  port.postMessage({ type: "hello", id: "hello", version: VERSION, browser: browserName(), auto });
  return port;
}

function scheduleRetry() {
  if (tabPorts.size === 0 || retryTimer || native) return;
  nextRetryAt = Date.now() + retryDelay;
  retryTimer = setTimeout(() => { retryTimer = null; if (!native && tabPorts.size) connect(true); }, retryDelay);
  retryDelay = Math.min(retryDelay * 2, 30_000);
}

function onNativeMessage(msg) {
  if (msg.type === "status") {
    if (msg.offline) {
      setStatus({ connected: false, ready: false, problem: msg.problem || "VoiceNote Translator isn't running." });
    } else {
      retryDelay = 3000;
      setStatus({ connected: true, ready: !!msg.ready, problem: msg.problem || "", appVersion: msg.appVersion, targetLanguage: msg.targetLanguage });
    }
  }
  const p = msg.id && pending.get(msg.id);
  if (!p) return;
  // Progress updates keep the request open; everything else finishes it.
  if (msg.type !== "progress") pending.delete(msg.id);
  deliver(msg.id, p, msg);
}

function deliver(id, p, msg) {
  if (p.port) {
    try { p.port.postMessage({ ...msg, id }); } catch {}
  } else if (p.resolve && msg.type !== "progress") {
    p.resolve(msg);
  }
}

function setStatus(next) {
  status = { ...status, ...next };
  const bad = tabPorts.size > 0 && (!status.connected || !status.ready);
  chrome.action.setBadgeText({ text: bad ? "!" : "" });
  chrome.action.setBadgeBackgroundColor({ color: "#e5484d" });
  for (const port of tabPorts) {
    try { port.postMessage({ type: "status", ...status }); } catch {}
  }
}

// Only things the person asked for may start the app; lookups and status checks may not.
const USER_ACTIONS = new Set(["translate", "openSettings"]);

function request(msg, target, userAction = USER_ACTIONS.has(msg.type)) {
  const id = msg.id || crypto.randomUUID();
  pending.set(id, target);
  try {
    connect(!userAction).postMessage({ ...msg, id });
  } catch (e) {
    pending.delete(id);
    deliver(id, target, { type: "error", message: friendly(String(e.message || e)) });
  }
  return id;
}

// WhatsApp Web tabs connect with a long-lived port, so progress can stream back.
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "whatsapp-tab") return;
  tabPorts.add(port);
  clearTimeout(idleTimer);
  connect(true);
  port.postMessage({ type: "status", ...status });
  port.onMessage.addListener((msg) => {
    // Tabs ping every 20s. That keeps this worker awake, and lets a retry run
    // even if the worker was restarted and lost its timer.
    if (msg.type === "ping") {
      if (!native && !retryTimer && Date.now() >= nextRetryAt) connect(true);
      return;
    }
    request(msg, { port });
  });
  port.onDisconnect.addListener(() => {
    tabPorts.delete(port);
    for (const [id, p] of pending) if (p.port === port) pending.delete(id);
    if (tabPorts.size === 0) {
      clearTimeout(retryTimer);
      retryTimer = null;
      idleTimer = setTimeout(() => { native?.disconnect(); native = null; setStatus({ connected: false, problem: "Idle: no WhatsApp Web tab open." }); }, IDLE_DISCONNECT_MS);
    }
  });
});

// The toolbar popup asks for status, or to open the app's settings.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.type === "popupStatus") {
    if (native && status.connected) { sendResponse(status); return; }
    new Promise((resolve) => request({ type: "status" }, { resolve }))
      .then(() => sendResponse(status));
    setTimeout(() => sendResponse(status), 4000);
    return true;
  }
  if (msg.type === "openSettings") {
    request({ type: "openSettings", tab: msg.tab }, { resolve: sendResponse });
    return true;
  }
  if (msg.type === "reconnect") {
    native?.disconnect();
    native = null;
    retryDelay = 3000;
    // The person clicked Reconnect, so this may start the app.
    request({ type: "status" }, { resolve: () => sendResponse(status) }, true);
    return true;
  }
});
