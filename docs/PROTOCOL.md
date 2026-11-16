# ZeTime BLE protocol notes

Reverse-engineered protocol of the MyKronoz ZeTime hybrid smartwatch, as
implemented by this project (`src/protocol/`, `src/transport.rs`,
`openaguja-ffi`). Cross-checked against Gadgetbridge's
`ZeTimeDeviceSupport` (AGPL-3.0), the community documentation at
zetime.artificialred.nl and the decompiled official Android app.

**Read [SAFETY.md](SAFETY.md) before sending anything to a real watch.**
Every command below is a real action on real hardware.

## Transport

- One GATT service `00006006-0000-1000-8000-00805f9b34fb` in app mode.
  Characteristics: `0x8001` write commands, `0x8002` acks (+ `0x03`
  ack-kick byte), `0x8003` replies, `0x8004` watch→phone events.
- There is **no Nordic DFU service** (`0x1530/0x1531/0x1532`) in app mode —
  DFU is entered through a proprietary trigger (see DFU below).
- Advertised name: `ZeTime#<serial>` (e.g. `ZeTime#00000` on a unit whose
  settings were erased). The Rust transport scans for the `zetime` name
  pattern; the DFU-mode advertised name is different (below).
- Frames longer than the BLE MTU are split into ≤20-byte chunks
  (`ZeTimeDeviceSupport.sendMsgToWatch`); the watch reassembles them.
  Our `Reassembler` is more tolerant than Gadgetbridge's
  `receiveCompleteMsg` (any chunk count, garbage skipped).
- There is **no checksum** in this protocol.

## Framing

```
6F <cmd> <71=send / 70=request> <len:2> 00 <payload…> 8F
```

- `<cmd>` = opcode subject byte (below).
- `71` = phone→watch notification, `70` = request (GET).
- Ack frames: `6F 01 81 02 00 <cmd> <status> 8F` — status `00` = OK,
  `01`/`02` = refused/unknown. The status-2 "unknown opcode" ack carries
  cmd byte `00` — parse replies **positionally**, not by opcode byte.
- Other reply shapes seen on the wire:
  - `6F 01 80 02 00 <op> <rc> 8F` = known opcode, GET refused (rc 1) or rc 0
  - `6F <op> 80 <len> 00 …` = data reply
- Some commands are **blocked until a generic ack** is written back on
  `0x8003`: `0xD1`/`0xD2`/`0xD9`/`0xDD` events and the `0xD0` music
  controls. The ack echoes the command byte:
  `6F 01 81 02 00 <cmd> 00 8F` (`Command::GenericAck` /
  `encode_generic_ack`). Without it the watch refreshes only after a
  ~2–3 s timeout.

## Opcodes (subjects)

