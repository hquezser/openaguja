# Real-world validation — patched-firmware "Remote" buttons (0xE8)

Procedure to validate support for the six buttons of the community
"Remote" app (`page4` firmware patch, zetime.artificialred.nl) before
merging. Everything below has passed **offline** (Rust/Swift tests,
iOS build). Only a real watch can confirm the parts marked
**unverified** in `docs/PROTOCOL.md`:

- the exact frame `6F E8 71 01 00 0n 8F`;
- that the watch really needs **no ack** (no retries, no error screen);
- that `n` is the number printed on the pressed button.

> **Scope and safety.** This PR never builds, ships or flashes
> firmware. Installing the patched firmware is a separate, deliberate
> act done by the owner of a **spare** watch with artificialred.nl's
> own tools, at their own risk: a patch that doesn't boot can only be
> recovered over SWD. Try the patched image in their emulator first.
> Read `docs/SAFETY.md`. No step below sends a dangerous opcode.

## A. Regression on stock firmware (mandatory, any watch)

Stock firmware never sends `0xE8`, so the change must be invisible.

| # | Step | Expected |
|---|---|---|
| A1 | Install the build from this branch on the iPhone, connect the watch | Connects as before |
| A2 | Routing → **Remote** tab (FR: *Télécommande*) | 6 rows "Remote button 1…6", target *Webhook HTTP* by default, footer explains patched firmware only |
| A3 | Change a Remote target, switch back to *Media*/*Alerts* | Other tabs unchanged; the active mode turns "custom" as for any manual edit |
| A4 | Music play/next from the watch, crown camera, find-phone | Routed and acked exactly as before (no 2–3 s lag, no "connection failed") |
| A5 | Import `contrib/profiles/example.json`, apply a mode | Applies as before; Remote targets fall back to defaults |
| A6 | App log after 10 min of normal use | No `0xE8` / `remote_` entry |

## B. Patched watch (needs a watch already running the patch)

### B0. Setup

- Watch on A2.0.55 **with** the `page4` patch installed (by its owner),
  on the charger, phone Bluetooth off for the CLI steps.
- Note the firmware string (Settings → About, or the app's device
  info) in the results table.
- A webhook receiver on the Mac:

  ```bash
  python3 contrib/receiver-python/receiver.py --port 8787
  ```

- Optional: `openaguja-macd` running with a harmless command, e.g. in
  `~/.config/openaguja-macd/config.toml`:

  ```toml
  remote_2 = "say 'remote two'"
  ```

### B1. Raw frames and numbering (CLI, no ack)

Run the read-only monitor **without** `--ack-events` (that flag never
acks `0xE8` anyway):

```bash
cargo run --features cli --bin openaguja -- -v monitor
```

On the watch: *Other apps* → **Remote**, then press each button
**once**, in order of the number printed on it (1 → 6), waiting 3 s
between presses.

| Check | Expected |
|---|---|
| Frame per press | exactly one `6F E8 71 01 00 0n 8F` → `RemoteButton(n)` |
| Retries | no repeated frame for the same press during 10 s (a repeat = the watch is waiting for an ack → **stop, report, do not merge**) |
| Watch screen | no error / "connection failed" after a press |
| Numbering | `n` = the number printed on the pressed button (write down any mismatch, with its position) |

Then press one button 5 times quickly: expect 5 frames, no stall.

### B2. Routing in the iOS app

Phone Bluetooth on, OpenAguja connected. Routing → Remote:
`remote_1` → *Webhook HTTP*, `remote_2` → *Mac (local HTTP)*,
`remote_3` → *iOS Shortcut* (any harmless shortcut), `remote_4` →
*Ignore*; leave 5–6 on the default.

| # | Press | Expected |
|---|---|---|
| B2.1 | button 1 | receiver prints `{"action":"remote_1", "timestamp":…}`; app log "Action : remote_1"; success haptic on the watch |
| B2.2 | button 2 | macd runs `remote_2` (hear "remote two") |
| B2.3 | button 3, app in foreground | the shortcut runs; app in background → log "skipped: app in background" (expected iOS limit) |
| B2.4 | button 4 | logged, nothing routed |
| B2.5 | stop the receiver, press button 1 | failure haptic (if enabled), error in the app log, app stays connected |
| B2.6 | iPhone locked, press button 1 (receiver back on) | webhook still received |
| B2.7 | Add `"daemonCommands": {"remote_5": "remote_2"}` to a mode, apply it, route `remote_5` → Mac, press 5 | macd runs `remote_2` |

### B3. Telemetry (if `telemetryUploadURL` is set)

One `button` event per press: `action:"remote_<n>"`, `opcode:"0xE8"`,
`remote_button:n`, `function:null`, `button_id:null`.

### B4. Resilience

- Leave the Remote page open for 5 min → no spurious frames.
- Walk out of range, come back → reconnects; next press routed.

## Results (paste into the PR)

```
Date:
Tester:
Watch hardware / firmware string:
Patch source/version:
A1–A6:      ok / ko (notes)
B1 frame:   ok / ko — raw:
B1 ack:     no retries / retries seen (details)
B1 mapping: n matches printed number? yes / no (details)
B2.1–B2.7:  ok / ko
B3:         ok / ko / n/a
B4:         ok / ko
```

## After validation

- Add a dated line to `docs/PROTOCOL.md` → *Live-verification log*
  with the confirmed frame, ack behaviour and numbering, and drop the
  "not yet confirmed" wording in `0xE8` / `WatchEvent::RemoteButton`.
- If the watch **does** wait for an ack, add `0xE8` to the generic-ack
  paths (`ack_cmd_for` in `src/app.rs`, `handle(action:)` in
  `ZeTimeBluetoothManager.swift`) before merging.
- If `n` doesn't match the printed number, fix the numbering note (ids
  stay `remote_<n>` as sent by the watch).
