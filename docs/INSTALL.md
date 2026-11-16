# Installing OpenAguja

OpenAguja is not on the App Store. Three routes, easiest first.

## 1. SideStore (recommended)

SideStore installs IPAs signed with your own certificate and
**auto-refreshes the 7-day signature on-device** — no computer needed
after the initial setup.

- Download `OpenAguja.ipa` from
  [GitHub Releases](https://github.com/hquezser/openaguja/releases).
- Install SideStore (side-store.io), then open the IPA — SideStore
  signs it with your certificate and installs it.

## 2. AltStore + AltServer

The classic free-signing route: AltServer on your computer refreshes
the app wirelessly. Same 7-day expiry, refreshed by AltServer when the
computer is around.

- Install AltServer (altstore.io) on macOS/Windows/Linux.
- Add OpenAguja's IPA as a source, or sideload the file.

## 3. Build from source

Full control — you sign with your own (free) Apple ID.

Prerequisites:

- **Xcode** (full install, `xcode-select` pointed at it)
- **Rust** + targets: `rustup target add aarch64-apple-ios
  aarch64-apple-ios-sim`
- `cargo install cargo-swift` (0.11.x)
- `brew install xcodegen`
- An iPhone paired with the Mac (Xcode → Devices → "Connect via
  network" for wireless installs)

Steps:

```bash
git clone https://github.com/hquezser/openaguja.git && cd openaguja

# signing identity — copy the example and fill yours in:
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
#   DEVELOPMENT_TEAM = YOURTEAMID
#   PRODUCT_BUNDLE_IDENTIFIER = com.yourname.openaguja

scripts/build-ios.sh        # cargo-swift + xcodegen + xcodebuild
# or install straight to the paired iPhone:
scripts/deploy-ios.sh       # respects OPENAGUJA_DEVICE_UDID
```

Free Apple ID limits: the provisioning profile expires after **7
days** — the app stops launching until re-signed. Automate the daily
re-sign with launchd: copy `contrib/launchd/deploy.plist.template`,
fill `__LABEL__`/`__REPO__`/`__LOG__`, adjust the schedule, then
`launchctl load` it. See `docs/CUSTOMIZATION.md` level 2.

## After installing

1. Open the app, grant Bluetooth/notification permissions, pair the
   watch (Réglages → watch pairing).
2. Configure your integrations: Réglages → Webhook HTTP (action URL +
   optional token), Réglages → Connexions → Mac (daemon), and import a
   profile or build routing modes under Routage.
3. See `docs/integrations/webhook.md` for a ready-made receiver
   (`contrib/receiver-python/receiver.py`).
