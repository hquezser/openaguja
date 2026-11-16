//! ZeTime wire protocol (frame encode/decode, chunking, reassembly).
//!
//! Frame format: `6F <cmd> <type> <len_lo> <len_hi> <payload…> 8F` where
//! `len` is the little-endian payload size, so a frame is `len + 6` bytes.
//! There is NO checksum in this protocol — Gadgetbridge's ZeTime support
//! doesn't use one either (see isMsgFormatOK / sendMsgToWatch in
//! ZeTimeDeviceSupport.java).

pub mod command;
pub mod parse;

pub use command::*;

use chrono::NaiveDateTime;
use std::fmt;

pub const CMD_PREAMBLE: u8 = 0x6F;
pub const CMD_END: u8 = 0x8F;

// Command ids (frame[1])
pub const CMD_RETURN_CODE: u8 = 0x01;
pub const CMD_WATCH_ID: u8 = 0x02;
pub const CMD_DEVICE_VERSION: u8 = 0x03;
pub const CMD_DATE_TIME: u8 = 0x04;
pub const CMD_TIME_SURFACE: u8 = 0x05;
pub const CMD_BATTERY_POWER: u8 = 0x08;
pub const CMD_SIGNALING: u8 = 0x0A;
pub const CMD_LANGUAGE: u8 = 0x0B;
pub const CMD_UPGRADE_MODE: u8 = 0x0E;
pub const CMD_TIMEZONE: u8 = 0x18;
pub const CMD_SHOCK_STRENGTH: u8 = 0x10;
pub const CMD_DO_NOT_DISTURB: u8 = 0x15;
pub const CMD_ANALOG_MODE: u8 = 0x17;
pub const CMD_ACTIVITY_TRACKING: u8 = 0x1A;
pub const CMD_SCREEN_TIME: u8 = 0x25;
pub const CMD_CUSTOMIZE_BUTTON: u8 = 0x2E;
pub const CMD_USER_INFO: u8 = 0x30;
pub const CMD_WRIST: u8 = 0x31;
pub const CMD_GOALS: u8 = 0x50;
pub const CMD_AVAILABLE_DATA: u8 = 0x52;
pub const CMD_DELETE_STEP_DATA: u8 = 0x53;
pub const CMD_STEP_DATA: u8 = 0x54;
pub const CMD_DELETE_SLEEP_DATA: u8 = 0x55;
pub const CMD_SLEEP_DATA: u8 = 0x56;
/// Fenêtre de détection auto-sleep `[enterH][enterM][exitH][exitM][cycle]`
/// (5 o — la référence la donne aussi comme brightness, mais le GET répond
/// un struct 5 o compatible ; sémantique inférée de l'app officielle,
/// pas encore confirmée sur hardware).
pub const CMD_AUTO_SLEEP_WINDOW: u8 = 0x58;
pub const CMD_DELETE_HEART_RATE_DATA: u8 = 0x5A;
pub const CMD_HEART_RATE_COUNT: u8 = 0x59;
pub const CMD_HEART_RATE_RECORD: u8 = 0x5B;
pub const CMD_HEART_RATE_INTERVAL: u8 = 0x5C;
pub const CMD_HEART_RATE_LIMITS: u8 = 0x5D;
pub const CMD_INACTIVITY: u8 = 0x5E;
pub const CMD_MOOD_DATA: u8 = 0x5F;
pub const CMD_SPORT_SLEEP_MODE: u8 = 0x51;
pub const CMD_SPORT_DATA_COUNT: u8 = 0x66;
pub const CMD_SPORT_SESSION_DATA: u8 = 0x67;
pub const CMD_WATCHFACE_DELETE: u8 = 0x1F;
pub const CMD_WATCHFACE_SET: u8 = 0x20;
pub const CMD_CALORIES_TYPE: u8 = 0x60;
pub const CMD_HEART_RATE_DATA: u8 = 0x61;
pub const CMD_PUSH_EX_MSG: u8 = 0x76;
pub const CMD_WEATHER: u8 = 0x77;
pub const CMD_SCREEN_BRIGHTNESS: u8 = 0x07;
pub const CMD_WATCH_VOLUME: u8 = 0x09;
pub const CMD_UNIT: u8 = 0x0C;
pub const CMD_BRIGHT_SCREEN_TIME: u8 = 0x13;
pub const CMD_SNOOZE: u8 = 0x14;
pub const CMD_TEXT_SIZE: u8 = 0x19;
pub const CMD_NIGHT_MODE: u8 = 0x21;
pub const CMD_BIND_START: u8 = 0x93;
pub const CMD_CALENDAR_MONTH_VIEW: u8 = 0x98;
pub const CMD_WATCH_MOVE_ONE: u8 = 0xB6;
pub const CMD_WATCH_MOVE_KEEP: u8 = 0xB8;
pub const CMD_DISPLAY_ON_MOVEMENT: u8 = 0x90;
pub const CMD_REMIND_COUNT: u8 = 0x91;
pub const CMD_REMINDERS: u8 = 0x97;
pub const CMD_CALENDAR: u8 = 0x99;
pub const CMD_MUSIC_CONTROL: u8 = 0xD0;
pub const CMD_TAKE_PHOTO: u8 = 0xD1;
pub const CMD_FIND_PHONE: u8 = 0xD2;
pub const CMD_SEND_SOS: u8 = 0xD9;
pub const CMD_CALL_CONTROL: u8 = 0xDC;
pub const CMD_SMS_REPLY: u8 = 0xDD;
pub const CMD_SMS_REPLY_CONTENT: u8 = 0xDE;
pub const CMD_SOCIAL_REPLY: u8 = 0xE6;
/// 0xD7 — undocumented watch→phone event opcode. Live-observed repeating
/// `6F D7 71 01 00 00 8F` (payload `[0x00]`); same firmware handler
/// family as the WATCH_MOVE_* opcodes (0xB6/0xD6, 0xB8/0xD8) — suspected
/// wrist/gesture notification. Not decoded into telemetry.
pub const CMD_WATCH_EVENT_D7: u8 = 0xD7;
/// 0x94 — `checkInit`/`init` : GET → `[initFlag]` ; SET `[0x00]` complète
/// l'init out-of-box (quitte l'écran QR → cadran) quand le flag de session
/// le permet — vérif. live post-factory-reset.
pub const CMD_INIT: u8 = 0x94;
/// 0xEE — absolute memory peek (lab only): read `len` bytes at `addr`.
/// Unsafe outside validated ranges (bus fault → boot hang, see RECOVERY.md).
pub const CMD_MEMORY_PEEK: u8 = 0xEE;
/// Quick-reply metadata reply (count + per-entry text CRC-16) — firmware
/// A2.0.55 quick-reply manager (region 0xA2000, verified by disassembly).
pub const CMD_QUICK_REPLY_META: u8 = 0xDA;
/// Quick-reply entries: GET streams `[index][crc:2le][text]` frames, SET
/// sub-commands insert/replace/delete entries.
pub const CMD_QUICK_REPLY: u8 = 0xDB;
pub const CMD_FIND_DEVICE: u8 = 0xFA;
/// 0xE2 — push cardio temps réel `[bpm:1]` (observé en live, SDK
/// `COMMAND_CODE_REAL_TIME_HEART_RATE`).
pub const CMD_REAL_TIME_HEART_RATE: u8 = 0xE2;