| Opcode | Meaning |
|---|---|
| `0x02` | Watch id / device info (fw `payload 0x05`, hw `0x02`) |
| `0x03` | Device version (same cmd family as 0x02 replies) |
| `0x08` | Battery power |
| `0x09` | Region/settings rewrite — **dangerous, see SAFETY** |
| `0x0B` | Language |
| `0x0C` | Units (0 metric / 1 imperial) |
| `0x0D` | Factory reset (the only working reset) |
| `0x0E` | Upgrade/DFU mode — bare `[0x01]` is the only working trigger |
| `0x11` | Reboot (refused on A2.0.55) |
| `0x13` | Bright-screen time (write-only) |
| `0x14` | Snooze duration |
| `0x15` | Do-not-disturb window |
| `0x19` | Notification text size |
| `0x1A` | Control device sub-commands (activity tracking, HR jump, shutdown…) |
| `0x1F` | Delete watchface |
| `0x20` | Watchface slot OTA (`is_ota` flag) |
| `0x21` | Night mode |
| `0x2A` | App settings page order — unknown opcode on A2.0.55 |
| `0x2E` | Button-function map (GET + SET) |
| `0x30` | User profile (sex/age/height/weight) |
| `0x36` | Does not exist in A2.0.55 dispatch table |
| `0x50` | Daily goals (5× `[u16le value][flag]`) |
| `0x52` | Data availability (steps/sleep/HR record counts) |
| `0x53`/`0x54` | Step data get/delete |
| `0x55`/`0x56` | Sleep data get/delete + sleep records |
| `0x57`–`0x5B` | Heart-rate / blood-pressure data family |
| `0x5C` | Auto heart-rate interval |
| `0x58` | Auto-sleep window `[enterH][enterM][exitH][exitM][days]` |
| `0x61` | Heart-rate record collection |
| `0x76` | Push extended message (notifications, calls, weather-adjacent) |
| `0x77` | World clock |
| `0x90` | Feature/switch flags (GET 4-byte word; SET per-bit) |
| `0x91` | Single status byte |
| `0x93`/`0x94` | Bind start / bind end + init flag |
| `0x97` | Alarms & reminders |
| `0x98`/`0x99` | Calendar month view / day events |
| `0x9A`–`0xA0` | Timezone, time surface, date format family |
| `0xB2` | World-clock city |
| `0xB6`/`0xB8`/`0xD6`/`0xD8` | DA14580 link / crypto channel (see Crypto) |
| `0xBA` | Park hands + sleep — **dangerous, see SAFETY** |
| `0xD0` | Music state request / music controls |
| `0xD1` | Camera remote (watch→phone) |
| `0xD2` | Find-phone (watch→phone) |
| `0xD3` | (empty reply observed) |
| `0xD9` | SOS (watch→phone) |
| `0xDA`/`0xDB` | Quick replies list / entry get-set-delete |
| `0xDC` | Call control (watch→phone) |
| `0xDD`/`0xDE`/`0xE6` | Quick-reply events (watch→phone) |
| `0xE2` | Real-time heart-rate push |
| `0xEE` | Keyed read (SRAM dumps when keyed right) |
| `0xEF` | 12-byte DA14580 link-state diagnostic (safe read) |
| `0xF0`/`0xF1` | Flash erase — **never call, see SAFETY** |
| `0xF6`–`0xFE` | Factory-test range (`0xFA` vibration, `0xFB` touch, `0xFE` LCD, `0xFF` write-ID **never**) |

The authoritative per-command encoders live in
`src/protocol/command.rs` (`Command` enum); reply parsers in
`src/protocol/parse.rs`. Provenance comments cite
`ZeTimeDeviceSupport.<method>`.

## Settings (all GET/SET unless noted)

- **Language**: `fr=7`, `es=6` per the decompiled Appscomm SDK
  (`j.c.a`) — Gadgetbridge's table swaps them. A wrong index sets the
  wrong language **silently**.
- **Time surface**: 8 bytes `[date_format][time_12h][…]`; `0xFF` bytes
  mean "leave unchanged".
- **Single-byte settings** (GET+SET verified live 2026-11-16):
  `0x0C` units (0 metric/1 imperial), `0x09` volume, `0x07` brightness,
  `0x14` snooze, `0x19` notification text size. `0x13`
  bright-screen-time is write-only.
- **Night mode** `0x21`: `[color 1-3][hasDial]` — 1 blue, 2 green,
  3 white; hasDial = tick ring (Android live-confirmed).
- **Goals** `0x50` GET → 15 B = 5×`[u16le value][flag]` for
  steps/calories/distance-km/sleep-h/active-min. Watch units: steps in
  hundreds, distance whole km, sleep hours, active minutes, calories kcal
  (`setUserGoals`).
- **User profile** `0x30`: `[sex][age][height][weight×10:u16le]`.
- **Do-not-disturb** `0x15`: 5-byte window `[startH][startM][endH][endM]`.
- **Vibration** `0xFA` SET `[01]` = motor on continuously, `[00]` = stop.
- **Feature flags** `0x90`: GET → 4-byte word (`F2 BF FF 7F` on one unit;
  bits 0-24 = switch ids used by `set` commands). Bit 2 = sleep tracking,
  bit 3 = auto-sleep detection.
