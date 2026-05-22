# Changelog

All notable changes to kuri are documented here.

## [0.3.3] — 2026-04-25

### Fixes
- **Auth profile reliability** — macOS keychain-backed auth profiles now resolve `security` correctly, and profile metadata round-trips escaped JSON safely
- **Session persistence safety** — bridge export/import now uses real JSON serialization/parsing instead of fragile string scanning
- **Redirect and localhost hardening** — URL validation now normalizes localhost aliases and re-validates redirect hops in both HTTP fetch paths
- **CDP stability** — stale buffered events no longer satisfy later `waitForEvent()` calls, and unsupported external CDP endpoint shapes are rejected up front
- **Packaging correctness** — HAR status/duration output is fixed, Chrome binary discovery checks `PATH`, and the npm installer rejects unsupported platforms instead of treating Windows as Linux

### Release
- **Notarized macOS artifacts in GitHub Releases** — tagged releases now mirror the signed/notarized macOS tarballs alongside the self-managed release channel

## [0.3.2] — 2026-04-24

### Release channel
- **Self-managed stable channel** — installers and manifests now resolve binaries from the `release-channel` branch instead of GitHub Releases
- **Channel-only release flow** — tag publishing updates the raw GitHub channel manifest and asset paths without creating a GitHub Release entry
- **macOS notarization kept in path** — stable macOS tarballs remain signed and notarized, with raw GitHub download URLs exposed directly in the README and channel manifest

## [0.3.1] — 2026-04-23

### Maintenance
- **Zig 0.16 migration stabilization** — build, test, and startup paths updated for Zig 0.16 across local and GitHub Actions environments
- **CI portability fixes** — Linux libc linking, Chrome startup, and validator compatibility regressions resolved
- **Benchmark refresh** — README benchmark section updated with a fresh `kuri` rerun from `bench/token_benchmark.sh`
- **Version sync** — runtime strings, package metadata, and docs aligned to `0.3.1`

## [0.4.0] — 2026-05-22

### kuri-browser — Standalone Browser Engine
- **Native rendering engine** — Full DOM tree, CSS cascade with layout/paint, real `<table>` layout, font shorthands (border/padding/margin/list-style), text metrics with per-character glyph widths calibrated against headless Chrome
- **QuickJS runtime** — JavaScript evaluation, fetch/XHR bridge, cookie-aware navigation state, form extraction, session-backed form submission, HAR capture for browser flows
- **CDP server** — Minimal CDP WebSocket router, CDP discovery server, compressed screenshot fallback, parsed DOM selectors
- **Agent actions** — Click, type, snap, scroll, navigate, eval, back/forward via CDP-compatible commands
- **Parity tracking** — Pixel parity benchmark harness vs Chrome, example.com parity tracking (98.45% wrapper / 86.37% direct), per-char glyph width calibration

### kuri-mobile — iOS + Android Device Control
- **Zig-native device automation** — Driverless: no on-device app, no Bun, no Gradle, no Xcode-time builds
- **Android** — ADB host protocol, XML UI tree parser, device listing, tap/swipe/type via input commands
- **iOS** — Simulator control via `xcrun simctl`, real device listing via usbmuxd, CGEvent-based tap/swipe/pan/type into Simulator.app

### Server
- **Bearer-token API auth** — All endpoints protected by configurable bearer token, new `kuri token` CLI command for token management
- **Signal-safe Chrome lifecycle** — Chrome process shutdown uses signal-safe paths, preventing orphan processes

### CI
- **Startup smoke tests** — CI now validates the bearer-token authentication wall
- **Mobile skills discovery** — Help/version regression guard for kuri-mobile CLI

## [0.3.0] — 2026-03-20

### Human Copilot Mode
- **`open [url]`** — one command to launch visible Chrome with CDP and auto-attach. The human sees the browser, the agent rides alongside. No headless, no bot detection issues.
- **`HEADLESS=false`** — kuri server mode now supports visible Chrome. Default remains headless for backward compat.
- **`stealth`** — anti-bot patches (UA override, navigator.webdriver=false, fake plugins). Persists across commands via session.

### Agent-Friendly Output
- All commands now return clean, flat JSON instead of raw CDP responses:
  - `go` → `{"ok":true,"url":"..."}`
  - `click` → `{"ok":true,"action":"clicked"}`
  - `eval` → raw value (no triple-nested JSON)
  - `text` → real newlines (not escaped `\n`)
  - `back/forward/reload/scroll` → `{"ok":true}`
- Agents no longer need `jq '.result.result.value'` to parse output.

### Popup & Redirect Following
- **`grab <ref>`** — click + follow popup redirects in the same tab. Hooks both `window.open` and dynamically created `<form target="_blank">` (Google Flights pattern).
- **`wait-for-tab`** — poll for new tabs opened by the page.
- Tested end-to-end: Google Flights → Scoot booking page landed successfully.

### Compact Snapshot (20x token reduction)
- Default `snap` output is now compact text-tree: `role "name" @ref`
- Noise roles filtered by default (none/generic/presentation/ignored)
- `--interactive` mode for agent loops (~1,927 tokens on Google Flights)
- `--json` flag restores old JSON format for backward compat

### Token Benchmark
- Full workflow benchmark: `go→snap→click→snap→eval`
- kuri: **4,110 tokens** vs agent-browser: **4,880 tokens** — **16% savings per cycle**
- Reproducible: `./bench/token_benchmark.sh [url]`

### Security Testing
- `cookies` — list with Secure/HttpOnly/SameSite flags
- `headers` — security response header audit (CSP, HSTS, X-Frame-Options)
- `audit` — full security scan (HTTPS + headers + JS-visible cookies)
- `storage` — dump localStorage/sessionStorage
- `jwt` — scan all storage + cookies for JWTs, base64-decode payloads
- `fetch` — authenticated fetch from browser context (uses session cookies + extra headers)
- `probe` — IDOR enumeration: `probe https://api.example.com/users/{id} 1 100`
- `set-header` / `clear-headers` / `show-headers` — persist auth headers across commands

### Install
- `curl -fsSL https://raw.githubusercontent.com/justrach/kuri/main/install.sh | sh`
- `bun install -g kuri-agent` / `npm install -g kuri-agent`
- GitHub release workflow with optional Apple notarization (add APPLE_* secrets)

### CI
- Fixed QuickJS Debug-mode crash on Linux (`-Doptimize=ReleaseSafe` in CI)

## [0.2.0] — 2026-03-17

### kuri-agent CLI
- Scriptable Chrome automation via CDP — stateless, one command per invocation
- Session persistence at `~/.kuri/session.json` (cdp_url, refs, extra_headers)
- Commands: tabs, use, go, snap, click, type, fill, select, hover, focus, scroll, viewport, eval, text, shot, back, forward, reload
- Accessibility tree snapshots with ref-based element targeting (@e0, @e1, ...)

### Compact Snapshot Format
- Text-tree format: `role "name" @ref` — replaces verbose JSON
- Noise filtering: skip none/generic/presentation roles
- `--interactive` / `--semantic` / `--all` / `--json` / `--text` flags

## [0.1.0] — 2026-03-14

### Initial Release
- **kuri** — CDP HTTP API server (Chrome automation, a11y snapshots, HAR recording)
- **kuri-fetch** — standalone fetcher with QuickJS JS engine, no Chrome needed
- **kuri-browse** — interactive terminal browser (navigate, follow links, search)
- 230+ tests, 4-target cross-compilation (macOS/Linux × arm64/x86_64)
- Zero Node.js dependencies, 464 KB server binary
