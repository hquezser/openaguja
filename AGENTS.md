# OpenAguja — agent guide

Unofficial open-source iOS companion app, CLI and protocol library for
MyKronoz ZeTime hybrid smartwatches. Rust workspace + SwiftUI app.

If `AGENTS.local.md` exists at the repo root, read it too (private,
gitignored).

## Layout

- Root package `openaguja`: lib (`src/lib.rs` → `protocol` + `telemetry`
  only) + CLI bin `openaguja` (`required-features = ["cli"]`;
  btleplug/tokio/futures/image optional behind `cli`). BLE transport,
  DFU, watchface and the CLI live in the binary (`src/main.rs` +
  `src/{app,dfu,transport,watchface}.rs`).
- `openaguja-ffi/`: UniFFI bindings (proc-macro mode), `uniffi = "=0.31.1"`
  pinned to match cargo-swift 0.11.1 (`uniffi_bindgen =0.31.1`) — bump
  both together. crate-type `lib`+`staticlib` only (cdylib needs the
  iOS SDK). Bindgen bin behind feature `bindgen`.
- `macd/`: `openaguja-macd` — small HTTP daemon (axum) exposing watch
  commands to the iPhone: `POST /cmd/<action>` Bearer → shell commands
  from `~/.config/openaguja-macd/config.toml` (token also via
  `OPENAGUJA_DAEMON_TOKEN`, never committed). iOS routing target
  `.macDaemon` (`MacDaemonBridge.swift`, Keychain `macd.token`).
- `ios/`: SwiftUI app (iOS 16+), XcodeGen spec `ios/project.yml` →
  `ios/OpenAguja.xcodeproj` (generated, gitignored).
  `ios/OpenAgujaCore/` = cargo-swift output (gitignored). App sources
  in `ios/OpenAguja/`.
- `docs/`: PROTOCOL.md (wire protocol), SAFETY.md (never-call opcodes),
  CUSTOMIZATION.md, INSTALL.md, integrations/.
- `contrib/`: `profiles/example.json` (routing profile),
  `launchd/deploy.plist.template`, `receiver-python/` (example webhook
  receiver).
- `assets/brand/`: logo + SVG source of truth; `scripts/render-icons.sh`
  regenerates the app icon and PNG assets.
- Telemetry pipeline: `src/telemetry.rs` (`TelemetryEvent` →
  `{"timestamp":u64,"event_type":…,"payload":Value}`) +
  `openaguja-ffi/src/telemetry.rs` (`decodeTelemetryEvents`,
  `telemetryEventJson`, `encodeHeartRateMeasurement`/
  `encodeExitHeartRateMeasurement`). Swift: `TelemetryService` +
  `TelemetryUploader` (JSONL queue → webhook `telemetryUploadURL`) +
  `TelemetryHistory` (`GET telemetryHistoryURL?days=N`). Wire gaps:
  no raw-button push nor identified inactivity event (`button_id`
  resolved via table 0x2E when unique, `press_type` always null;
  `is_charging` always null; watch times = ISO-8601 local verbatim;
  steps/sleep/HR records only flow during activity syncs; `inactivity`
  = reserved schema type, never emitted).
- `openaguja-ffi/src/commands.rs`: `WatchCommand` (every safe command)
  + typed reply parsers. Never expose `0x0E` upgrade mode / watchface
  SET/DELETE to the app — see docs/SAFETY.md.

## Conventions

- **Swift imports**: view files `import OpenAgujaCore` (generated
  UniFFI types live there). Non-UI files use
  `#if canImport(OpenAgujaCore)` so `scripts/swift-check.sh` can
  typecheck them on macOS — **add every new non-UI file to its list**.
- UI strings are English source + French translations
  (`Localizable.xcstrings`, `fr.lproj/`) — iOS picks the device
  language; code comments/docs are English.
- Protocol-describing names keep `ZeTime` (`ZeTimeBluetoothManager`,
  `ZeTimeDeviceSupport` references…) — they describe the watch, not the
  product. Product/crate/module names are `OpenAguja*`/`openaguja*`.
- Generated files stay generated: `ios/OpenAgujaCore/` (cargo-swift),
  `ios/OpenAguja.xcodeproj` (xcodegen), `openaguja-ffi/generated/`
  (uniffi-bindgen) — never hand-edit.
- Secrets/tokens live in Keychain or local config — never in tracked
  files, profiles or logs.

## Safety

**Real watch commands are real actions.** Never-call opcodes and
brick risks are documented in `docs/SAFETY.md`; the wire protocol in
`docs/PROTOCOL.md`. Do not run BLE/watch commands for probing — use
the `--mock` path. Live checks are deliberate and documented.

## Verification

```bash
cargo fmt --check && cargo clippy --workspace --all-targets -- -D warnings && cargo test --workspace
cargo run --features cli --bin openaguja -- --help
scripts/build-ios.sh --rust-only     # Rust .a for iOS targets (no Xcode)
scripts/swift-check.sh               # macOS typecheck of non-UI Swift + smoke tests
cd ios && xcodegen generate
xcodebuild -project ios/OpenAguja.xcodeproj -scheme OpenAguja \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Prereqs for the iOS build: Xcode, Rust targets `aarch64-apple-ios` +
`aarch64-apple-ios-sim`, `cargo install cargo-swift`, `brew install
xcodegen`, and `ios/Config/Local.xcconfig` (see
`Local.xcconfig.example`) for signing identity.
