//! Raw telemetry capture: decoded watch frames → JSON-ready events.
//!
//! Each [`TelemetryEvent`] serializes to the JSON document uploaded to the
//! configured telemetry endpoint:
//!
//! ```json
//! {"timestamp": 1730000000, "event_type": "battery",
//!  "payload": {"level": 64, "is_charging": null}}
//! ```
//!
//! `timestamp` is the phone-side receipt time (unix seconds). Watch-derived
//! times inside `payload` are transmitted verbatim as local wall-clock
//! ISO-8601 strings (`"2026-11-09T08:30:00"`, no offset): the watch stores
//! local time without a timezone, so no conversion is attempted — the
//! receiver knows the wearer's locale.
//!
//! Wire coverage (firmware A2.0.55):
//! - `battery`    ← `0x08` replies (`level`; `is_charging` stays null — the
//!   watch reports the level alone).
//! - `heart_rate` ← `0xE2` live pushes (`source:"live"`, phone timestamp)
//!   and `0x61` stored records (`source:"record"`, watch timestamp).
//! - `steps`      ← `0x54` records.
//! - `sleep`      ← `0x56` stage/marker records.
//! - `button`     ← watch-initiated action events on `0x8004` (music `0xD0`,
//!   camera `0xD1`, find-phone `0xD2`, SOS `0xD9`, call reject `0xDC`,
//!   quick reply `0xDD`). The wire carries the *function* triggered, not
//!   the physical button: `button_id` is resolved through the 0x2E
//!   button→function map when the caller supplies it and the match is
//!   unique (`button_candidates` lists the ambiguity otherwise).
//!   `press_type` is always null — no press-type field exists on the wire.
//! - `ble_status` ← generated phone-side (CoreBluetooth), never decoded
//!   here; the type exists so the schema is complete.
//! - `inactivity` ← reserved: no inactivity push has been identified on the
//!   wire yet (the undocumented `0xDE`–`0xE1`/`0xE6` event range is the
//!   remaining candidate). The type exists so the schema is complete.

use chrono::NaiveDateTime;
use serde::Serialize;
use serde_json::{Value, json};

use crate::protocol::parse::{self, SleepKind, WatchEvent};
use crate::protocol::{
    self, CMD_BATTERY_POWER, CMD_HEART_RATE_DATA, CMD_REQUEST_RESPOND, CMD_SLEEP_DATA,
    CMD_STEP_DATA,
};

/// Event categories of the telemetry upload schema (snake_case on the wire).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TelemetryEventType {
    Battery,
    HeartRate,
    Steps,
    Sleep,
    BleStatus,
    Button,
    Inactivity,
}

impl TelemetryEventType {
    /// Wire name, identical to the serde representation.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Battery => "battery",
            Self::HeartRate => "heart_rate",
            Self::Steps => "steps",
            Self::Sleep => "sleep",
            Self::BleStatus => "ble_status",
            Self::Button => "button",
            Self::Inactivity => "inactivity",
        }
    }
}

/// One telemetry document: `timestamp` (unix s, phone receipt time),
/// `event_type` and a free-form JSON `payload`.
#[derive(Debug, Clone, PartialEq)]
pub struct TelemetryEvent {
    pub timestamp: u64,
    pub event_type: TelemetryEventType,
    pub payload: Value,
}

impl TelemetryEvent {
    pub fn new(event_type: TelemetryEventType, timestamp: u64, payload: Value) -> Self {
        Self {
            timestamp,
            event_type,
            payload,
        }
    }

    /// Build an event from wire parts — `payload_json` must be a JSON
    /// object (validated, then embedded verbatim). Used by the FFI layer
    /// for phone-generated events (e.g. `ble_status`).
    pub fn from_json_parts(
        event_type: TelemetryEventType,
        timestamp: u64,
        payload_json: &str,
    ) -> Result<Self, protocol::ProtocolError> {
        let payload: Value = serde_json::from_str(payload_json).map_err(|e| {
            protocol::ProtocolError::InvalidValue(format!("telemetry payload: {e}"))
        })?;
        if !payload.is_object() {
            return Err(protocol::ProtocolError::InvalidValue(
                "telemetry payload must be a JSON object".into(),
            ));
        }
        Ok(Self::new(event_type, timestamp, payload))
    }

