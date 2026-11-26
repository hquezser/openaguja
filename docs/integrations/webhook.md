# Webhook integration

The iOS app posts every routed watch action to a single HTTP endpoint
you control, and can upload/sync telemetry to two more URLs. No server
SDK is required — any endpoint that accepts JSON POSTs works.

Configure in the app: **Réglages → Webhook HTTP** (name, action URL,
optional Bearer token kept in Keychain, custom headers, telemetry
upload/history URLs). "Tester la connexion" sends a `test` action.

## Action events

`POST <actionURL>` per watch action:

```json
{
  "action": "play",
  "value": 3,
  "text": "Bonjour",
  "timestamp": "2026-11-16T14:32:07+01:00"
}
```

- `action` (string, required): one of the action ids below, or `test`.
- `value` (int, optional): numeric payload — e.g. the crown volume
  level for `volume_up`/`volume_down`.
- `text` (string, optional): quick-reply text for `quick_reply`.
- `timestamp` (string): ISO-8601 with timezone, phone clock.

Action ids (`ActionRouter.actions`): `play`, `pause`, `previous`,
`next`, `volume_up`, `volume_down`, `find_phone`, `camera`,
`call_rejected`, `sos`, `quick_reply`, `remote_1`…`remote_6` (the six
buttons of the "Remote" app — only on watches running the community
firmware patch, see `docs/PROTOCOL.md` → `0xE8`) — plus `test`
(connection check). Each action is routed independently in the app (per-mode
targets); only actions whose target is "Webhook HTTP" are POSTed.

Headers sent:

- `Content-Type: application/json`
- `X-OpenAguja-Client: ios`
- `Authorization: Bearer <token>` — only if a token is configured
- plus any custom headers from settings (they may override the above)

Timeout 20 s; failed sends are queued on-device and retried. The token
is never logged or exported in profiles.

### Responses

- **2xx** = success (a JSON `{"message": "…"}` body is shown to the
  user, else "OK").
- **401/403** = token refused.
- Anything else = HTTP error shown with status.

Receivers **should answer 2xx to the `test` action** — it is what the
"Tester la connexion" button sends. Any HTTP status already proves the
server is reachable; 401/403 specifically means the token was rejected.

## Telemetry upload

When `telemetryUploadURL` is set, decoded watch telemetry is appended
to a local JSONL queue and POSTed (same headers as actions, incl.
optional Bearer + custom headers):

```json
{"timestamp": 1730000000, "event_type": "battery", "payload": {"level": 64, "is_charging": null}}
```

One JSON object per line/event. `timestamp` = phone-side unix seconds.
`event_type` ∈ `battery`, `heart_rate`, `steps`, `sleep`, `ble_status`,
`button`, `inactivity` (snake_case, see `src/telemetry.rs`). `payload`
is a free-form JSON object; watch-derived times inside it are local
wall-clock verbatim. Known gaps: `press_type`/`is_charging` always
null, `inactivity` never emitted, steps/sleep/HR records only flow
during activity syncs.

## Telemetry history

When `telemetryHistoryURL` is set, the app's history screen does:

```
GET <telemetryHistoryURL>?days=N        (or &days=N if the URL has a query)
Accept: application/json
X-OpenAguja-Client: ios
Authorization: Bearer <token>           (if configured)
```

Expected response: a **bare JSON array** of day objects (snake_case
keys), one per local day, newest last. Fields (all optional/nullable):

```json
[
  {
    "date": "2026-11-15",
    "sleep_minutes": 452,
    "sleep_hours": 7.5,
    "deep_minutes": 80,
    "light_minutes": 300,
    "rem_minutes": 72,
    "awake_minutes": 20,
    "bedtime": "23:12",
    "wake": "06:44",
    "resting_hr": 58,
    "avg_hr": 64,
    "max_hr": 121,
    "total_steps": 8432,
    "battery_min": 34,
    "events_count": 57
  }
]
```

`N` (`days`) is bounded 1..400 server-side expectation; the app offers
7/30-day presets. Empty array = "no data".

## Profiles

The whole non-secret configuration (webhook name/URLs/headers, macd
URL, routing targets, modes) round-trips as JSON via Réglages → Profil.
Format: `{"version":1, "webhook":{…}, "macDaemonURL":"…",
"routing":{…}, "modes":[…]}` — see `contrib/profiles/example.json`.
Tokens are never included.

## Minimal receiver

`contrib/receiver-python/receiver.py` — stdlib-only Python HTTP server:
Bearer check, prints every event, answers 2xx (including `test`).
Run: `python3 contrib/receiver-python/receiver.py --port 8787
--token secret` then point the app's action URL at
`http://<mac>:8787/hook`.
