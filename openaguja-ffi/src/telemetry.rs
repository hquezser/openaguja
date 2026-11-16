//! Telemetry surface: raw watch frames → `TelemetryEvent` records whose
//! canonical JSON is uploaded to the configured telemetry endpoint.
//!
//! The app feeds every complete frame from `FrameReassembler` to
//! [`decode_telemetry_events`]; phone-generated events (`ble_status`)
//! are built as [`TelemetryEvent`] records directly and serialized with
//! [`telemetry_event_json`].

use openaguja::telemetry::{self, TelemetryEvent as CoreEvent, TelemetryEventType};

use crate::commands::ButtonFunction;
use crate::{ZeTimeError, encode};
use chrono::NaiveDateTime;
use openaguja::protocol::Command;

/// Event categories of the telemetry upload schema (snake_case on the wire).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
pub enum TelemetryEventKind {
    Battery,
    HeartRate,
    Steps,
    Sleep,
    BleStatus,
    Button,
    Inactivity,
}

impl From<TelemetryEventType> for TelemetryEventKind {
    fn from(t: TelemetryEventType) -> Self {
        match t {
            TelemetryEventType::Battery => Self::Battery,
            TelemetryEventType::HeartRate => Self::HeartRate,
            TelemetryEventType::Steps => Self::Steps,
            TelemetryEventType::Sleep => Self::Sleep,
            TelemetryEventType::BleStatus => Self::BleStatus,
            TelemetryEventType::Button => Self::Button,
            TelemetryEventType::Inactivity => Self::Inactivity,
        }
    }
}

impl From<TelemetryEventKind> for TelemetryEventType {
    fn from(k: TelemetryEventKind) -> Self {
        match k {
            TelemetryEventKind::Battery => Self::Battery,
            TelemetryEventKind::HeartRate => Self::HeartRate,
            TelemetryEventKind::Steps => Self::Steps,
            TelemetryEventKind::Sleep => Self::Sleep,
            TelemetryEventKind::BleStatus => Self::BleStatus,
            TelemetryEventKind::Button => Self::Button,
            TelemetryEventKind::Inactivity => Self::Inactivity,
        }
    }
}

/// One telemetry document. `payload_json` is the raw JSON object text of
/// the event payload — `telemetry_event_json` validates and embeds it.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TelemetryEvent {
    /// Unix seconds — phone receipt time.
    pub timestamp: u64,
    pub event_type: TelemetryEventKind,
    pub payload_json: String,
}

/// Decode every telemetry event carried by one complete watch frame
/// (battery replies, stored steps/sleep/heart-rate records, live `0xE2`
/// pushes and watch action events). Returns an empty list for acks,
/// setting replies and undecodable frames.
///
/// `now_unix`/`utc_offset_seconds` stamp phone-side times (live pushes);
/// `button_functions` is the current 0x2E button→function map used to
/// resolve `button_id` — pass an empty list when unknown.
#[uniffi::export]
pub fn decode_telemetry_events(
    frame: Vec<u8>,
    now_unix: i64,
    utc_offset_seconds: i32,
    button_functions: Vec<ButtonFunction>,
) -> Vec<TelemetryEvent> {
    let buttons: Vec<(u8, u8)> = button_functions
        .iter()
        .map(|b| (b.button, b.function))
        .collect();
    telemetry::events_from_frame(&frame, now_unix, utc_offset_seconds, &buttons)
        .into_iter()
        .map(|e| TelemetryEvent {
            timestamp: e.timestamp,
            event_type: TelemetryEventKind::from(e.event_type),
            payload_json: e.payload.to_string(),
        })
        .collect()
}

/// Canonical JSON document for the telemetry endpoint — exactly
/// `{"timestamp":…,"event_type":"…","payload":{…}}`. Fails when
/// `payload_json` is not a JSON object.
#[uniffi::export]
pub fn telemetry_event_json(event: TelemetryEvent) -> Result<String, ZeTimeError> {
    let core = CoreEvent::from_json_parts(
        TelemetryEventType::from(event.event_type),
        event.timestamp,
        &event.payload_json,
    )?;
    Ok(core.to_json())
}

/// Trigger a one-shot real-time heart-rate measurement
/// (`0x1A` CONTROL_DEVICE sub 3, decompiled SDK "jump real-time HR").
///
/// Caveat: on firmware A2.0.55 this sub-command produced no effect in live
/// tests — the app's `HeartRateService` drives on-demand cardio through the
/// `0x5C` interval instead (5-minute minimum, then restore). Kept for
/// completeness on firmwares where the jump works.
#[uniffi::export]
pub fn encode_heart_rate_measurement() -> Result<Vec<u8>, ZeTimeError> {
    encode(&Command::ControlDevice { sub: 3 }, NaiveDateTime::default())
}

/// Exit real-time heart-rate mode (`0x1A` CONTROL_DEVICE sub 15) —
/// counterpart of [`encode_heart_rate_measurement`], same A2.0.55 caveat.
#[uniffi::export]
pub fn encode_exit_heart_rate_measurement() -> Result<Vec<u8>, ZeTimeError> {
    encode(
        &Command::ControlDevice { sub: 15 },
        NaiveDateTime::default(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn decode_battery_to_json() {
        let events = decode_telemetry_events(
            vec![0x6F, 0x08, 0x80, 0x01, 0x00, 0x64, 0x8F],
            NOW,
            3600,
            vec![],
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, TelemetryEventKind::Battery);
        let json = telemetry_event_json(events[0].clone()).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["event_type"], "battery");
        assert_eq!(parsed["payload"]["level"], 100);
    }

    #[test]
    fn decode_button_with_map() {
        let events = decode_telemetry_events(
            vec![0x6F, 0xD1, 0x71, 0x01, 0x00, 0x00, 0x8F],
            NOW,
            3600,
            vec![
                ButtonFunction {
                    button: 2,
                    function: 6,
                },
                ButtonFunction {
                    button: 4,
                    function: 6,
                },
            ],
        );
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, TelemetryEventKind::Button);
        let json = telemetry_event_json(events[0].clone()).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["payload"]["action"], "camera");
        assert_eq!(
            parsed["payload"]["button_candidates"],
            serde_json::json!([2, 4])
        );
    }

    #[test]
    fn phone_side_event_json() {
        let event = TelemetryEvent {
            timestamp: 42,
            event_type: TelemetryEventKind::BleStatus,
            payload_json: "{\"state\":\"connected\",\"rssi\":-55}".into(),
        };
        let json = telemetry_event_json(event).unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed["timestamp"], 42);
        assert_eq!(parsed["event_type"], "ble_status");
        assert_eq!(parsed["payload"]["state"], "connected");
        assert_eq!(parsed["payload"]["rssi"], -55);
        // Non-object payload is rejected.
        let bad = TelemetryEvent {
            timestamp: 1,
            event_type: TelemetryEventKind::BleStatus,
            payload_json: "[1]".into(),
        };
        assert!(telemetry_event_json(bad).is_err());
    }

    #[test]
    fn heart_rate_encoders() {
        // 0x1A 0x71 [sub] — same shape as SetActivityTracking.
        assert_eq!(
            encode_heart_rate_measurement().unwrap(),
            vec![0x6F, 0x1A, 0x71, 0x01, 0x00, 0x03, 0x8F]
        );
        assert_eq!(
            encode_exit_heart_rate_measurement().unwrap(),
            vec![0x6F, 0x1A, 0x71, 0x01, 0x00, 0x0F, 0x8F]
        );
    }
}