- Auto-sleep window `0x58`: `[enterH][enterM][exitH][exitM][days]`,
  `days` = weekday bitmask (official app sends 127). Firmware-verified
  2026-11-11: `days=0` disables everything; factory default storage is
  days=0 — **never feed a read-back `days` value into a SET** (the app
  sends a hardcoded 0x7F). Overnight windows handled. Sleep records only
  exist when tracking was on. `0x36` does not exist in this firmware.
  Sleep record kinds in `0x56` (per the official app's aggregator
  `cn/appscomm/bluetoothsdk/b/c.java`): 0=deep, 1=light, 2/3/4=awake
  variants, 16=begin, 17=end, 18=end-folded. (The old community doc's
  "10: begin / 11: end" was hex 0x10/0x11 — do not remap to decimal.)
- **Heart-rate interval** `0x5C`: accepted 0 (off), 5, 10, 15, 30, 60;
  **1 and 120 refused (ack status 1)** — 5 is the minimum
  (live-verified 2026-11-08). The watch pushes `0xE2` real-time BPM
  while tracking and stores a record per interval, readable via `0x52`
  availability + `0x61` collection (`heart rate data` frames =
  `[ts:4][bpm:1]` pairs).
- **`0x1A` CONTROL_DEVICE sub-commands** (decompiled SDK): 3 = jump
  real-time HR, 11 = jump camera, 15 = exit real-time HR, 13/14 =
  start/end sport record (inferred), 9/10 = forbid/allow activity
  tracking, 1 = shutdown. **The jump subs are NO-OPs on A2.0.55** —
  `0x1A[0x0B]` refused ack=2 on 2026-10-29, `0x1A[0x03]`/`[0x0F]` no
  effect on 2026-11-08. On-demand cardio uses `SetHeartRateInterval`
  (0x5C) instead.
- Alarms `0x97`: entry types 1=medicine, 2=water, 4=alarm, 7=custom
  (renders `content` appended after the 20-byte field block). Edit =
  SET `[0x01] + existing_fields(10) + new_fields(10) + content_utf8`;
  the field block IS the identity (no stable id). AddAlarm same shape
  with `[0x00]` flag.
- Calendar: `0x99` opcode 4 = clear (sent before re-push for full
  replace); `0x98` month view = 32 B = 8×u32le day-bitmasks, wire order
  `[thisMonth][lastMonth][+1..+6]`, bit `dayOfMonth-1` — no year/month
  on the wire. iOS pushes ≤17 events, opcode 1 first then 2, 300 ms
  apart, each ack-checked.
- QR bind tail: `0x93` SET `[0x02]` → SetTime → `0x94` SET `[0x01]`
  (distinct from `CompleteInit` = `0x94` SET `[0x00]`).
- `0x94` GET (`checkInit`): reply `[0x01]` = initFlag=true — i.e.
  pairing/bind still required.
- `0x91` GET → single status byte; `0xEE` GET `[00]` → empty reply
  (keyed read); `0xF8` GET → 7-byte datetime.
- `0x56` GET streams 8-byte internal records from flash `0xA8000`
  (accounting records, not an app table).

## Physical buttons (0x2E)

- Button ids: 1=UP, 2=BOTTOM, 3=OTS_SHORT (crown short), 4=OTS_LONG
  (crown long). Functions 0-19 (1 dim screen, 4 music, 6 camera,
  16 find phone…).
- SET = `6F 2E 71 <len> 00 [0x02][buttonId][function]… 8F`, acked
  status 0 live (2026-10-29, again 2026-10-30 after reset).
- GET `6F 2E 70 01 00 00 8F` → same `[0x02][button][function]` records.
  Live-read on one unit: UP→1, BOTTOM→6, OTS_SHORT→4, OTS_LONG→6.
- Swipe gestures are **not** configurable — `0x2E` covers buttons only.

## Notifications & watch→phone events (0x8004)

Watch-initiated events: music `0xD0`, camera remote `0xD1`, find-phone
`0xD2`, SOS `0xD9`, call control `0xDC`, quick reply `0xDD` (0xDE/0xE6
are other reply variants). Payloads of `0xD2`/`0xD9` are undocumented —
the app logs raw bytes.

