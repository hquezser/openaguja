# Contributing to OpenAguja

Thanks for your interest! OpenAguja is a small, volunteer-run project —
bug fixes, protocol findings, docs, translations and integrations of
all sizes are welcome.

## Before you start

- Skim [AGENTS.md](AGENTS.md) for the repository layout and conventions.
- Read [docs/SAFETY.md](docs/SAFETY.md) — **required** before touching
  anything that talks to a watch. Real commands are real actions, and
  some opcodes can brick the device; they are deliberately not exposed.
- Check [docs/PROTOCOL.md](docs/PROTOCOL.md) for the wire protocol and
  [docs/CUSTOMIZATION.md](docs/CUSTOMIZATION.md) for the supported
  extension points.

## Reporting bugs and requesting features

Use the issue templates (**Bug report** / **Feature request**). For
protocol questions or ambiguous behavior, include:

- app, CLI or commit version
- watch model and firmware version, if relevant
- whether you reproduced on the `--mock` path or on a real watch
- logs — **redact tokens, credentialed URLs and personal data** first

## Development setup

### Rust workspace (library, CLI, macd daemon)

```sh
cargo build --workspace
cargo run --features cli --bin openaguja -- --help
```

Checks — the same ones CI runs:

```sh
cargo fmt --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
```

### iOS app

Prerequisites: macOS, Xcode, Rust targets `aarch64-apple-ios` and
`aarch64-apple-ios-sim`, `cargo install cargo-swift`,
`brew install xcodegen`, and `ios/Config/Local.xcconfig` (copy from
`Local.xcconfig.example`) for signing.

```sh
scripts/swift-check.sh                 # typecheck non-UI Swift + smoke tests
cd ios && xcodegen generate             # regenerate OpenAguja.xcodeproj
xcodebuild -project ios/OpenAguja.xcodeproj -scheme OpenAguja \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Hosted macOS runners are not available for this project — run the
macOS checks locally before pushing Swift changes.

### Privacy guard

`scripts/public-check.sh` runs on every push and pull request. It
scans files and history for personal infrastructure, the maintainer's
professional email and private routine names. Enable it locally:

```sh
scripts/install-hooks.sh   # pre-push → scripts/public-check.sh
```

Never commit real endpoints, device IDs, tokens or personal automation
names — configuration and profiles must stay generic.

## Ground rules

1. **Safety first.** Never-call opcodes and brick risks are documented
   in [docs/SAFETY.md](docs/SAFETY.md). New commands go through
   `WatchCommand` review; anything that writes flash, erases, reboots,
   enters DFU or moves the hands stays CLI-only and documented. Do not
   run commands against a real watch "to see what happens" — use the
   `--mock` path.
2. **Generated files stay generated.** `ios/OpenAgujaCore/`,
   `ios/OpenAguja.xcodeproj` and `openaguja-ffi/generated/` are
   produced by cargo-swift, XcodeGen and uniffi-bindgen — never
   hand-edit them.
3. **Secrets stay out of the repo.** Tokens live in the Keychain or
   local config (e.g. `~/.config/openaguja-macd/`); profiles must not
   contain real endpoints or credentials.
4. **UI strings are bilingual.** English is the source language; add
   the French translation in `Localizable.xcstrings` / `fr.lproj/`
   for every new string.
5. **Naming.** `ZeTime*` names describe the watch and the protocol;
   `OpenAguja*` / `openaguja*` names describe the product.
6. **No firmware blobs.** Watch firmware images and
   reverse-engineering tooling are not part of this repository.

## Pull requests

- Keep pull requests focused and link the issue they address.
- Fill in the pull request checklist — CI runs fmt/clippy/tests plus
  the privacy guard.
- By contributing you agree your work is licensed under
  [AGPL-3.0-or-later](LICENSE), the same license as the project.
