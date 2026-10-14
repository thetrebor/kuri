# Installing kuri (fork) — build, MCP, and pi wiring

Setup for a fresh machine, using **this fork** rather than upstream's release
channel. Covers the browser server, the MCP server that exposes it to pi, and the
pi configuration that makes the tools reachable.

Written for a machine that has never had kuri. Verified on macOS arm64 against
kuri v0.6.1.

---

## Why a build instead of the one-line installer

Upstream publishes a stable binary, but this fork carries a change upstream does
not have — `KURI_ALLOW_PRIVATE`, which lets kuri reach localhost and private-IP
addresses. Without it the SSRF validator blocks every `127.0.0.1` and LAN
target, which is what the CNP stacks are served from.

So the binary must be built from this fork. There is no shortcut.

---

## 1. Zig 0.17

kuri v0.6.1 requires **Zig 0.17.0 or newer**. Check what you have:

```bash
zig version
```

If it prints 0.17 or higher, skip to step 2. Otherwise install it:

```bash
# macOS arm64 — adjust the filename for other platforms
# (list: https://ziglang.org/download/index.json)
curl -LO https://ziglang.org/download/0.17.0/zig-aarch64-macos-0.17.0.tar.xz

# verify the checksum against the published shasum before extracting
shasum -a 256 zig-aarch64-macos-0.17.0.tar.xz

mkdir -p ~/.local/zig-0.17.0
tar xf zig-aarch64-macos-0.17.0.tar.xz -C ~/.local/zig-0.17.0 --strip-components=1
ln -sfn ~/.local/zig-0.17.0/zig ~/.local/bin/zig
```

If Homebrew also has a `zig`, it will win if `/opt/homebrew/bin` is earlier in
`PATH` than `~/.local/bin`. Either reorder `PATH`, or unlink the keg:

```bash
brew unlink zig    # keeps it installed; `brew link zig` restores it
```

**Gate:** `zig version` prints `0.17.0`.

---

## 2. Build the fork

```bash
cd ~/Projects
git clone git@github.com:thetrebor/kuri.git
cd kuri
git checkout upgrade/v0.6.1-mcp
zig build
```

**Expect one failure.** `kuri-fetch` does not compile on v0.6.1 (four
`@bitCast` errors inside the `quickjs` dependency). That is an upstream problem,
not something you did, and it does not affect the browser or MCP servers. `zig
build` exits 1 because of it — check the summary line rather than the exit code:

```
Build Summary: 18/21 steps succeeded (1 failed)
+- install kuri-mcp success          ← this one matters
+- install kuri success
+- install kuri-fetch transitive failure   ← expected, harmless
```

**Gate:** `./zig-out/bin/kuri --version` prints `kuri 0.6.1`.

---

## 3. Install the binaries

```bash
cp zig-out/bin/kuri      ~/.local/bin/kuri
cp zig-out/bin/kuri-mcp  ~/.local/bin/kuri-mcp
kuri --version        # kuri 0.6.1
```

`kuri-mcp` is the MCP server; it talks to a running `kuri` over HTTP and never
opens a browser itself.

---

## 4. Run kuri as a service

kuri needs to stay running. The launcher must export `KURI_ALLOW_PRIVATE=1`, or
localhost navigation is blocked.

```bash
mkdir -p ~/Library/LaunchAgents
cat > ~/.local/bin/kuri-start <<'SH'
#!/bin/bash
PORT="${PORT:-9223}"
export KURI_ALLOW_PRIVATE=1
pkill -f "chrome-profile-headless" 2>/dev/null
pkill -f "/\.local/bin/kuri" 2>/dev/null
sleep 2
lsof -tiTCP:9222 -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null
sleep 1
export PORT
exec /Users/REPLACE_ME/.local/bin/kuri
SH
chmod +x ~/.local/bin/kuri-start
```

Replace `REPLACE_ME` with your username. Then the launchd plist:

```bash
cat > ~/Library/LaunchAgents/com.local.kuri.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.local.kuri</string>
    <key>ProgramArguments</key>
    <array><string>/Users/REPLACE_ME/.local/bin/kuri-start</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/kuri-launchd.log</string>
    <key>StandardErrorPath</key><string>/tmp/kuri-launchd.err</string>
</dict>
</plist>
PLIST

launchctl load ~/Library/LaunchAgents/com.local.kuri.plist
```

**Gate:** `curl -s http://127.0.0.1:9223/health` prints JSON with
`"ok":true` and `"version":"0.6.1"`.

### The API token

