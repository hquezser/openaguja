# Safety — real commands are real actions

This project talks to real hardware. **Every command sent to the watch
is a real action**: it can change settings, erase data, vibrate the
motor, reboot the device — or brick it. There is no sandbox and no
undo.

## Never-call opcodes

These exist in the firmware and are deliberately **not exposed** by the
app or the safe command set (`WatchCommand` / `Command`):

| Opcode | Why |
|---|---|
| `0xF0` / `0xF1` | Flash erase — can destroy the firmware. |
| `0xFF` | Write-ID — destructive, identity region. Never sent, even during recovery scans. |
| `0xBA` | Not a plain power-off: parks the hands then sleeps the device in a weird state. |
| `0xFD` / `0xF2` | Factory test sequences — undefined side effects. |
| `0x09` | Region rewrite — erases a settings region. |
| `0x0E` (addressed forms) | Only the bare `0x0E [0x01]` DFU trigger is known-good; other payload forms are ack'd but their deferred behavior is unverified. |
| Watchface SET/DELETE (`0x1F`, `0x20`) | Can corrupt the watchface slot / trigger unintended OTA paths. The CLI exposes watchface upload only through the explicit `watchface` flow. |
| Hand-calibration `0xB8` modes | `0xB8` mode 2 unlocks hand movement (white face + red dot). **Never leave the watch unlocked** — always send mode 0/3 to stop/lock. Lab-only via the `calibrate` CLI subcommand; no app UI. |

## Commands that hurt if misused

- `0xFA` SET `[0x01]` turns the **vibration motor on continuously** —
  always follow with `[0x00]` to stop it.
- `0x0D` factory reset erases all watch settings (~60–90 s); the watch
  comes back needing re-pairing and re-configuration.
- `0xDA`/`0xDB` quick-reply SETs erase+rewrite the whole flash region
  `0xA2000` — do not interrupt the watch mid-write.
- DFU/firmware flashing: a mismatched firmware component set has
  already produced a watch that boots to a broken UI (grey/missing
  menu icons). Match component versions (`A`/`R`/`T`/`H`/`B` string
  segments), keep the watch **on the charger**, and never flash
  without understanding the recovery path. See `docs/PROTOCOL.md` →
  DFU.
- Alarms `0x97` edit uses the field block as identity — a malformed
  edit can corrupt the reminder list.

## Rules for contributors and agents

1. **Never run a command against a real watch "to see what happens."**
   Use the offline mock (`--mock` / `WatchCommand` encoders + parsers)
   for development. Live checks are deliberate, documented operations —
   see the dated live-verification log in `docs/PROTOCOL.md`.
2. New commands go through `WatchCommand` review: check the opcode
   against this file and `docs/PROTOCOL.md` first.
3. Anything that writes flash, erases, reboots, enters DFU, or moves
   the hands stays CLI-only and documented — never wire it into the
   iOS app UI or an automation by default.
4. When in doubt, check what Gadgetbridge's `ZeTimeDeviceSupport`
   exposes — if upstream doesn't call it, we probably shouldn't either.