- `0xD0` music state query payload = `[source:1]` — the player picked
  on the watch's music screen: 0 = default slot, 1 = Deezer, 2 = Spotify
  (user report 2026-10-29; initially guessed swapped). The watch
  re-queries `source=0` on screen entry/back-navigation, so the last
  reply's title wins on a shared title line. The "simple status" reply
  has no app-name field — `[state][title]` only.
- `0xD0` music controls (play/pause/next/prev/volume) want the generic
  ack `6F 01 81 02 00 D0 00 8F` sent **first**, before the state/volume
  reply — otherwise the watch refreshes after a ~2–3 s timeout.
- `0xDD` payload decoded live (2026-10-29): `[reply_id:12][text]` where
  reply_id = stored reply → `FF×10 + crc16 LE`; emoji pick → literal
  UTF-8 + `0xFF` pad; empty list → `FF×8 00 01 FF FF` (list-request
  marker). The watch re-emits the event until the generic ack arrives.
- `0xDE` = `[index][utf16le content]`.
- `0xE6` = social/notification selection: bytes 0-7 emoji face (to first
  `0xFF`), byte 8 language, 9 command, 10-11 preset CRC LE (`0xFFFF` =
  none), 12+ notification CRC.
- Quick-reply resolution: `0xDA` GET → `[count][crc:2le]×count`;
  `0xDB` GET `[0]` streams all entries, `[1][crc:2le]…` matching ones —
  reply per entry `[seq][crc:2le][text]` (seq = 1-based stream position
  = slot index when streaming all). `0xDB` SET sub0 `[0][index][0][0]
  <text>` INSERTS at 1-based index; sub1 `[1][_][crc:2le]<text>` replaces
  by CRC; sub2 `[2][_][crc:2le]` deletes by CRC. Entries live in flash
  region `0xA2000` (8-byte header `"DEFA"`/`"USER"` magic + count@+5;
  10 slots × 184 B: len@+0 ≤180, CRC-16/CCITT-FALSE@+1 over the
  **UTF-16LE** text@+4 — ASCII writes display as CJK pairs). Every SET
  erase+rewrites the whole region (interruptible; a later SET repairs).
  The CRC is the stable id — indices shift on insert/delete.
- iOS cannot inject a reply into the originating app's notification
  (ANCS is display-only) — the resolved text is forwarded to routed
  targets as `"text"`.
- Notifications reach the watch straight from iOS via ANCS (system
  Bluetooth), not through this app; the watch only filters by category.
  Per-app filtering is iPhone-side (iOS notification settings).

## Music (0xD0)

- State request payload `[source]`: 0 default, 1 Deezer, 2 Spotify —
  the iOS app maps 1→Now Playing (private MediaRemote), 2→its "Assistant"
  remote. Opening a player sends its byte, then a byte-0 request 1–1.6 s
  later: a 0 within 3 s keeps the player.
- Crown volume on the default source is debounced app-side into one
  `volume_up`/`volume_down` event with `"value": N`.

## Power

- Off = `0x1A` SEND `[0x01]` (SDK `CONTROL_DEVICE_DEVICE_SHUTDOWN`;
  `0x11` = reboot), acked status 0 live. On = physical button long
  press or plugging in the charger (PMIC plug edge); the button toggle
  is ignored while charging.
- `0xBA` is not a plain power-off: it parks the hands
  (`[u16 <360][u16 <360][h][m][s]`) then posts msg `0x16f`.

## DFU / firmware update

- Trigger on A2.0.55: `0x0E` with bare payload `[0x01]`
  (`Command::EnterDfu`) is the **only** form that reboots into DFU; the
  addressed `0x0E` and the `0x20` `is_ota=1` SET are ack'd but never
  reboot. Send it **fire-and-forget** — the watch drops the link
  instantly, no ack.