// Frame types (frame[2])
pub const CMD_REQUEST: u8 = 0x70;
pub const CMD_SEND: u8 = 0x71;
pub const CMD_REQUEST_RESPOND: u8 = 0x80;
/// Return-code frame type (watch → host ack on 0x8002).
pub const TYPE_RETURN_CODE: u8 = 0x81;
/// Written to the ACK characteristic after each frame to make the watch process it.
pub const CMD_ACK_WRITE: u8 = 0x03;

// Notification kinds (payload[0] of CMD_PUSH_EX_MSG) — see NotificationKind
// in command.rs for the full table; only the call pseudo-kinds live here.
pub const NOTIFICATION_INCOME_CALL: u8 = 0x05;
pub const NOTIFICATION_CALL_OFF: u8 = 0x06;

/// Frames are written to the TX characteristic in chunks of at most this
/// many bytes (Gadgetbridge `maxMsgLength`).
pub const MAX_CHUNK_LEN: usize = 20;

/// Quick-reply limits (firmware A2.0.55): 10 slots of 184 bytes each,
/// `len` field maxes at 180 — texts longer than this would overwrite
/// the next slot's header. Slot text is UTF-16LE, so 180 bytes = 90
/// UTF-16 code units.
pub const QUICK_REPLY_MAX_COUNT: u8 = 10;
pub const QUICK_REPLY_TEXT_MAX: usize = 180;

/// CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no
/// xorout) — quick-reply entries are addressed by this CRC of their
/// text bytes, so update/delete need it computed the same way.
pub fn crc16_ccitt(bytes: &[u8]) -> u16 {
    let mut crc = 0xFFFFu16;
    for &b in bytes {
        crc ^= (b as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    crc
}

#[derive(Debug)]
pub enum ProtocolError {
    Unsupported(&'static str),
    PayloadTooLong(usize),
    InvalidFrame(String),
    InvalidValue(String),
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unsupported(what) => write!(f, "unsupported command: {what}"),
            Self::PayloadTooLong(len) => {
                write!(f, "payload too long: {len} bytes (max {})", u16::MAX)
            }
            Self::InvalidFrame(why) => write!(f, "invalid frame: {why}"),
            Self::InvalidValue(why) => write!(f, "invalid value: {why}"),
        }
    }
}

impl std::error::Error for ProtocolError {}

pub(crate) fn frame(cmd: u8, kind: u8, payload: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    if payload.len() > u16::MAX as usize {
        return Err(ProtocolError::PayloadTooLong(payload.len()));
    }
    let len = payload.len() as u16;
    let mut frame = Vec::with_capacity(payload.len() + 6);
    frame.push(CMD_PREAMBLE);
    frame.push(cmd);
    frame.push(kind);
    frame.push((len & 0xFF) as u8);
    frame.push((len >> 8) as u8);
    frame.extend_from_slice(payload);
    frame.push(CMD_END);
    Ok(frame)
}

/// Truncate to at most `max` bytes on a UTF-8 char boundary.
pub(crate) fn truncate_utf8(s: &str, max: usize) -> &[u8] {
    let bytes = s.as_bytes();
    if bytes.len() <= max {
        return bytes;
    }
    let mut end = max;
    while !s.is_char_boundary(end) {
        end -= 1;
    }
    &bytes[..end]
}

/// "YYYYMMDDTHHMMSS" ASCII timestamp used by notifications/call events.
pub(crate) fn timestamp15(now: NaiveDateTime) -> [u8; 15] {
    // Always exactly 15 ASCII bytes.
    now.format("%Y%m%dT%H%M%S")
        .to_string()
        .as_bytes()
        .try_into()
        .unwrap()
}

/// Human-readable name for a command byte (for messages/errors).
pub fn command_name(cmd: u8) -> &'static str {
    match cmd {
        CMD_RETURN_CODE => "return code",
        CMD_WATCH_ID => "watch id",
        CMD_DEVICE_VERSION => "device version",
        CMD_DATE_TIME => "time sync",
        CMD_TIME_SURFACE => "time surface settings",
        CMD_BATTERY_POWER => "battery",
        CMD_SIGNALING => "signaling",
        CMD_LANGUAGE => "language",
        CMD_UPGRADE_MODE => "upgrade mode",
        CMD_TIMEZONE => "home timezone",
        CMD_SHOCK_STRENGTH => "shock strength",
        CMD_DO_NOT_DISTURB => "do not disturb",
        CMD_ANALOG_MODE => "analog mode",
        CMD_ACTIVITY_TRACKING => "activity tracking",
        CMD_SCREEN_TIME => "screen time",
        CMD_USER_INFO => "user info",
        CMD_WRIST => "wrist",
        CMD_GOALS => "goal",
        CMD_AVAILABLE_DATA => "available data",
        CMD_DELETE_STEP_DATA => "delete step data",
        CMD_STEP_DATA => "step data",
        CMD_DELETE_SLEEP_DATA => "delete sleep data",
        CMD_SLEEP_DATA => "sleep data",
        CMD_AUTO_SLEEP_WINDOW => "auto-sleep window",
        CMD_DELETE_HEART_RATE_DATA => "delete heart rate data",
        CMD_HEART_RATE_INTERVAL => "heart rate interval",
        CMD_HEART_RATE_LIMITS => "heart rate limits",
        CMD_INACTIVITY => "inactivity alert",
        CMD_WATCHFACE_DELETE => "watchface delete",
        CMD_WATCHFACE_SET => "customize watchface",
        CMD_CALORIES_TYPE => "calories type",
        CMD_HEART_RATE_DATA => "heart rate data",
        CMD_HEART_RATE_COUNT => "heart rate count",
        CMD_HEART_RATE_RECORD => "heart rate record",
        CMD_MOOD_DATA => "mood data",
        CMD_SPORT_SLEEP_MODE => "sport/sleep mode",
        CMD_SPORT_DATA_COUNT => "sport session count",
        CMD_SPORT_SESSION_DATA => "sport session data",
        CMD_REAL_TIME_HEART_RATE => "real-time heart rate",
        CMD_PUSH_EX_MSG => "notification",
        CMD_WEATHER => "weather",
        CMD_DISPLAY_ON_MOVEMENT => "switch setting",
        CMD_REMIND_COUNT => "alarm count",
        CMD_REMINDERS => "alarm",
        CMD_CALENDAR => "calendar",
        CMD_MUSIC_CONTROL => "music control",
        CMD_TAKE_PHOTO => "camera shutter",
        CMD_FIND_PHONE => "find phone",
        CMD_SEND_SOS => "sos",
        CMD_CALL_CONTROL => "call control",
        CMD_SMS_REPLY => "quick reply",
        CMD_INIT => "check init",
        CMD_MEMORY_PEEK => "memory peek",
        CMD_QUICK_REPLY_META => "quick reply list",
        CMD_QUICK_REPLY => "quick reply entry",
        CMD_CUSTOMIZE_BUTTON => "customize button",
        CMD_FIND_DEVICE => "find device",
        CMD_WATCH_EVENT_D7 => "watch event 0xD7",
        // Other undocumented watch→phone event opcodes (0x8004 pushes) —
        // raw hex stays in the journal; none are decoded into telemetry.
        0xD3..=0xD6 | 0xD8 | 0xDE..=0xE1 | 0xE6 => "watch event",
        _ => "unknown command",
    }
}

