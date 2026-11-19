# Security Policy

## Supported versions

OpenAguja is maintained on a best-effort basis by a solo maintainer.
Security fixes land on `main` and in the latest GitHub Release; older
releases are not supported.

| Version | Supported |
| --- | --- |
| Latest release / `main` | :white_check_mark: |
| Older releases | :x: |

## Reporting a vulnerability

**Please do not open a public issue for security vulnerabilities.**

Report privately to **dev@hougo.nohost.me** with:

- a description of the issue and its potential impact
- steps to reproduce (a `--mock` reproduction is ideal — most protocol
  bugs do not need a real watch)
- affected version or commit SHA, platform, and the app / CLI /
  `openaguja-macd` component involved

You can expect an acknowledgement when the maintainer is available;
there is no guaranteed response time.

### What to report

- Memory-safety or crash bugs in the Rust protocol, transport, DFU or
  watchface code
- Parsing bugs triggered by malformed BLE payloads, webhook bodies or
  profile JSON
- Authentication or token-handling weaknesses in `openaguja-macd` or
  the iOS webhook server
- Privacy leaks: telemetry or logs exposing more data than documented

### Out of scope

- Damage caused by *documented* risky operations — see
  [docs/SAFETY.md](docs/SAFETY.md). Commands that write flash, erase,
  reboot or enter DFU are real actions; misuse is a user risk, not a
  vulnerability.
- Issues that require physical access to a watch, or that depend on
  sending opcodes the project deliberately does not expose.
- The watch firmware itself (proprietary, not part of this project)
  and third-party services you point OpenAguja at (your webhook,
  Shortcuts, `openaguja-macd` configuration).

## Security notes for users

- `openaguja-macd` binds to `127.0.0.1` by default; if you expose it,
  use a long random token and a trusted network — see
  [docs/integrations/macd.md](docs/integrations/macd.md).
- Telemetry uploads go only to endpoints you configure; review what
  leaves the watch before enabling upload.
- The iOS app is distributed unsigned via Releases — you sign it
  locally with your own certificate (SideStore / AltStore). Only
  install IPAs from this repository's Releases page.
