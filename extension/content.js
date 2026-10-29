// Adds a "Translate" button to every voice message in WhatsApp Web. The audio
// goes to the VoiceNote Translator Mac app (through the extension's service
// worker); the result is shown under the message.
//
// WhatsApp re-renders messages often (e.g. when the play icon turns into a
// pause icon), which wipes anything injected into them. So each message's
// state lives here, keyed by its data-id, and the box is redrawn from it
// whenever WhatsApp throws it away.
(() => {
  const TAG = "wvt";
  // Any of these marks a voice note's play button. Only matched inside a chat
  // message ([data-id]), so the composer's record button is never picked up.
  const PLAY_SELECTORS = [
    '[aria-label="Play voice message"]',
    '[aria-label="Play audio message"]',
    '[data-icon="audio-play"]',
    '[data-icon="ptt-play"]',
  ].join(",");
  const states = new Map(); // message id -> { status, data, error, open, step }
  const waiting = new Map(); // audio capture id -> { resolve, reject }
  const requests = new Map(); // app request id -> { onProgress, resolve, reject }
  let appStatus = { connected: false, ready: false };

  // MARK: Connection to the service worker

  let port = null;
  function bridge() {
    if (port) return port;
    port = chrome.runtime.connect({ name: "whatsapp-tab" });
    port.onMessage.addListener((msg) => {
      if (msg.type === "status" && !msg.id) { appStatus = msg; return; }
      const r = requests.get(msg.id);
      if (!r) return;
      if (msg.type === "progress") return r.onProgress?.(msg.stage);
      requests.delete(msg.id);
      msg.type === "error" ? r.reject(new Error(msg.message)) : r.resolve(msg);
    });
    port.onDisconnect.addListener(() => {
      port = null;
      for (const r of requests.values()) r.reject(new Error("Lost the connection to the extension. Try again."));
      requests.clear();
      // Chrome restarts the extension's worker from time to time; reconnect so
      // the app's status stays current. If the extension itself was removed or
      // updated, chrome.runtime.id is gone and there's nothing to reconnect to.
      if (chrome.runtime?.id) setTimeout(bridge, 1000);
    });
    return port;
  }

  // Keep the worker awake while WhatsApp Web is open, and let it retry the app.
  setInterval(() => {
    if (!chrome.runtime?.id) return;
    try { bridge().postMessage({ type: "ping" }); } catch {}
  }, 20_000);

  function ask(msg, onProgress) {
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      requests.set(id, { resolve, reject, onProgress });
      try { bridge().postMessage({ ...msg, id }); }
      catch { requests.delete(id); reject(new Error("The extension was reloaded. Reload this page.")); }
    });
  }

  // MARK: Getting the audio out of WhatsApp

  window.addEventListener("message", (ev) => {
    if (ev.source !== window || !ev.data || !["audio", "error"].includes(ev.data[TAG])) return;
    const w = waiting.get(ev.data.id);
    if (!w) return;
    waiting.delete(ev.data.id);
    if (ev.data[TAG] === "audio") w.resolve(ev.data);
    else w.reject(new Error(ev.data.error));
  });

  function press(el) {
    const target = el.closest("button,[role=button]") || el;
    const r = target.getBoundingClientRect();
    const opts = { bubbles: true, cancelable: true, composed: true, view: window, clientX: r.x + r.width / 2, clientY: r.y + r.height / 2, button: 0 };
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup"]) {
      target.dispatchEvent(new (type.startsWith("pointer") ? PointerEvent : MouseEvent)(type, { ...opts, pointerId: 1, isPrimary: true }));
    }
    target.click();
  }

  function captureAudio(msgId) {
    const playEl = playButtonIn(msgId);
    if (!playEl) return Promise.reject(new Error("Couldn't find this voice message's play button. Scroll it into view and try again."));
    const id = crypto.randomUUID();
    return new Promise((resolve, reject) => {
      waiting.set(id, { resolve, reject });
      window.postMessage({ [TAG]: "arm", id }, "*");
      press(playEl);
    });
  }

  function toBase64(buf) {
    const bytes = new Uint8Array(buf);
    let s = "";
    for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
    return btoa(s);
  }

  function messageEl(msgId) {
    return document.querySelector(`[data-id="${CSS.escape(msgId)}"]`);
  }

  function playButtonIn(msgId) {
    const root = messageEl(msgId);
    return root && root.querySelector(PLAY_SELECTORS);
  }

  function chatName() {
    const t = document.querySelector("#main header [title], #main header span[dir='auto']");
    return t ? (t.getAttribute("title") || t.textContent || "").trim() : "";
  }

  // MARK: Drawing

  function anchorOf(playEl, root) {
    // The outermost element of the voice-note player that still fits inside
    // the bubble; the box goes right below it.
    let node = playEl;
    while (node.parentElement && node.parentElement !== root && node.parentElement.offsetWidth < 520) node = node.parentElement;
    return node;
  }

  function el(tag, cls, text) {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text != null) e.textContent = text;
    return e;
  }

  function link(label, onClick) {
    const b = el("button", "wvt-link", label);
    b.type = "button";
    b.addEventListener("click", (e) => { e.stopPropagation(); onClick(b); });
    return b;
  }

  const STEP = { transcribing: "Transcribing…", translating: "Translating…" };

  function bubbleIcon() {
    const ns = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    const path = document.createElementNS(ns, "path");
    // Speech bubble with three text lines.
    path.setAttribute("d", "M5 3h14a3 3 0 0 1 3 3v9a3 3 0 0 1-3 3h-7l-5 4v-4H5a3 3 0 0 1-3-3V6a3 3 0 0 1 3-3zm2 5v1.6h10V8H7zm0 3.5v1.6h7v-1.6H7z");
    path.setAttribute("fill", "currentColor");
    path.setAttribute("fill-rule", "evenodd");
    svg.append(path);
    return svg;
  }

  function draw(box) {
    const msgId = box.dataset.for;
    const st = states.get(msgId) || { status: "idle" };
    box.replaceChildren();

    const btn = el("button", "wvt-btn", { idle: "Translate", busy: "Translating…", error: "Retry" }[st.status]);
    btn.type = "button";
    // A finished note gets a small round icon instead of a label.
    if (st.status === "done") {
      btn.classList.add("wvt-icon");
      btn.title = btn.ariaLabel = st.open ? "Hide translation" : "Show translation";
      btn.append(bubbleIcon());
    }
    btn.disabled = st.status === "busy";
    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      if (st.status === "done") { st.open = !st.open; redraw(msgId); }
      else run(msgId);
    });
    box.append(btn);

    if (st.status === "busy") box.append(el("div", "wvt-panel wvt-busy", st.step || "Loading audio…"));
    if (st.status === "error") {
      const p = el("div", "wvt-panel wvt-error", st.error);
      if (/API key|settings|app/i.test(st.error)) {
        p.append(" ", link("Open VoiceNote Translator", () => ask({ type: "openSettings", tab: /API key/i.test(st.error) ? "translation" : "connections" }).catch(() => {})));
      }
      box.append(p);
    }
    if (st.status === "done" && st.open) {
      const p = el("div", "wvt-panel");
      p.append(el("div", "wvt-english", st.data.text));
      const orig = el("div", "wvt-original", st.data.transcript);
      orig.hidden = !st.showOriginal;
      const bar = el("div", "wvt-bar");
      bar.append(
        link("Copy", (b) => navigator.clipboard.writeText(st.data.text).then(() => { b.textContent = "Copied"; setTimeout(() => (b.textContent = "Copy"), 1200); })),
        link("Original", () => { st.showOriginal = !st.showOriginal; orig.hidden = !st.showOriginal; }),
        el("span", "wvt-meta", st.data.language || ""),
      );
      p.append(bar, orig);
      box.append(p);
    }
  }

  function redraw(msgId) {
    document.querySelectorAll(`.wvt-box[data-for="${CSS.escape(msgId)}"]`).forEach(draw);
  }

  function setState(msgId, patch) {
    states.set(msgId, Object.assign(states.get(msgId) || {}, patch));
    redraw(msgId);
  }

  // MARK: Translating

  async function run(msgId) {
    setState(msgId, { status: "busy", step: "Loading audio…" });
    try {
      if (appStatus.connected && !appStatus.ready && appStatus.problem) throw new Error(appStatus.problem);
      const audio = await captureAudio(msgId);
      setState(msgId, { step: "Sending to VoiceNote Translator…" });
      const data = await ask(
        { type: "translate", audio: toBase64(audio.buf), mime: audio.type, cacheKey: "web:" + msgId, chat: chatName() },
        (stage) => setState(msgId, { step: STEP[stage] || "Working…" }),
      );
      setState(msgId, { status: "done", data, open: true });
    } catch (e) {
      const msg = /Extension context invalidated/i.test(e.message) ? "The extension was updated. Reload this page." : e.message;
      setState(msgId, { status: "error", error: msg });
    }
  }

  // Earlier results come from the app's history; ask in batches as messages appear.
  let lookupQueue = [];
  let lookupTimer = null;
  function lookupLater(msgId) {
    lookupQueue.push(msgId);
    clearTimeout(lookupTimer);
    lookupTimer = setTimeout(async () => {
      const ids = lookupQueue;
      lookupQueue = [];
      try {
        const res = await ask({ type: "lookup", cacheKeys: ids.map((id) => "web:" + id) });
        for (const id of ids) {
          const hit = res.results?.["web:" + id];
          if (hit && states.get(id)?.status === "idle") setState(id, { status: "done", data: hit, open: true });
        }
      } catch {}
    }, 250);
  }

  function decorate(playEl) {
    const root = playEl.closest("[data-id]");
    if (!root) return;
    const msgId = root.getAttribute("data-id");
    if (root.querySelector(`.wvt-box[data-for="${CSS.escape(msgId)}"]`)) return;

    const box = el("div", "wvt-box");
    box.dataset.for = msgId;
    anchorOf(playEl, root).after(box);
    draw(box);

    if (!states.has(msgId)) {
      states.set(msgId, { status: "idle" });
      lookupLater(msgId);
    }
  }

  let queued = false;
  function scan() {
    queued = false;
    document.querySelectorAll(`[data-id] :is(${PLAY_SELECTORS})`).forEach(decorate);
  }
  new MutationObserver(() => {
    if (!queued) { queued = true; requestAnimationFrame(scan); }
  }).observe(document.body, { childList: true, subtree: true });
  bridge();
  scan();
})();
