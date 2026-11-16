# openaguja-macd — Mac command daemon

`openaguja-macd` is a tiny HTTP daemon (Rust/axum) that turns watch
actions into shell commands on your Mac — same Wi-Fi as the iPhone.
The iOS app routes actions to it via the **Mac daemon** target
(Réglages → Connexions → Mac: URL + Bearer token, token in Keychain).

## Endpoints

```
GET  /health       → {"ok":true}              (no auth, for tests)
GET  /cmd          → list of command names    (Bearer required)
POST /cmd/{name}   → run the configured command (Bearer required)
```

`POST /cmd/{name}` executes the shell command mapped to `name` in the
config and returns its exit status / output as JSON.

## Install

```bash
cargo build --release -p openaguja-macd
cp target/release/openaguja-macd ~/.local/bin/
mkdir -p ~/.config/openaguja-macd
cp macd/config.example.toml ~/.config/openaguja-macd/config.toml
# edit config.toml: real token + your commands
```

Run it (or under launchd):

```bash
openaguja-macd                      # default config path
openaguja-macd --config /path/config.toml
OPENAGUJA_DAEMON_TOKEN=secret openaguja-macd   # env overrides config token
```

Default config path: `~/.config/openaguja-macd/config.toml`.
Default bind: `0.0.0.0:9876` — reachable from the iPhone on the LAN.

## Config

See `macd/config.example.toml` (comments in French). Each `[commands]`
key = command name = URL segment; names match the watch action ids
(`play`, `pause`, `previous`, `next`, `volume_up`, `volume_down`,
`find_phone`, `camera`, `call_rejected`, `sos`, `quick_reply`) but you
can map any action id to any command name in the app's routing modes.

Forms accepted per command:

```toml
play = "osascript -e 'tell application \"Music\" to play'"
# or with a custom timeout:
notify = { run = "osascript -e 'display notification \"Hi\"'", timeout_secs = 5 }
```

`token` is required on `/cmd/*` (503 if unset); `OPENAGUJA_DAEMON_TOKEN`
takes precedence. `timeout_secs` (default 10) bounds each command.

## iOS side

In the app: **Réglages → Connexions → Mac** — set the daemon URL
(e.g. `http://my-mac.local:9876`), paste the same Bearer token, run
"Tester la connexion". Then in **Routage**, point any action (or a
whole mode) at the *Daemon Mac* target. Daemon commands can also be
bound per mode (`daemonCommands` / `daemonEndCommands` in a profile).

## Security notes

- The daemon executes arbitrary shell commands — keep it on a trusted
  LAN, use a strong random token, and prefer `127.0.0.1` binding if
  the iPhone reaches the Mac another way (e.g. VPN/tunnel).
- The token is sent as `Authorization: Bearer …` and never logged.
