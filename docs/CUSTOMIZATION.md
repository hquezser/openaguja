# Customization levels

OpenAguja is generic by design: no personal URLs, names or device ids
live in the tracked source. Everything below is opt-in, from "configure
in the app" to "build your own".

## Level 0 — in the app (no code)

Everything configurable from the iOS app UI (French):

- **Webhook HTTP** (Réglages → Webhook HTTP): action URL, optional
  Bearer token (Keychain), custom headers, telemetry upload/history
  URLs — see [integrations/webhook.md](integrations/webhook.md).
- **Routing modes** (Boutons/Routage): per-action targets — webhook,
  Apple Music, Mac daemon, Shortcut, ring iPhone, phone camera, ignore —
  plus timed commands, heart-rate interval, daemon commands, crown
  button bindings. Modes are data (`RouteMode`), persisted in
  UserDefaults; **no built-in modes ship in code**.
- **Profiles** (Réglages → Profil): export/import the whole
  configuration (webhook URLs/headers/name, macd URL, routing, modes)
  as JSON — tokens are never exported. See
  `contrib/profiles/example.json`.
- Weather city, Apple Music, incoming-call display, camera screen,
  quick replies, alarms, calendar push, watch settings.

## Level 1 — integrations

- **Webhook**: any HTTP endpoint receiving watch actions + telemetry —
  [integrations/webhook.md](integrations/webhook.md) (+ a minimal
  stdlib-only Python receiver in `contrib/receiver-python/`).
- **iOS Shortcuts**: App Intents ("Envoyer une notification à la
  montre", "Faire vibrer la montre", mode de routage…) let other apps
  and personal automations reach the watch.
- **openaguja-macd**: tiny HTTP daemon on your Mac turning watch
  actions into local shell commands —
  [integrations/macd.md](integrations/macd.md).

## Level 2 — your own build

- `ios/Config/Local.xcconfig`: your `DEVELOPMENT_TEAM` +
  `PRODUCT_BUNDLE_IDENTIFIER` (free Apple ID works; the bundle id must
  be unique to you). See `Local.xcconfig.example`.
- `scripts/build-ios.sh` builds + installs nothing; `scripts/
  deploy-ios.sh` rebuilds and installs on your paired iPhone.
- Free Apple ID: the provisioning profile expires after **7 days** —
  automate a daily re-sign with launchd using
  `contrib/launchd/deploy.plist.template` (fill `__LABEL__`, `__REPO__`,
  `__LOG__`).

## Level 3 — CLI / protocol library

The `openaguja` CLI (`cargo run --features cli --bin openaguja --`)
and the `openaguja` Rust library (`protocol`, `telemetry`) expose the
whole safe command set: settings, alarms, quick replies, activity sync,
watchface upload, DFU. See `--help` and `docs/PROTOCOL.md`.
`openaguja-ffi` generates the UniFFI bindings the iOS app uses.

## Level 4 — lab (coming later)

`openaguja-lab`: experimental firmware/recovery tooling — **not in
this repository yet**.

## The personal-overlay pattern

Keep your private configuration **outside** the repo, in a separate
directory (its own git repo if you like). A typical overlay contains:

- `Local.xcconfig` → symlinked to `ios/Config/Local.xcconfig` (signing
  + bundle id)
- `profile.json` → imported once via Réglages → Profil → Importer
- macd `config.toml` → `~/.config/openaguja-macd/`
- launchd plist(s) for scheduled deploys / the daemon
- `AGENTS.local.md` → symlinked to the repo root; private operational
  notes for AI agents (gitignored here)
- an `install.sh` that creates those symlinks
- private docs (recovery notes, firmware assets) that must never be
  committed to the public repo
