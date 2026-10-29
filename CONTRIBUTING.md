# Contributing

Thanks for helping! Bug reports and pull requests are welcome.

## Getting set up

```bash
make install   # build for this Mac, install into /Applications
make test
```

Load `extension/` unpacked in Chrome (`chrome://extensions` → Developer mode → Load unpacked). After changing the extension, click its reload button and refresh WhatsApp Web. After changing the app, run `make install` again; it quits and replaces the running copy.

## When WhatsApp changes

Most breakage comes from WhatsApp updating its UI:

- **WhatsApp Web buttons missing:** update `PLAY_SELECTORS` in `extension/content.js`.
- **WhatsApp Web audio not captured:** see the three capture paths in `extension/page-hook.js`.
- **WhatsApp Desktop buttons missing:** the bubble labels are parsed by `parseBubble` in `Sources/VoiceNoteTranslator/WhatsAppDesktop.swift`. The accessibility identifiers used are `NavigationBar_HeaderViewButton` and `ChatMessagesTableView`.
- **WhatsApp Desktop audio not found:** the database query is in `WhatsAppDB.voiceNotes`.

Please include the WhatsApp version and macOS version in bug reports.

## Guidelines

- Keep the extension a thin connector: no network access, no API keys, no settings of its own.
- Keep WhatsApp Desktop access read-only.
- Watch CPU use when changing the WhatsApp Desktop refresh logic: every accessibility query is answered by WhatsApp itself.
- Bump `VERSION` and `extension/manifest.json` together; `scripts/build-app.sh` refuses to build when they differ.
- Releases (signing, notarization, the update feed and its key) are described in [docs/RELEASING.md](docs/RELEASING.md).
