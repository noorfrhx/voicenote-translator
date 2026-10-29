# Extension ↔ app protocol

The browser extension never talks to the network. It talks to the Mac app through Chrome's [native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging):

```
WhatsApp Web page ──► extension (content script) ──► extension (service worker)
        ──chrome.runtime.connectNative──► vnt-host (inside the app bundle)
        ──Unix socket──► VoiceNote Translator.app ──► OpenRouter (or any OpenAI-compatible API)
```

- Chrome starts `vnt-host` and only lets the extension IDs listed in the host manifest connect. The app writes that manifest for every Chromium browser it finds (Chrome, Chrome Beta/Canary, Chromium, Brave, Edge, Arc, Vivaldi) each time it starts.
- `vnt-host` relays bytes unchanged between Chrome (stdin/stdout) and the app's Unix socket at `~/Library/Application Support/VoiceNote Translator/bridge.sock` (mode 0600). If the app isn't running, it launches it.
- Both legs use Chrome's framing: a 4-byte little-endian length, then UTF-8 JSON.

## Messages

Every request carries an `id`; the reply carries the same `id`.

### Extension → app

| `type` | Fields | Meaning |
|---|---|---|
| `hello` | `version`, `browser` | Sent once after connecting. |
| `status` | | Ask for the app's state. |
| `translate` | `audio` (base64), `mime`, `cacheKey`, `chat?` | Transcribe and translate one voice note. |
| `lookup` | `cacheKeys` (array) | Which of these notes were already translated? |
| `openSettings` | `tab?` | Bring up the settings window. |

### App → extension

| `type` | Fields | Meaning |
|---|---|---|
| `status` | `appVersion`, `ready`, `problem?`, `targetLanguage` | Reply to `hello` / `status`, and pushed when settings change. |
| `progress` | `stage` (`transcribing` / `translating`) | While a `translate` runs. |
| `result` | `transcript`, `text`, `language`, `cached` | A finished translation. |
| `lookupResult` | `results` (object keyed by cache key) | Reply to `lookup`. |
| `error` | `message` | The request failed. |
| `ok` | | Plain acknowledgement. |

Messages from the app are kept well under Chrome's 1 MB limit for host-to-extension messages.