    /// Canonical JSON document for the telemetry endpoint.
    pub fn to_json(&self) -> String {
        #[derive(Serialize)]
        struct Wire<'a> {
            timestamp: u64,
            event_type: &'a str,
            payload: &'a Value,
        }
        let wire = Wire {
            timestamp: self.timestamp,
            event_type: self.event_type.as_str(),
            payload: &self.payload,
        };
        serde_json::to_string(&wire).expect("telemetry event always serializes")
    }
}

// ---------------------------------------------------------------------------
// Time helpers — watch times are local wall clock, kept verbatim.
// ---------------------------------------------------------------------------

/// `NaiveDateTime` (watch local wall time) → `"YYYY-MM-DDTHH:MM:SS"`.
fn iso_local(t: NaiveDateTime) -> String {
    t.format("%Y-%m-%dT%H:%M:%S").to_string()
}

/// Phone `now` (unix s) + UTC offset → local wall time → ISO string.
fn now_local_iso(now_unix: i64, utc_offset_seconds: i32) -> String {
    chrono::DateTime::from_timestamp(now_unix + i64::from(utc_offset_seconds), 0)
        .map(|d| iso_local(d.naive_utc()))
        .unwrap_or_default()
}

fn ts_unix(now_unix: i64) -> u64 {
    now_unix.max(0) as u64
}

// ---------------------------------------------------------------------------
// Frame → events
// ---------------------------------------------------------------------------

