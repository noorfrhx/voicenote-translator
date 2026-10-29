// Runs in WhatsApp Web's own page context (world: MAIN) so it can see the
// decrypted audio. WhatsApp only downloads and decrypts a voice note when it is
// played, so the content script "arms" a capture, clicks the play button, and
// this hook grabs the audio the moment WhatsApp hands it over, then stops
// playback before you hear it. It watches three hand-off points, because
// WhatsApp has used each of them: an <audio> element's play(), a blob URL, and
// Web Audio's decodeAudioData().
(() => {
  const TAG = "wvt";
  const blobsByUrl = new Map();
  let pending = null; // { id, timer }

  function take() {
    const req = pending;
    if (req) clearTimeout(req.timer);
    pending = null;
    return req;
  }

  function send(req, buf, type, via) {
    console.debug("[wvt] captured", buf.byteLength, "bytes via", via);
    window.postMessage({ [TAG]: "audio", id: req.id, type: type || "audio/ogg", buf }, "*", [buf]);
  }

  function fail(req, error) {
    console.warn("[wvt]", error);
    window.postMessage({ [TAG]: "error", id: req.id, error }, "*");
  }

  const origCreate = URL.createObjectURL;
  URL.createObjectURL = function (obj) {
    const url = origCreate.apply(this, arguments);
    if (obj instanceof Blob && obj.size > 1024 && !/^(image|video)\//.test(obj.type)) {
      blobsByUrl.set(url, obj);
      if (blobsByUrl.size > 50) blobsByUrl.delete(blobsByUrl.keys().next().value);
      // Give play() a moment to claim it first; it knows the exact element.
      if (pending && /^(audio\/|application\/octet-stream|$)/.test(obj.type)) {
        const req = pending;
        setTimeout(() => {
          if (pending !== req) return;
          take();
          obj.arrayBuffer().then((b) => send(req, b, obj.type, "blob"), (e) => fail(req, String(e)));
        }, 400);
      }
    }
    return url;
  };

  const origPlay = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    if (!pending || this instanceof HTMLVideoElement) return origPlay.apply(this, arguments);
    const req = take();
    const el = this;
    const wasMuted = el.muted;
    el.muted = true;
    const result = origPlay.apply(el, arguments);
    const stop = () => {
      el.pause();
      el.currentTime = 0;
      setTimeout(() => (el.muted = wasMuted), 300);
    };
    Promise.resolve(result).then(stop, stop);
    const src = el.currentSrc || el.src;
    (async () => {
      try {
        const blob = blobsByUrl.get(src) || (await (await fetch(src)).blob());
        send(req, await blob.arrayBuffer(), blob.type, "play");
      } catch (e) {
        fail(req, `Could not read the audio (${e.message || e}).`);
      }
    })();
    return result;
  };

  const AC = window.AudioContext || window.webkitAudioContext;
  if (AC) {
    const origDecode = AC.prototype.decodeAudioData;
    AC.prototype.decodeAudioData = function (buf) {
      if (pending && buf instanceof ArrayBuffer && buf.byteLength > 1024) {
        send(take(), buf.slice(0), "audio/ogg", "decodeAudioData");
      }
      return origDecode.apply(this, arguments);
    };
  }

  window.addEventListener("message", (ev) => {
    if (ev.source !== window || !ev.data || ev.data[TAG] !== "arm") return;
    const id = ev.data.id;
    pending = {
      id,
      timer: setTimeout(() => {
        if (pending && pending.id === id) fail(take(), "Timed out waiting for WhatsApp to load the audio.");
      }, 30000),
    };
  });
})();
