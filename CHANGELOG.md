# Changelog

All notable changes to this project are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [1.1.1] - 2026-10-30

### Fixed
- Translate buttons now appear when WhatsApp, WhatsApp Web or macOS is set to a language other than English (German, Arabic, French, …).
- WhatsApp Desktop finds the voice note's audio on 12-hour clocks ("6:27 PM").
- The API key field in Settings → Translation is visible and has a hint inside.

### Added
- Opened from the disk image or Downloads, the app offers to move itself into Applications and reopens from there, so browsers and macOS permissions always find the right copy.
- A permission guide beside System Settings for Accessibility and Full Disk Access: switch the app on, or drag its icon into the list. It closes by itself once the permission is on.

### Changed
- Settings → Connections lists the two WhatsApp Desktop permissions as numbered steps and updates by itself; the menu bar shows when Full Disk Access is missing.

## [1.1.0] - 2026-10-29

### Added
- Automatic updates (Sparkle): daily checks, an "Update Available" item in the menu bar, Check for Updates…, and Settings → General → Updates.
- The browser extension refreshes itself after app updates when installed from the app.

### Changed
- Releases are a single notarized disk image plus the update feed.

## [1.0.1] - 2026-10-29

### Fixed
- WhatsApp Desktop popup no longer runs off the bottom of the screen with long text.

### Changed
- Translate buttons and the popup follow scrolling at 60 fps.
- The popup hides when you switch apps and returns the keyboard to WhatsApp when closed.

### Added
- Popup keyboard shortcuts: Esc / ⌘W close, ⌘C copy, Tab switches to the original.

## [1.0.0] - 2026-10-29

First release.

### Added
- Translate button for voice messages in WhatsApp Web (browser extension) and WhatsApp Desktop (Accessibility overlay).
- Mac menu bar app: connection status, language switcher, Settings (General, Translation, Connections, History, About), open at login.
- Native messaging connector (`vnt-host`) that only accepts the bundled extension and survives app restarts.
- OpenRouter and OpenAI-compatible APIs; configurable models; Keychain-stored API key.
- Translation cache and searchable history.
- Drag-and-drop disk image, build, packaging and release scripts; CI build.

[1.1.0]: https://github.com/noorfrhx/voicenote-translator/releases/tag/v1.1.0
[1.0.1]: https://github.com/noorfrhx/voicenote-translator/tree/v1.0.1
[1.0.0]: https://github.com/noorfrhx/voicenote-translator/tree/v1.0.0