/// Decode every telemetry event carried by one complete watch frame.
/// Returns an empty vec for acks, settings replies and undecodable frames.
///
/// `now_unix`/`utc_offset_seconds` stamp phone-side times (live `0xE2`
/// pushes); `button_functions` is the current 0x2E button→function map
/// (`(button_id, function)` pairs, empty when unknown).
pub fn events_from_frame(
    frame: &[u8],
    now_unix: i64,
    utc_offset_seconds: i32,
    button_functions: &[(u8, u8)],
) -> Vec<TelemetryEvent> {
    // Same validation as the UI path: malformed frames yield nothing.
    if protocol::decode(frame).is_err() {
        return Vec::new();
    }
    let cmd = frame[1];
    let kind = frame[2];
    let payload = &frame[5..frame.len() - 1];
    let ts = ts_unix(now_unix);

    // Watch-initiated events (0x8004) first: their (cmd, kind) pairs never
    // collide with command replies.
    if let Some(event) = parse::parse_watch_event(frame) {
        return watch_event_events(
            event,
            cmd,
            ts,
            now_unix,
            utc_offset_seconds,
            button_functions,
        );
    }

    match (cmd, kind) {
        // Battery reply — `decode` treats any non-empty 0x08 payload as
        // battery; the level is payload[0], a hypothetical charge flag
        // would be payload[1] (A2.0.55 sends the level alone).
        (CMD_BATTERY_POWER, _) if !payload.is_empty() => {
            vec![TelemetryEvent::new(
                TelemetryEventType::Battery,
                ts,
                json!({
                    "level": payload[0],
                    "is_charging": payload.get(1).map(|&b| b != 0),
                }),
            )]
        }
        // Stored records, one reply frame each (0x80 kind).
        (CMD_HEART_RATE_DATA, CMD_REQUEST_RESPOND) => parse::parse_heart_rate_records(payload)
            .map(|records| {
                records
                    .into_iter()
                    .map(|r| {
                        TelemetryEvent::new(
                            TelemetryEventType::HeartRate,
                            ts,
                            json!({
                                "heart_rate_bpm": r.bpm,
                                "timestamp": iso_local(r.timestamp),
                                "index": r.index,
                                "source": "record",
                            }),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default(),
        (CMD_STEP_DATA, CMD_REQUEST_RESPOND) => parse::parse_step_record(payload)
            .map(|r| {
                vec![TelemetryEvent::new(
                    TelemetryEventType::Steps,
                    ts,
                    json!({
                        "step_count": r.steps,
                        "timestamp": iso_local(r.timestamp),
                        "index": r.index,
                        "calories": r.calories,
                        "distance_m": r.distance_m,
                        "active_min": r.active_min,
                    }),
                )]
            })
            .unwrap_or_default(),
        (CMD_SLEEP_DATA, CMD_REQUEST_RESPOND) => parse::parse_sleep_record(payload)
            .map(|r| vec![sleep_event(r, ts)])
            .unwrap_or_default(),
        _ => Vec::new(),
    }
}

fn sleep_event(r: parse::SleepRecord, ts: u64) -> TelemetryEvent {
    let local = iso_local(r.timestamp);
    let (stage, start, end) = match r.kind {
        // Stage markers: the record's timestamp is when that phase began.
        SleepKind::Deep => ("deep", Some(local.clone()), None),
        SleepKind::Light => ("light", Some(local.clone()), None),
        SleepKind::Begin => ("begin", Some(local.clone()), None),
        // End marker: timestamp = wake time.
        SleepKind::End => ("end", None, Some(local.clone())),
        SleepKind::Unknown(_) => ("unknown", Some(local.clone()), None),
    };
    TelemetryEvent::new(
        TelemetryEventType::Sleep,
        ts,
        json!({
            "sleep_stage": stage,
            "stage_code": match r.kind {
                SleepKind::Deep => 0,
                SleepKind::Light => 1,
                SleepKind::Begin => 10,
                SleepKind::End => 11,
                SleepKind::Unknown(v) => v,
            },
            "start_time": start,
            "end_time": end,
            "index": r.index,
        }),
    )
}

// ---------------------------------------------------------------------------
// Watch events → button / heart_rate telemetry
// ---------------------------------------------------------------------------

/// `(action_id, function_code)` for a watch action. Function codes follow
/// the 0x2E table (4 = music, 6 = camera, 16 = find phone); `None` when the
/// action has no configurable button binding.
fn action_function(action: &WatchEvent) -> (&'static str, Option<u8>) {
    match action {
        WatchEvent::Music(parse::MusicCommand::Play) => ("play", Some(4)),
        WatchEvent::Music(parse::MusicCommand::Pause) => ("pause", Some(4)),
        WatchEvent::Music(parse::MusicCommand::Previous) => ("previous", Some(4)),
        WatchEvent::Music(parse::MusicCommand::Next) => ("next", Some(4)),
        WatchEvent::Music(parse::MusicCommand::Volume(_)) => ("volume", Some(4)),
        WatchEvent::Music(parse::MusicCommand::Unknown(_)) => ("music_unknown", None),
        WatchEvent::Camera => ("camera", Some(6)),
        WatchEvent::FindPhone => ("find_phone", Some(16)),
        WatchEvent::Sos => ("sos", None),
        WatchEvent::CallRejected => ("call_rejected", None),
        WatchEvent::QuickReply(_) => ("quick_reply", None),
        // MusicStateRequest handled separately; RealTimeHeartRate too.
        WatchEvent::MusicStateRequest(_) | WatchEvent::RealTimeHeartRate { .. } => ("", None),
    }
}

/// Extra payload fields per action (volume level, raw reply bytes).
fn action_extra(action: &WatchEvent) -> Value {
    match action {
        WatchEvent::Music(parse::MusicCommand::Volume(level)) => {
            json!({ "level": level })
        }
        WatchEvent::Music(parse::MusicCommand::Unknown(code)) => json!({ "code": code }),
        WatchEvent::QuickReply(ev) => json!({
            "data_hex": ev.raw.iter().map(|b| format!("{b:02X}")).collect::<String>(),
            "preset_crc": ev.preset_crc,
            "face": ev.face,
            "sender": ev.sender,
            "content": ev.content,
        }),
        _ => json!({}),
    }
}

/// Resolve `function` → physical `button_id` through the 0x2E map.
/// Returns `(button_id, candidates)`: id only when exactly one button
/// carries the function, otherwise the ambiguous candidate list.
fn resolve_button(buttons: &[(u8, u8)], function: Option<u8>) -> (Option<u8>, Vec<u8>) {
    let Some(f) = function else {
        return (None, Vec::new());
    };
    let ids: Vec<u8> = buttons
        .iter()
        .filter(|&&(_, g)| g == f)
        .map(|&(b, _)| b)
        .collect();
    match ids.as_slice() {
        [one] => (Some(*one), Vec::new()),
        _ => (None, ids),
    }
}

fn watch_event_events(
    event: WatchEvent,
    cmd: u8,
    ts: u64,
    now_unix: i64,
    utc_offset_seconds: i32,
    button_functions: &[(u8, u8)],
) -> Vec<TelemetryEvent> {
    match event {
        // Live cardio push `0xE2 71 [bpm]` — no watch timestamp, the phone
        // receipt time stands in (same wall clock: the phone sets the watch).
        WatchEvent::RealTimeHeartRate { bpm } => vec![TelemetryEvent::new(
            TelemetryEventType::HeartRate,
            ts,
            json!({
                "heart_rate_bpm": bpm,
                "timestamp": now_local_iso(now_unix, utc_offset_seconds),
                "source": "live",
            }),
        )],
        // Music screen state query — navigation, not a press: no telemetry.
        WatchEvent::MusicStateRequest(_) => Vec::new(),
        other => {
            let (action, function) = action_function(&other);
            let (button_id, candidates) = resolve_button(button_functions, function);
            let mut payload = json!({
                "action": action,
                "opcode": format!("0x{cmd:02X}"),
                "button_id": button_id,
                "press_type": Value::Null,
                "function": function,
                "button_candidates": candidates,
            });
            if let (Value::Object(map), Value::Object(extra)) = (&mut payload, action_extra(&other))
            {
                map.extend(extra);
            }
            vec![TelemetryEvent::new(TelemetryEventType::Button, ts, payload)]
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000; // arbitrary unix seconds
    const OFFSET: i32 = 3600; // UTC+1 → local = now + 1h

    fn frame(cmd: u8, kind: u8, payload: &[u8]) -> Vec<u8> {
        let mut f = vec![0x6F, cmd, kind, payload.len() as u8, 0x00];
        f.extend_from_slice(payload);
        f.push(0x8F);
        f
    }

    fn only(frame_bytes: &[u8]) -> TelemetryEvent {
        let events = events_from_frame(frame_bytes, NOW, OFFSET, &[]);
        assert_eq!(events.len(), 1, "expected exactly one event");
        events.into_iter().next().unwrap()
    }

    #[test]
    fn battery_event_json() {
        // Live capture: `6F 08 80 01 00 06 8F`
        let e = only(&[0x6F, 0x08, 0x80, 0x01, 0x00, 0x06, 0x8F]);
        assert_eq!(e.event_type, TelemetryEventType::Battery);
        assert_eq!(e.timestamp, NOW as u64);
        assert_eq!(e.payload["level"], 6);
        assert!(e.payload["is_charging"].is_null());
        let json = e.to_json();
        assert!(json.starts_with("{\"timestamp\":"));
        assert!(json.contains("\"event_type\":\"battery\""));
        // Round-trip: the document parses and matches the schema.
        let parsed: Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["payload"]["level"], 6);
    }

    #[test]
    fn heart_rate_live_push() {
        // Live frame: `6F E2 71 01 00 31 8F` → 49 bpm
        let e = only(&[0x6F, 0xE2, 0x71, 0x01, 0x00, 0x31, 0x8F]);
        assert_eq!(e.event_type, TelemetryEventType::HeartRate);
        assert_eq!(e.payload["heart_rate_bpm"], 0x31);
        assert_eq!(e.payload["source"], "live");
        assert!(e.payload["timestamp"].is_string());
    }

    #[test]
    fn heart_rate_records_one_and_two() {
        // One record: [index:2le][ts:4le][bpm]
        let mut p = vec![0x01, 0x00];
        p.extend_from_slice(&1_792_972_800u32.to_le_bytes());
        p.push(72);
        let f = frame(0x61, 0x80, &p);
        let events = events_from_frame(&f, NOW, OFFSET, &[]);
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].payload["heart_rate_bpm"], 72);
        assert_eq!(events[0].payload["source"], "record");
        assert_eq!(events[0].payload["index"], 1);
        assert!(events[0].payload["timestamp"].is_string());

        // Two records in a 14-byte payload.
        let mut p2 = p.clone();
        p2.extend_from_slice(&[0x02, 0x00]);
        p2.extend_from_slice(&1_792_973_160u32.to_le_bytes());
        p2.push(75);
        let f2 = frame(0x61, 0x80, &p2);
        let events = events_from_frame(&f2, NOW, OFFSET, &[]);
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].payload["heart_rate_bpm"], 75);
        assert_eq!(events[1].payload["index"], 2);
    }

    #[test]
    fn step_record_event() {
        let mut p = vec![0x02, 0x00];
        p.extend_from_slice(&1_792_972_800u32.to_le_bytes());
        p.extend_from_slice(&5000u32.to_le_bytes());
        p.extend_from_slice(&250u32.to_le_bytes());
        p.extend_from_slice(&3500u32.to_le_bytes());
        p.extend_from_slice(&45u32.to_le_bytes());
        let e = only(&frame(0x54, 0x80, &p));
        assert_eq!(e.event_type, TelemetryEventType::Steps);
        assert_eq!(e.payload["step_count"], 5000);
        assert_eq!(e.payload["calories"], 250);
        assert_eq!(e.payload["distance_m"], 3500);
        assert_eq!(e.payload["active_min"], 45);
        assert!(e.payload["timestamp"].is_string());
    }

    #[test]
    fn sleep_records() {
        // Deep sleep marker at ts.
        let mut p = vec![0x01, 0x00];
        p.extend_from_slice(&1_792_972_800u32.to_le_bytes());
        p.push(0x00);
        let e = only(&frame(0x56, 0x80, &p));
        assert_eq!(e.event_type, TelemetryEventType::Sleep);
        assert_eq!(e.payload["sleep_stage"], "deep");
        assert_eq!(e.payload["stage_code"], 0);
        assert!(e.payload["start_time"].is_string());
        assert!(e.payload["end_time"].is_null());

        // End marker → end_time carries the wake time (code 17 ; 18 est
        // la variante de fin fusionnée côté app officielle).
        let mut p2 = vec![0x02, 0x00];
        p2.extend_from_slice(&1_792_976_400u32.to_le_bytes());
        p2.push(17);
        let e2 = only(&frame(0x56, 0x80, &p2));
        assert_eq!(e2.payload["sleep_stage"], "end");
        assert_eq!(e2.payload["stage_code"], 11);
        assert!(e2.payload["start_time"].is_null());
        assert!(e2.payload["end_time"].is_string());
    }

    #[test]
    fn button_events_resolve_map() {
        // Live 0x2E map: up→1 dim, bottom→6 camera, crown-short→4 music,
        // crown-long→6 camera.
        let map = [(1u8, 1u8), (2, 6), (3, 4), (4, 6)];

        // Camera event 0xD1 → function 6 → ambiguous (buttons 2 and 4).
        let e = only_with(&[0x6F, 0xD1, 0x71, 0x01, 0x00, 0x00, 0x8F], &map);
        assert_eq!(e.event_type, TelemetryEventType::Button);
        assert_eq!(e.payload["action"], "camera");
        assert_eq!(e.payload["opcode"], "0xD1");
        assert_eq!(e.payload["function"], 6);
        assert!(e.payload["button_id"].is_null());
        assert_eq!(e.payload["button_candidates"], json!([2, 4]));
        assert!(e.payload["press_type"].is_null());

        // Music next → function 4 → unique button 3.
        let e = only_with(&[0x6F, 0xD0, 0x71, 0x01, 0x00, 0x03, 0x8F], &map);
        assert_eq!(e.payload["action"], "next");
        assert_eq!(e.payload["button_id"], 3);
        assert_eq!(e.payload["button_candidates"], json!([]));

        // Crown volume → function 4 → button 3, level carried.
        let e = only_with(&[0x6F, 0xD0, 0x71, 0x02, 0x00, 0x04, 60, 0x8F], &map);
        assert_eq!(e.payload["action"], "volume");
        assert_eq!(e.payload["level"], 60);
        assert_eq!(e.payload["button_id"], 3);

        // SOS → no function → no resolution.
        let e = only_with(&[0x6F, 0xD9, 0x71, 0x01, 0x00, 0x00, 0x8F], &map);
        assert_eq!(e.payload["action"], "sos");
        assert!(e.payload["function"].is_null());
        assert!(e.payload["button_id"].is_null());

        // Quick reply keeps its raw payload as hex.
        let e = only_with(&[0x6F, 0xDD, 0x71, 0x02, 0x00, 0x0D, 0x03, 0x8F], &map);
        assert_eq!(e.payload["action"], "quick_reply");
        assert_eq!(e.payload["data_hex"], "0D03");
    }

    fn only_with(frame_bytes: &[u8], buttons: &[(u8, u8)]) -> TelemetryEvent {
        let events = events_from_frame(frame_bytes, NOW, OFFSET, buttons);
        assert_eq!(events.len(), 1);
        events.into_iter().next().unwrap()
    }

    #[test]
    fn non_telemetry_frames_yield_nothing() {
        // Music state request: navigation, not a press.
        assert!(
            events_from_frame(
                &[0x6F, 0xD0, 0x80, 0x01, 0x00, 0x00, 0x8F],
                NOW,
                OFFSET,
                &[]
            )
            .is_empty()
        );
        // Ack.
        assert!(
            events_from_frame(
                &[0x6F, 0x01, 0x81, 0x02, 0x00, 0x04, 0x00, 0x8F],
                NOW,
                OFFSET,
                &[]
            )
            .is_empty()
        );
        // Setting reply.
        assert!(
            events_from_frame(
                &[0x6F, 0x25, 0x80, 0x02, 0x00, 0x0A, 0x00, 0x8F],
                NOW,
                OFFSET,
                &[]
            )
            .is_empty()
        );
        // Garbage.
        assert!(events_from_frame(&[0xDE, 0xAD, 0xBE, 0xEF], NOW, OFFSET, &[]).is_empty());
        // Truncated frame.
        assert!(events_from_frame(&[0x6F, 0x08, 0x80], NOW, OFFSET, &[]).is_empty());
    }

    #[test]
    fn from_json_parts_validates() {
        let e = TelemetryEvent::from_json_parts(
            TelemetryEventType::BleStatus,
            1234,
            "{\"rssi\":-55,\"state\":\"connected\"}",
        )
        .unwrap();
        assert_eq!(e.event_type, TelemetryEventType::BleStatus);
        assert_eq!(
            e.to_json(),
            "{\"timestamp\":1234,\"event_type\":\"ble_status\",\"payload\":{\"rssi\":-55,\"state\":\"connected\"}}"
        );
        assert!(TelemetryEvent::from_json_parts(TelemetryEventType::BleStatus, 1, "[1]").is_err());
        assert!(TelemetryEvent::from_json_parts(TelemetryEventType::BleStatus, 1, "{").is_err());
    }

    #[test]
    fn type_names_match_serde() {
        for t in [
            TelemetryEventType::Battery,
            TelemetryEventType::HeartRate,
            TelemetryEventType::Steps,
            TelemetryEventType::Sleep,
            TelemetryEventType::BleStatus,
            TelemetryEventType::Button,
            TelemetryEventType::Inactivity,
        ] {
            let e = TelemetryEvent::new(t, 0, json!({}));
            let parsed: Value = serde_json::from_str(&e.to_json()).unwrap();
            assert_eq!(parsed["event_type"], t.as_str());
        }
    }
}