pub fn to_hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// Split a frame into ≤ `MAX_CHUNK_LEN` byte pieces for writing to the TX
/// characteristic (Gadgetbridge ZeTimeDeviceSupport.sendMsgToWatch).
pub fn chunks(frame: &[u8]) -> impl Iterator<Item = &[u8]> {
    frame.chunks(MAX_CHUNK_LEN)
}

#[derive(Debug, PartialEq, Eq)]
pub enum Response {
    Battery {
        level: u8,
    },
    /// Return-code frame: the watch acks a previous command
    /// (payload [acked cmd, status]; status 0x00 = OK, 0x01 = NOK).
    Ack {
        cmd: u8,
        status: u8,
    },
    Other {
        cmd: u8,
        kind: u8,
        payload: Vec<u8>,
    },
}

/// Validate and decode a complete frame (Gadgetbridge ZeTimeDeviceSupport.isMsgFormatOK).
pub fn decode(frame: &[u8]) -> Result<Response, ProtocolError> {
    if frame.len() < 7 {
        return Err(ProtocolError::InvalidFrame(format!(
            "too short: {} bytes (min 7)",
            frame.len()
        )));
    }
    if frame[0] != CMD_PREAMBLE {
        return Err(ProtocolError::InvalidFrame(format!(
            "bad preamble: {:#04X} (expected {CMD_PREAMBLE:#04X})",
            frame[0]
        )));
    }
    let payload_len = frame[3] as usize | (frame[4] as usize) << 8;
    if frame.len() != payload_len + 6 {
        return Err(ProtocolError::InvalidFrame(format!(
            "length mismatch: {} bytes, payload length field says {payload_len} (expected {})",
            frame.len(),
            payload_len + 6
        )));
    }
    if frame[frame.len() - 1] != CMD_END {
        return Err(ProtocolError::InvalidFrame(format!(
            "bad end byte: {:#04X} (expected {CMD_END:#04X})",
            frame[frame.len() - 1]
        )));
    }
    let cmd = frame[1];
    let kind = frame[2];
    let payload = frame[5..frame.len() - 1].to_vec();
    if cmd == CMD_BATTERY_POWER && !payload.is_empty() {
        Ok(Response::Battery { level: payload[0] })
    } else if cmd == CMD_RETURN_CODE && kind == TYPE_RETURN_CODE && payload.len() >= 2 {
        Ok(Response::Ack {
            cmd: payload[0],
            status: payload[1],
        })
    } else {
        Ok(Response::Other { cmd, kind, payload })
    }
}

/// Accumulates raw notification chunks into complete frames. More general
/// than ZeTimeDeviceSupport.receiveCompleteMsg: any number of chunks
/// per frame, garbage between frames is skipped.
#[derive(Default)]
pub struct Reassembler {
    buf: Vec<u8>,
}