- DFU-mode advertised name: `<8 hex digits>` (e.g. `07B33053`),
  optionally suffixed ` [<addr>]` — matched by prefix /
  `looks_like_dfu_name`.
- Running two btleplug `Manager`s in one process wedges the second DFU
  scan → the watchface-upload flow is deliberately two-process
  (`watchface upload --manual` + `dfu-push`).
- Firmware string segments (ZeFotaProtocol decode): `A`=Apollo MCU,
  `R`=Picture/asset version, `T`=TouchPanel, `H`=HR chip,
  `B`=build. Example healthy set `N2.0A2.0R3.0T0.3H0.5B5.5`.
- **Brick risk**: flashing an Apollo build that expects newer Picture
  assets leaves the watch booting with a broken UI (observed live —
  see project history). Always match firmware component versions;
  keep the watch on the charger for any flash attempt.

## Crypto / link layer (advanced)

- `flag==7` (`*0x10000a06`) = DA14580 link bring-up terminal state —
  reached by itself ~60–75 s into a session, NOT unlocked by the
  `0xB8`/`0xD8` AES handshake. Under the flag: `0xB8`/`0xD8` gains a
  3-byte relay to the DA14580 subsystem (`p2` 0-3 = session sub-cmds);
  `0xB6`/`0xD6` = async session config → returns `0xff` (silent).
- Crypto channel `0xB8`/`0xD8` (alias pair, handler `0x15f14`):
  GET `6F B8 70 12 00 [00][10]<16B> 8F` → same shape back. Transform
  (live-verified ×3): `out = AES128_ECB_enc(AES128_ECB_dec(
  "leyuanencryptkey", in), "appscomm"+8×00)` — mutual-auth handshake;
  the phone picks the session key. Wrong sub-code →
  `6F 01 80 02 00 B8 01` refusal.
- `0xEF` GET = 12-byte DA14580 link-state diagnostic (safe read).

## Hand calibration (LAB ONLY)

Android `HandCalibration.kt` live-confirmed: `0xB8` SET mode
2=unlock (white face + red dot), 1=continuous rotate, 0=stop,
3=lock; `0xB6` move-once `[hand 0=h/1=m][direction][angle:u16le ≤359]`.
**Never leave unlocked; always lock.** Exposed only via the CLI
`calibrate` subcommand — never in the app UI. See SAFETY.md.

## Live-verification log (dated facts)

- 2026-10-29: `0x2E` SET acked status 0; button map read back;
  music-state source bytes user-confirmed (0 default, 1 Deezer,
  2 Spotify); `0x1A[0x0B]` refused; `0xDD` payload decoded;
  notifications per-app filtering confirmed iPhone-side.
- 2026-10-30: `0x2E` SET re-confirmed after factory reset; DND window
  read/write verified.
- 2026-11-08: `0x1A[0x03]`/`[0x0F]` no-ops; `0x5C` interval values
  verified (5 min minimum, 1/120 refused); `0xE2` live HR pushes.
- 2026-11-10: sleep-marker CSV verification — watch worn + hourly HR
  all night but no `0x56` markers while manual mode was on.
- 2026-11-11: auto-sleep firmware-verified via `0xEE` SRAM dumps +
  disassembly (see Auto-sleep above).
- 2026-11-16 (BLE from dev shell, watch awake/paired): goals GET
  (steps raw×100), profile GET, night-mode GET/SET/restore, quick-reply
  insert/update/delete round-trip (UTF-16 picker OK), all 5 simple
  settings SET confirmed by read-back (SETs return a spurious
  unknown-opcode ack yet take effect), alarm add/edit(type 4→7
  custom+content)/time-edit/delete, calendar `0x99` push + `0x98` mask
  (mask slot bug found+fixed: +1 month lands in wire slot 2, not 3),
  QR-bind `0x93`→time→`0x94` all acked.
- Still unverified live: reply-event decode path end-to-end (needs a
  real notification + physical reply), calibration unlock screen,
  calendar clear opcode 4 (iOS-only path), alarm type-7 content
  rendering, `0x99` calendar events per Gadgetbridge (ships disabled).