kuri generates `~/.kuri/api.token` (0600) on first launch. The MCP server needs
it — step 5 passes it without writing the secret into any file.

---

## 5. Wire the MCP server into pi

Add to `~/.pi/agent/mcp.json`:

```json
{
  "mcpServers": {
    "kuri": {
      "command": "/Users/REPLACE_ME/.local/bin/kuri-mcp",
      "env": {
        "KURI_BASE": "http://127.0.0.1:9223",
        "KURI_SECRET": "!cat /Users/REPLACE_ME/.kuri/api.token"
      },
      "exposure": "deferred",
      "description": "Kuri browser automation: navigate, snapshot the accessibility tree, click/type/fill, screenshots, network requests. Token-efficient compact snapshots.",
      "toolExposure": {
        "navigate_page": "direct",
        "take_snapshot": "direct",
        "get_page_state": "direct"
      }
    }
  }
}
```

`KURI_SECRET` uses pi's `!command` form, which runs at connect time — the token
is never stored in the file. `KURI_BASE` **must** be set: `kuri-mcp` defaults to
port 8080, and kuri listens on 9223.

Then enable tool search in `~/.pi/agent/settings.json`:

```json
{ "defaultTools": ["+tool_search"] }
```

> **This is not optional.** With `exposure: "deferred"`, pi registers the
> server's tools but does not declare them to the model. `tool_search` is the
> only way the model reaches them. Without it the server connects, the tools
> exist, and nothing can call them — a silent failure, not an error.

**Gate:** start `pi`, run `/mcp`, and confirm `kuri` shows as connected with 14
tools.

---

## 6. Two-stage tool access — why only three tools are visible

The design keeps context small. Rather than declaring all 14 browser tools to
the model on every request, only three are direct and the rest are discovered:

| Tier | Tools | Behaviour |
|---|---|---|
| **direct** | `navigate_page`, `take_snapshot`, `get_page_state` | declared to the model, usable immediately |
| **deferred** | `click`, `fill`, `type_text`, `hover`, `evaluate_script`, `take_screenshot`, `take_snapshot_diff`, `list_pages`, `new_page`, `list_network_requests`, `wait_for` | not declared; the model searches for them when it needs them |

Use them as `mcp__kuri__<tool>` — for example `mcp__kuri__take_snapshot`.

`take_snapshot_diff` is worth reaching for inside a loop: it returns only what
changed, typically 3–9× fewer tokens than a full snapshot. `get_page_state` is
the cheapest orientation (~48 tokens) before paying for either.

---

## 7. Remove the old pi-kuri extension

If you previously installed the `pi-kuri` pi extension, it registers 30
`kuri_*` tools that overlap this server. Remove or disable it so the model is
not choosing between two sets:

```bash
rm -f ~/.pi/agent/extensions/pi-kuri.ts
```

The extension is superseded. Everything it offered is reachable through
`kuri-mcp`, except `kuri_screenshot_site`, which is being retired with it — see
"Known gaps" below.

---

## Verification summary

| # | Check | Expected |
|---|---|---|
| 1 | `zig version` | 0.17.0 or newer |
| 2 | `kuri --version` | `kuri 0.6.1` |
| 3 | `curl -s http://127.0.0.1:9223/health` | `"ok":true`, `"version":"0.6.1"` |
| 4 | `/mcp` in pi | `kuri` connected, 14 tools |
| 5 | Ask pi to navigate to a localhost URL | works (proves `KURI_ALLOW_PRIVATE`) |

Step 5 is the one that proves the fork is in use rather than upstream. Against a
stock build, `http://127.0.0.1:...` is rejected by the SSRF validator.

---

## Known gaps

1. **`kuri_screenshot_site` is gone.** The old extension had a
   site-manifest-aware screenshot tool that resolved pages from
   `.sandcastle/site-manifest.yaml` and saved to evidence paths. `kuri-mcp` has
   only a plain `take_screenshot`. If a workflow depends on the manifest form,
   that tool needs re-adding — as an MCP tool or a separate extension.

2. **`kuri-fetch` does not build** on v0.6.1 (quickjs incompatibility,
   upstream). Unrelated to this setup; ignore the build failure.

3. **`kuri-mobile` needs macOS Accessibility** granted to the terminal
   (`System Settings → Privacy & Security → Accessibility`). Not needed for the
   browser tools. Check with `kuri-mobile doctor`.

4. **The pi-kuri plugin package is not tracked on this branch.** It lives on
   `fix/evaluate-double-escape` and `feat/pi-kuri-plugin`. This branch is
   browser-server + MCP only.