impl Reassembler {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed a chunk; returns every complete frame it finished.
    pub fn push(&mut self, chunk: &[u8]) -> Vec<Vec<u8>> {
        self.buf.extend_from_slice(chunk);
        let mut frames = Vec::new();
        loop {
            // Drop leading garbage until a preamble.
            if let Some(pos) = self.buf.iter().position(|&b| b == CMD_PREAMBLE) {
                self.buf.drain(..pos);
            } else {
                self.buf.clear();
                break;
            }
            // Need the 2-byte length field before the expected size is known.
            if self.buf.len() < 5 {
                break;
            }
            let expected = (self.buf[3] as usize | (self.buf[4] as usize) << 8) + 6;
            if self.buf.len() < expected {
                break;
            }
            frames.push(self.buf.drain(..expected).collect());
        }
        frames
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_battery() {
        // Real capture from the watch's reply on 0x8002
        let r = decode(&[0x6F, 0x08, 0x80, 0x01, 0x00, 0x06, 0x8F]).unwrap();
        assert_eq!(r, Response::Battery { level: 6 });
    }

    #[test]
    fn decode_ack() {
        // Real capture on 0x8002 after a SetTime: acked cmd 0x04, status 0x00 (OK)
        let r = decode(&[0x6F, 0x01, 0x81, 0x02, 0x00, 0x04, 0x00, 0x8F]).unwrap();
        assert_eq!(r, Response::Ack { cmd: 4, status: 0 });
    }

    #[test]
    fn decode_short_return_code_is_other() {
        // 1-byte payload: not a valid ack
        let r = decode(&[0x6F, 0x01, 0x81, 0x01, 0x00, 0x04, 0x8F]).unwrap();
        assert_eq!(
            r,
            Response::Other {
                cmd: 0x01,
                kind: 0x81,
                payload: vec![0x04]
            }
        );
    }

    #[test]
    fn crc16_ccitt_vector() {
        // Standard check value for CRC-16/CCITT-FALSE
        assert_eq!(crc16_ccitt(b"123456789"), 0x29B1);
        assert_eq!(crc16_ccitt(b""), 0xFFFF);
    }

    #[test]
    fn command_names() {
        assert_eq!(command_name(0x04), "time sync");
        assert_eq!(command_name(0x08), "battery");
        assert_eq!(command_name(0x76), "notification");
        assert_eq!(command_name(0xD7), "watch event 0xD7");
        assert_eq!(command_name(0xDE), "watch event");
        assert_eq!(command_name(0xFF), "unknown command");
    }

    #[test]
    fn decode_invalid_frames() {
        // Bad preamble
        assert!(matches!(
            decode(&[0x70, 0x08, 0x80, 0x01, 0x00, 0x06, 0x8F]),
            Err(ProtocolError::InvalidFrame(_))
        ));
        // Bad end byte
        assert!(matches!(
            decode(&[0x6F, 0x08, 0x80, 0x01, 0x00, 0x06, 0x90]),
            Err(ProtocolError::InvalidFrame(_))
        ));
        // Length mismatch
        assert!(matches!(
            decode(&[0x6F, 0x08, 0x80, 0x05, 0x00, 0x06, 0x8F]),
            Err(ProtocolError::InvalidFrame(_))
        ));
        // Too short
        assert!(matches!(
            decode(&[0x6F, 0x08, 0x80]),
            Err(ProtocolError::InvalidFrame(_))
        ));
    }

    #[test]
    fn reassembler_multi_chunk() {
        // 39-byte frame pushed as 20+19 → nothing, then one frame
        let frame = [
            0x6F, 0x76, 0x71, 0x21, 0x00, 0x02, 0x01, 0x06, 0x08, b'R', b'a', b'p', b'p', b'e',
            b'l', 0x52, 0xC3, 0xA9, 0x75, 0x6E, 0x69, 0x6F, 0x6E, b'2', b'0', b'2', b'6', b'1',
            b'0', b'2', b'6', b'T', b'1', b'7', b'3', b'0', b'4', b'5', 0x8F,
        ];
        let mut r = Reassembler::new();
        assert!(r.push(&frame[..20]).is_empty());
        let frames = r.push(&frame[20..]);
        assert_eq!(frames, vec![frame.to_vec()]);
    }

    #[test]
    fn reassembler_single_chunk() {
        // 7-byte frame emitted immediately
        let frame = [0x6F, 0x08, 0x80, 0x01, 0x00, 0x06, 0x8F];
        let mut r = Reassembler::new();
        assert_eq!(r.push(&frame), vec![frame.to_vec()]);
    }

    #[test]
    fn reassembler_drops_garbage() {
        let frame = [0x6F, 0x08, 0x80, 0x01, 0x00, 0x06, 0x8F];
        let mut r = Reassembler::new();
        let mut chunk = vec![0xDE, 0xAD, 0xBE];
        chunk.extend_from_slice(&frame);
        assert_eq!(r.push(&chunk), vec![frame.to_vec()]);
    }
}
