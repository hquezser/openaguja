//! UniFFI bindings for the ZeTime wire protocol (iOS Swift app).
//!
//! Exposes frame encode/decode, chunking and reassembly without the CLI's
//! BLE/tokio dependencies — the app drives CoreBluetooth itself.

use std::fmt;
use std::sync::{Arc, Mutex};

use chrono::{DateTime, FixedOffset, TimeZone};
use openaguja::protocol::parse::{MusicCommand, WatchEvent};
use openaguja::protocol::{self, Command, ProtocolError, Response};

uniffi::setup_scaffolding!();

mod commands;
pub use commands::*;
mod telemetry;
pub use telemetry::*;

// ---------------------------------------------------------------------------
// Error
// ---------------------------------------------------------------------------

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum ZeTimeError {
    InvalidFrame(String),
    InvalidValue(String),
    Unsupported(String),
    PayloadTooLong(String),
}

impl fmt::Display for ZeTimeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidFrame(m)
            | Self::InvalidValue(m)
            | Self::Unsupported(m)
            | Self::PayloadTooLong(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for ZeTimeError {}

impl From<ProtocolError> for ZeTimeError {
    fn from(e: ProtocolError) -> Self {
        let msg = e.to_string();
        match e {
            ProtocolError::InvalidFrame(_) => Self::InvalidFrame(msg),
            ProtocolError::InvalidValue(_) => Self::InvalidValue(msg),
            ProtocolError::Unsupported(_) => Self::Unsupported(msg),
            ProtocolError::PayloadTooLong(_) => Self::PayloadTooLong(msg),
        }
    }
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Mirror of `protocol::NotificationKind` (notification category icons).
#[derive(Debug, Clone, Copy, uniffi::Enum)]
pub enum NotificationKind {
    MissedCall,
    Sms,
    Social,
    Email,
    Calendar,
    WeChat,
    Viber,
    Snapchat,
    WhatsApp,
    Qq,
    Facebook,
    Hangouts,
    Gmail,
    Messenger,
    Instagram,
    Twitter,
    LinkedIn,
    Uber,
    Line,
    Skype,
}

impl From<NotificationKind> for protocol::NotificationKind {
    fn from(k: NotificationKind) -> Self {
        use protocol::NotificationKind as K;
        match k {
            NotificationKind::MissedCall => K::MissedCall,
            NotificationKind::Sms => K::Sms,
            NotificationKind::Social => K::Social,
            NotificationKind::Email => K::Email,
            NotificationKind::Calendar => K::Calendar,
            NotificationKind::WeChat => K::WeChat,
            NotificationKind::Viber => K::Viber,
            NotificationKind::Snapchat => K::Snapchat,
            NotificationKind::WhatsApp => K::WhatsApp,
            NotificationKind::Qq => K::Qq,
            NotificationKind::Facebook => K::Facebook,
            NotificationKind::Hangouts => K::Hangouts,
            NotificationKind::Gmail => K::Gmail,
            NotificationKind::Messenger => K::Messenger,
            NotificationKind::Instagram => K::Instagram,
            NotificationKind::Twitter => K::Twitter,
            NotificationKind::LinkedIn => K::LinkedIn,
            NotificationKind::Uber => K::Uber,
            NotificationKind::Line => K::Line,
            NotificationKind::Skype => K::Skype,
        }
    }
}

/// An action the user triggered on the watch (music controls, call reject,
/// camera remote, find-phone, SOS, quick reply).
#[derive(Debug, Clone, uniffi::Enum)]
pub enum WatchAction {
    Play,
    Pause,
    Previous,
    Next,
    Volume {
        level: u8,
    },
    CallRejected,
    /// 0xD1 — camera-remote screen tap (watch runs a 3→1 countdown).
    Camera,
    /// 0xD2 — "find my phone" screen.
    FindPhone,
    /// 0xD9 — SOS trigger.
    Sos,
    /// 0xE8 — button `button` (1–6) of the "Remote" app added by the
    /// community `page4` firmware patch. Stock firmware never sends it; no
    /// ack expected. Routed as `remote_1`…`remote_6`.
    RemoteButton {
        button: u8,
    },
    /// Quick reply to a notification (0xDD SMS / 0xE6 social selection,
    /// 0xDE content follow-up). `text` is the best locally-resolved reply
    /// string: 0xDE content, else the emoji face — the app resolves
    /// `preset_crc` against the 0xDA/0xDB list when present. iOS cannot
    /// inject the reply into the originating app's notification — forward
    /// it to the webhook/macDaemon/Shortcuts targets.
    QuickReply {
        /// Event opcode: 0xDD SMS / 0xE6 social / 0xDE content.
        opcode: u8,
        /// Resolved reply text ("" when nothing decodable).
        text: String,
        /// CRC of the watch-stored preset picked (0xDA/0xDB identity).
        preset_crc: Option<u16>,
        /// Emoji face picked on the watch's keyboard ("" if none).
        face: String,
        /// SMS sender name/number (0xDD only).
        sender: Option<String>,
        /// Notification CRC correlating to the triggering notification
        /// (0xE6 only).
        notification_crc: Option<u16>,
        /// 0xDE follow-up content frame.
        is_content: bool,
        /// Raw payload for the journal/debug panel.
        raw: Vec<u8>,
    },
}

/// A decoded frame received from the watch.
#[derive(Debug, uniffi::Enum)]
pub enum WatchFrame {
    Battery {
        level: u8,
    },
    /// Return-code ack for a previous command (status 0 = OK, 1 = NOK).
    Ack {
        cmd: u8,
        status: u8,
    },
    /// Watch-initiated event (0x8004): music controls and call reject.
    Action {
        action: WatchAction,
    },
    /// The watch wants the phone's music state; `source` = the player picked
    /// on the watch's music screen (0=Apple Music, 1=Spotify, 2=Deezer).
    MusicStateRequest {
        source: u8,
    },
    /// Unrecognized music-control code.
    UnknownMusic {
        code: u8,
    },
    /// 0xE2 — real-time heart-rate push from the watch `[bpm:1]`.
    RealTimeHeartRate {
        bpm: u8,
    },
    /// Any other well-formed frame.
    Other {
        cmd: u8,
        kind: u8,
        payload: Vec<u8>,
    },
}

/// 16-bit GATT UUIDs — `CBUUID(string:)` accepts short strings.
#[derive(uniffi::Record)]
pub struct GattUuids {
    /// Service UUIDs to scan for ("6006" base, "7006" extend).
    pub services: Vec<String>,
    /// Write characteristic (frames go here, chunked ≤ 20 bytes).
    pub tx: String,
    /// Write the ack byte here after each frame sent.
    pub ack: String,
    /// Replies to REQUEST frames (subscribe).
    pub reply: String,
    /// Watch-initiated events (subscribe).
    pub notify: String,
}

// ---------------------------------------------------------------------------
// Constants / helpers
// ---------------------------------------------------------------------------

#[uniffi::export]
pub fn gatt_uuids() -> GattUuids {
    GattUuids {
        services: vec!["6006".into(), "7006".into()],
        tx: "8001".into(),
        ack: "8002".into(),
        reply: "8003".into(),
        notify: "8004".into(),
    }
}

/// Byte to write on the ACK characteristic after each frame sent.
#[uniffi::export]
pub fn ack_byte() -> u8 {
    protocol::CMD_ACK_WRITE
}

/// Split a frame into ≤20-byte chunks for the TX characteristic.
#[uniffi::export]
pub fn chunk_frame(frame: Vec<u8>) -> Vec<Vec<u8>> {
    protocol::chunks(&frame).map(|c| c.to_vec()).collect()
}

/// Decode a complete frame received from the watch: watch events first
/// (music controls, call reject), then REQUEST replies.
#[uniffi::export]
pub fn decode_frame(frame: Vec<u8>) -> Result<WatchFrame, ZeTimeError> {
    if let Some(event) = protocol::parse::parse_watch_event(&frame) {
        return Ok(match event {
            WatchEvent::Music(cmd) => match cmd {
                MusicCommand::Play => WatchFrame::Action {
                    action: WatchAction::Play,
                },
                MusicCommand::Pause => WatchFrame::Action {
                    action: WatchAction::Pause,
                },
                MusicCommand::Previous => WatchFrame::Action {
                    action: WatchAction::Previous,
                },
                MusicCommand::Next => WatchFrame::Action {
                    action: WatchAction::Next,
                },
                MusicCommand::Volume(level) => WatchFrame::Action {
                    action: WatchAction::Volume { level },
                },
                MusicCommand::Unknown(code) => WatchFrame::UnknownMusic { code },
            },
            WatchEvent::MusicStateRequest(source) => WatchFrame::MusicStateRequest { source },
            WatchEvent::CallRejected => WatchFrame::Action {
                action: WatchAction::CallRejected,
            },
            WatchEvent::Camera => WatchFrame::Action {
                action: WatchAction::Camera,
            },
            WatchEvent::FindPhone => WatchFrame::Action {
                action: WatchAction::FindPhone,
            },
            WatchEvent::Sos => WatchFrame::Action {
                action: WatchAction::Sos,
            },
            WatchEvent::RemoteButton(button) => WatchFrame::Action {
                action: WatchAction::RemoteButton { button },
            },
            WatchEvent::QuickReply(ev) => WatchFrame::Action {
                action: WatchAction::QuickReply {
                    opcode: ev.opcode,
                    text: ev
                        .content
                        .clone()
                        .or_else(|| ev.face.clone().into())
                        .unwrap_or_default(),
                    preset_crc: ev.preset_crc,
                    face: ev.face,
                    sender: ev.sender,
                    notification_crc: ev.notification_crc,
                    is_content: ev.opcode == protocol::CMD_SMS_REPLY_CONTENT,
                    raw: ev.raw,
                },
            },
            WatchEvent::RealTimeHeartRate { bpm } => WatchFrame::RealTimeHeartRate { bpm },
        });
    }
    Ok(match protocol::decode(&frame)? {
        Response::Battery { level } => WatchFrame::Battery { level },
        Response::Ack { cmd, status } => WatchFrame::Ack { cmd, status },
        Response::Other { cmd, kind, payload } => WatchFrame::Other { cmd, kind, payload },
    })
}

/// Stable id for a watch action (used by the iOS app to route events).
#[uniffi::export]
pub fn watch_action_id(action: WatchAction) -> String {
    match action {
        WatchAction::Play => "play",
        WatchAction::Pause => "pause",
        WatchAction::Previous => "previous",
        WatchAction::Next => "next",
        WatchAction::Volume { .. } => "volume",
        WatchAction::CallRejected => "call_rejected",
        WatchAction::Camera => "camera",
        WatchAction::FindPhone => "find_phone",
        WatchAction::Sos => "sos",
        WatchAction::QuickReply { .. } => "quick_reply",
        WatchAction::RemoteButton { button } => {
            openaguja::protocol::parse::remote_action_id(button).unwrap_or("remote")
        }
    }
    .to_string()
}

/// Human-readable name for a command byte.
#[uniffi::export]
pub fn command_name(cmd: u8) -> String {
    protocol::command_name(cmd).to_string()
}

/// Hex dump ("6F 04 71 …"), for logging/debug.
#[uniffi::export]
pub fn to_hex(bytes: Vec<u8>) -> String {
    protocol::to_hex(&bytes)
}

// ---------------------------------------------------------------------------
// Encoders
// ---------------------------------------------------------------------------

fn fixed_datetime(
    unix_seconds: i64,
    utc_offset_seconds: i32,
) -> Result<DateTime<FixedOffset>, ZeTimeError> {
    let offset = FixedOffset::east_opt(utc_offset_seconds).ok_or_else(|| {
        ZeTimeError::InvalidValue(format!(
            "utc offset {utc_offset_seconds}s out of range (±24h)"
        ))
    })?;
    offset
        .timestamp_opt(unix_seconds, 0)
        .single()
        .ok_or_else(|| {
            ZeTimeError::InvalidValue(format!("unix timestamp {unix_seconds} out of range"))
        })
}

fn encode(cmd: &Command, now: chrono::NaiveDateTime) -> Result<Vec<u8>, ZeTimeError> {
    cmd.encode(now).map_err(ZeTimeError::from)
}

/// Sync the watch's date/time to `unix_seconds` wall-clock in the given UTC
/// offset (e.g. offset +3600 → the watch displays unix_seconds+3600 local).
#[uniffi::export]
pub fn encode_set_time(unix_seconds: i64, utc_offset_seconds: i32) -> Result<Vec<u8>, ZeTimeError> {
    let dt = fixed_datetime(unix_seconds, utc_offset_seconds)?;
    encode(&Command::SetTime(dt), dt.naive_local())
}

/// Push a notification. The frame's timestamp is the local wall time of
/// `unix_seconds` in `utc_offset_seconds`.
#[uniffi::export]
pub fn encode_notification(
    kind: NotificationKind,
    title: String,
    body: String,
    unix_seconds: i64,
    utc_offset_seconds: i32,
) -> Result<Vec<u8>, ZeTimeError> {
    let dt = fixed_datetime(unix_seconds, utc_offset_seconds)?;
    encode(
        &Command::SendNotification {
            kind: kind.into(),
            title,
            body,
        },
        dt.naive_local(),
    )
}

/// Show an incoming-call screen with the caller's name/number.
#[uniffi::export]
pub fn encode_incoming_call(
    caller: String,
    unix_seconds: i64,
    utc_offset_seconds: i32,
) -> Result<Vec<u8>, ZeTimeError> {
    let dt = fixed_datetime(unix_seconds, utc_offset_seconds)?;
    encode(&Command::IncomingCall { caller }, dt.naive_local())
}

/// Dismiss the call screen (call ended/missed).
#[uniffi::export]
pub fn encode_call_ended(
    unix_seconds: i64,
    utc_offset_seconds: i32,
) -> Result<Vec<u8>, ZeTimeError> {
    let dt = fixed_datetime(unix_seconds, utc_offset_seconds)?;
    encode(&Command::CallEnded, dt.naive_local())
}

/// Start/stop the phone-finder buzzer on the watch.
#[uniffi::export]
pub fn encode_find_device(start: bool) -> Result<Vec<u8>, ZeTimeError> {
    encode(
        &Command::FindDevice { start },
        chrono::NaiveDateTime::default(),
    )
}

/// Request the battery level (answer comes on the reply characteristic).
#[uniffi::export]
pub fn encode_get_battery() -> Result<Vec<u8>, ZeTimeError> {
    encode(&Command::GetBattery, chrono::NaiveDateTime::default())
}

/// Music state + track title for the watch's music screen. Written on the
/// reply characteristic (0x8003), chunked, WITHOUT the ack byte — answers its
/// music-state request and follows player changes.
#[uniffi::export]
pub fn encode_music_info(playing: bool, title: String) -> Result<Vec<u8>, ZeTimeError> {
    encode(
        &Command::MusicInfo { playing, title },
        chrono::NaiveDateTime::default(),
    )
}

/// Music volume echo on the reply characteristic (0x8003), no ack byte —
/// init at connect and after each watch volume button event.
#[uniffi::export]
pub fn encode_music_volume(level: u8) -> Result<Vec<u8>, ZeTimeError> {
    encode(
        &Command::MusicVolume(level),
        chrono::NaiveDateTime::default(),
    )
}

/// Generic ack for watch-initiated events (0xD1 camera, 0xD2 find-phone,
/// 0xD9 SOS, 0xDD quick reply): the watch blocks on it — camera shows
/// "connection failed" without one. Written on the reply characteristic
/// (0x8003) via the sendReply path, chunked, WITHOUT the ack byte.
#[uniffi::export]
pub fn encode_generic_ack(echoed_cmd: u8) -> Result<Vec<u8>, ZeTimeError> {
    encode(
        &Command::GenericAck {
            echoed_cmd,
            status: 0,
        },
        chrono::NaiveDateTime::default(),
    )
}

/// Reassign a physical watch button (0x2E): `button` 1=UP, 2=BOTTOM,
/// 3=OTS_SHORT (crown tap), 4=OTS_LONG (crown hold); `function` 0-19 —
/// 1 dim screen, 4 music control, 6 camera, 16 find my phone (full table
/// in the protocol reference). NOT live-confirmed yet. Written on TX
/// (0x8001) with the ack byte, i.e. the normal send path, NOT sendReply.
#[uniffi::export]
pub fn encode_set_button_function(button: u8, function: u8) -> Result<Vec<u8>, ZeTimeError> {
    encode(
        &Command::SetButtonFunction { button, function },
        chrono::NaiveDateTime::default(),
    )
}

// ---------------------------------------------------------------------------
// Reassembler
// ---------------------------------------------------------------------------

/// Collects raw notify/reply chunks into complete frames. The app feeds
/// every CoreBluetooth characteristic value; each returned item is one
/// complete frame for `decode_frame`.
#[derive(uniffi::Object)]
pub struct FrameReassembler {
    inner: Mutex<protocol::Reassembler>,
}

#[uniffi::export]
impl FrameReassembler {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(protocol::Reassembler::new()),
        })
    }

    /// Feed a chunk; returns every complete frame it finished.
    pub fn push(&self, chunk: Vec<u8>) -> Vec<Vec<u8>> {
        self.inner
            .lock()
            .expect("reassembler poisoned")
            .push(&chunk)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    const UNIX: i64 = 1_792_972_800; // 2026-10-26T00:00:00Z → 01:00 local at +1h
    const OFFSET: i32 = 3600;

    #[test]
    fn set_time_matches_core() {
        let frame = encode_set_time(UNIX, OFFSET).unwrap();
        let dt = FixedOffset::east_opt(OFFSET)
            .unwrap()
            .timestamp_opt(UNIX, 0)
            .unwrap();
        let expected = Command::SetTime(dt).encode(dt.naive_local()).unwrap();
        assert_eq!(frame, expected);
        // 2026-10-26 01:00 local: year 2026 LE, month 10, day 26, hour 1, tz +1
        assert_eq!(
            &frame[5..17],
            &[
                0xEA, 0x07, 0x0A, 0x1A, 0x01, 0x00, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00
            ]
        );
    }

    #[test]
    fn set_time_bad_offset() {
        assert!(matches!(
            encode_set_time(UNIX, 200_000),
            Err(ZeTimeError::InvalidValue(_))
        ));
        assert!(matches!(
            encode_set_time(UNIX, -200_000),
            Err(ZeTimeError::InvalidValue(_))
        ));
    }

    #[test]
    fn notification_uses_local_timestamp() {
        let frame = encode_notification(
            NotificationKind::Sms,
            "Rappel".into(),
            "Réunion".into(),
            UNIX,
            OFFSET,
        )
        .unwrap();
        let needle = b"20261026T010000";
        assert!(
            frame.windows(needle.len()).any(|w| w == needle),
            "local timestamp missing: {}",
            protocol::to_hex(&frame)
        );
    }

    #[test]
    fn decode_events() {
        // Music next (real capture on 0x8004)
        assert!(matches!(
            decode_frame(vec![0x6F, 0xD0, 0x71, 0x01, 0x00, 0x03, 0x8F]).unwrap(),
            WatchFrame::Action {
                action: WatchAction::Next
            }
        ));
        // Volume 60
        assert!(matches!(
            decode_frame(vec![0x6F, 0xD0, 0x71, 0x02, 0x00, 0x04, 60, 0x8F]).unwrap(),
            WatchFrame::Action {
                action: WatchAction::Volume { level: 60 }
            }
        ));
        // Music state request
        assert!(matches!(
            decode_frame(vec![0x6F, 0xD0, 0x80, 0x01, 0x00, 0x00, 0x8F]).unwrap(),
            WatchFrame::MusicStateRequest { source: 0 }
        ));
        // Battery level 6
        assert!(matches!(
            decode_frame(vec![0x6F, 0x08, 0x80, 0x01, 0x00, 0x06, 0x8F]).unwrap(),
            WatchFrame::Battery { level: 6 }
        ));
        // Camera remote tap (payload 0x00)
        assert!(matches!(
            decode_frame(vec![0x6F, 0xD1, 0x71, 0x01, 0x00, 0x00, 0x8F]).unwrap(),
            WatchFrame::Action {
                action: WatchAction::Camera
            }
        ));
        // Patched-firmware Remote button 3
        assert!(matches!(
            decode_frame(vec![0x6F, 0xE8, 0x71, 0x01, 0x00, 0x03, 0x8F]).unwrap(),
            WatchFrame::Action {
                action: WatchAction::RemoteButton { button: 3 }
            }
        ));
        // Find-phone (payload byte undocumented)
        assert!(matches!(
            decode_frame(vec![0x6F, 0xD2, 0x71, 0x01, 0x00, 0x01, 0x8F]).unwrap(),
            WatchFrame::Action {
                action: WatchAction::FindPhone
            }
        ));
        // SOS
        assert!(matches!(
            decode_frame(vec![0x6F, 0xD9, 0x71, 0x01, 0x00, 0x00, 0x8F]).unwrap(),
            WatchFrame::Action {
                action: WatchAction::Sos
            }
        ));
        // Quick reply: decoded event fields + raw kept
        assert!(matches!(
            decode_frame(vec![0x6F, 0xDD, 0x71, 0x02, 0x00, 0x0D, 0x03, 0x8F]).unwrap(),
            WatchFrame::Action {
                action: WatchAction::QuickReply { .. }
            }
        ));
        // Real-time heart-rate push (live frame: 6F E2 71 01 00 31 8F)
        assert!(matches!(
            decode_frame(vec![0x6F, 0xE2, 0x71, 0x01, 0x00, 0x31, 0x8F]).unwrap(),
            WatchFrame::RealTimeHeartRate { bpm: 0x31 }
        ));
        // Ack cmd 0x04 status 0
        assert!(matches!(
            decode_frame(vec![0x6F, 0x01, 0x81, 0x02, 0x00, 0x04, 0x00, 0x8F]).unwrap(),
            WatchFrame::Ack {
                cmd: 0x04,
                status: 0x00
            }
        ));
        // Garbage
        assert!(matches!(
            decode_frame(vec![0xDE, 0xAD, 0xBE, 0xEF]),
            Err(ZeTimeError::InvalidFrame(_))
        ));
    }

    #[test]
    fn reassembler_multi_chunk() {
        // Same 39-byte frame as the core test, pushed 20+19
        let frame = [
            0x6F, 0x76, 0x71, 0x21, 0x00, 0x02, 0x01, 0x06, 0x08, b'R', b'a', b'p', b'p', b'e',
            b'l', 0x52, 0xC3, 0xA9, 0x75, 0x6E, 0x69, 0x6F, 0x6E, b'2', b'0', b'2', b'6', b'1',
            b'0', b'2', b'6', b'T', b'1', b'7', b'3', b'0', b'4', b'5', 0x8F,
        ];
        let r = FrameReassembler::new();
        assert!(r.push(frame[..20].to_vec()).is_empty());
        assert_eq!(r.push(frame[20..].to_vec()), vec![frame.to_vec()]);
    }

    #[test]
    fn chunking() {
        let frame = encode_notification(
            NotificationKind::Sms,
            "A".repeat(10),
            "B".repeat(10),
            UNIX,
            OFFSET,
        )
        .unwrap();
        assert_eq!(frame.len(), 45);
        let chunks = chunk_frame(frame);
        assert_eq!(
            chunks.iter().map(|c| c.len()).collect::<Vec<_>>(),
            [20, 20, 5]
        );
    }

    #[test]
    fn music_reply_encoders() {
        // GB replyMsgToWatch: type 0x80 sur 0x8003, sans octet ack
        assert_eq!(
            encode_music_info(true, "Source".into()).unwrap(),
            [
                0x6F, 0xD0, 0x80, 0x07, 0x00, 0x00, b'S', b'o', b'u', b'r', b'c', b'e', 0x8F
            ]
        );
        assert_eq!(
            encode_music_info(false, "Source".into()).unwrap()[5],
            0x01 // state : pause
        );
        assert_eq!(
            encode_music_volume(50).unwrap(),
            [0x6F, 0xD0, 0x80, 0x02, 0x00, 0x02, 50, 0x8F]
        );
        // Ack générique (0x01/0x81) renvoyé à la montre après ses événements
        assert_eq!(
            encode_generic_ack(0xD1).unwrap(),
            [0x6F, 0x01, 0x81, 0x02, 0x00, 0xD1, 0x00, 0x8F]
        );
        // Bouton UP (1) → camera (6)
        assert_eq!(
            encode_set_button_function(1, 6).unwrap(),
            [0x6F, 0x2E, 0x71, 0x03, 0x00, 0x02, 0x01, 0x06, 0x8F]
        );
    }

    #[test]
    fn action_ids() {
        assert_eq!(watch_action_id(WatchAction::Play), "play");
        assert_eq!(watch_action_id(WatchAction::Pause), "pause");
        assert_eq!(watch_action_id(WatchAction::Previous), "previous");
        assert_eq!(watch_action_id(WatchAction::Next), "next");
        assert_eq!(watch_action_id(WatchAction::Volume { level: 42 }), "volume");
        assert_eq!(watch_action_id(WatchAction::CallRejected), "call_rejected");
        assert_eq!(watch_action_id(WatchAction::Camera), "camera");
        assert_eq!(watch_action_id(WatchAction::FindPhone), "find_phone");
        assert_eq!(
            watch_action_id(WatchAction::RemoteButton { button: 1 }),
            "remote_1"
        );
        assert_eq!(
            watch_action_id(WatchAction::RemoteButton { button: 6 }),
            "remote_6"
        );
        assert_eq!(watch_action_id(WatchAction::Sos), "sos");
        assert_eq!(
            watch_action_id(WatchAction::QuickReply {
                opcode: 0xDD,
                text: String::new(),
                preset_crc: None,
                face: String::new(),
                sender: None,
                notification_crc: None,
                is_content: false,
                raw: vec![],
            }),
            "quick_reply"
        );
    }
}
