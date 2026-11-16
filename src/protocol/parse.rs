//! Parsers for watch → phone payloads (REQUEST replies on 0x8002 and
//! watch events on 0x8004). Layouts verified against Gadgetbridge's
//! ZeTimeDeviceSupport.java.

use super::{
    CMD_CALL_CONTROL, CMD_FIND_PHONE, CMD_MUSIC_CONTROL, CMD_REAL_TIME_HEART_RATE, CMD_SEND,
    CMD_SEND_SOS, CMD_SMS_REPLY, CMD_SMS_REPLY_CONTENT, CMD_SOCIAL_REPLY, CMD_TAKE_PHOTO,
    ProtocolError, Response, SettingId, decode,
};
use chrono::{DateTime, NaiveDateTime};
use std::fmt;

/// Watch raw u32 timestamp → LOCAL wall-clock NaiveDateTime: the watch
/// counts local seconds, GB adds an 8h offset then subtracts the timezone
/// (L1151-1153) — equivalent to `raw + 28800` as UTC wall time.
pub fn watch_timestamp(raw: u32) -> NaiveDateTime {
    DateTime::from_timestamp(raw as i64 + 28800, 0)
        .expect("u32 timestamp is always representable")
        .naive_utc()
}

fn need(p: &[u8], n: usize, what: &str) -> Result<(), ProtocolError> {
    if p.len() < n {
        return Err(ProtocolError::InvalidFrame(format!(
            "{what}: payload too short ({} < {n})",
            p.len()
        )));
    }
    Ok(())
}

fn u16le(p: &[u8], i: usize) -> u16 {
    p[i] as u16 | (p[i + 1] as u16) << 8
}

fn u32le(p: &[u8], i: usize) -> u32 {
    p[i] as u32 | (p[i + 1] as u32) << 8 | (p[i + 2] as u32) << 16 | (p[i + 3] as u32) << 24
}

// ---------------------------------------------------------------------------
// Device info (L948-957, L1011-1019)
// ---------------------------------------------------------------------------

/// ASCII serial, trailing NUL/whitespace trimmed.
pub fn parse_watch_id(p: &[u8]) -> Result<String, ProtocolError> {
    need(p, 1, "watch id")?;
    Ok(String::from_utf8_lossy(p)
        .trim_end_matches(|c: char| c == '\0' || c.is_whitespace())
        .to_string())
}

/// p[0] echoes the requested kind (5 = firmware, 2 = hardware), the rest is
/// a NUL-terminated ASCII string.
pub fn parse_version(p: &[u8]) -> Result<String, ProtocolError> {
    need(p, 1, "version")?;
    Ok(String::from_utf8_lossy(&p[1..])
        .trim_end_matches(|c: char| c == '\0' || c.is_whitespace())
        .to_string())
}

// ---------------------------------------------------------------------------
// Activity data (L1032-1035, L1148+, L1196+, L1238+)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AvailableData {
    pub steps: u16,
    pub sleep: u16,
    pub heart_rate: u16,
}

pub fn parse_available_data(p: &[u8]) -> Result<AvailableData, ProtocolError> {
    need(p, 6, "available data")?;
    Ok(AvailableData {
        steps: u16le(p, 0),
        sleep: u16le(p, 2),
        heart_rate: u16le(p, 4),
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StepRecord {
    pub index: u16,
    pub timestamp: NaiveDateTime,
    pub steps: u32,
    pub calories: u32,
    pub distance_m: u32,
    pub active_min: u32,
}

pub fn parse_step_record(p: &[u8]) -> Result<StepRecord, ProtocolError> {
    need(p, 22, "step record")?;
    Ok(StepRecord {
        index: u16le(p, 0),
        timestamp: watch_timestamp(u32le(p, 2)),
        steps: u32le(p, 6),
        calories: u32le(p, 10),
        distance_m: u32le(p, 14),
        active_min: u32le(p, 18),
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SleepKind {
    Deep,
    Light,
    /// 16 — début de session de sommeil (agrégateur de l'app officielle,
    /// `cn/appscomm/bluetoothsdk/b/c.java` ; le « 10 » du doc Gadgetbridge
    /// était de l'hexadécimal 0x10).
    Begin,
    /// 17 — fin de session de sommeil : heure de réveil ; 18 est une
    /// variante de fin fusionnée côté app officielle.
    End,
    Unknown(u8),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SleepRecord {
    pub index: u16,
    pub timestamp: NaiveDateTime,
    pub kind: SleepKind,
}

pub fn parse_sleep_record(p: &[u8]) -> Result<SleepRecord, ProtocolError> {
    need(p, 7, "sleep record")?;
    Ok(SleepRecord {
        index: u16le(p, 0),
        timestamp: watch_timestamp(u32le(p, 2)),
        kind: match p[6] {
            0 => SleepKind::Deep,
            1 => SleepKind::Light,
            // 2/3/4 = variantes d'éveil, 16 = début, 17/18 = fin —
            // mapping confirmé dans l'agrégateur sommeil de l'app
            // officielle (0=deep, 1=light, 16=begin, 17=end, 18=end).
            16 => SleepKind::Begin,
            17 | 18 => SleepKind::End,
            v => SleepKind::Unknown(v),
        },
    })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HeartRateRecord {
    pub index: u16,
    pub timestamp: NaiveDateTime,
    pub bpm: u8,
}

/// One frame carries one record, or two when the payload is exactly 14 bytes.
pub fn parse_heart_rate_records(p: &[u8]) -> Result<Vec<HeartRateRecord>, ProtocolError> {
    need(p, 7, "heart rate record")?;
    let mut records = vec![HeartRateRecord {
        index: u16le(p, 0),
        timestamp: watch_timestamp(u32le(p, 2)),
        bpm: p[6],
    }];
    if p.len() == 14 {
        records.push(HeartRateRecord {
            index: u16le(p, 7),
            timestamp: watch_timestamp(u32le(p, 9)),
            bpm: p[13],
        });
    }
    Ok(records)
}

// ---------------------------------------------------------------------------
// Settings read back (ZeTimeDeviceSupport get* reply handlers)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub enum Setting {
    TimeSurface {
        date_format: u8,
        time_12h: bool,
    },
    Signaling {
        antiloss: u8,
        call: u8,
        missed_call: u8,
        sms: u8,
        social: u8,
        email: u8,
        calendar: u8,
        inactivity: u8,
        low_power: u8,
    },
    DoNotDisturb {
        enabled: bool,
        start: (u8, u8),
        end: (u8, u8),
    },
    AnalogMode(u8),
    ActivityTracking(bool),
    ScreenTime(u16),
    Wrist(u8),
    HeartRateInterval(u8),
    Inactivity {
        enabled: bool,
        days: u8,
        threshold_min: u8,
        start: (u8, u8),
        end: (u8, u8),
    },
    CaloriesType(u8),
    DisplayOnMovement(bool),
    /// Notification category bits decoded from the 0x90 switch mask
    /// (decompiled official app): bits 4-9 of bytes 0-1.
    NotificationSwitches {
        calls: bool,
        missed_calls: bool,
        sms: bool,
        social: bool,
        email: bool,
        calendar: bool,
    },
    /// Sleep switches decoded from the same 0x90 mask: bit 2 = sleep
    /// tracking, bit 3 = auto-sleep detection.
    SleepSwitches {
        tracking: bool,
        auto_sleep: bool,
    },
    /// Auto-sleep detection window read back from 0x58
    /// `[enterH][enterM][exitH][exitM][days]` (inferred layout — the GET
    /// answers a 5-byte struct, matching the SET payload).
    AutoSleepWindow {
        enter: (u8, u8),
        exit: (u8, u8),
        days: u8,
    },
    /// Single-byte settings (units, watch volume, brightness, snooze,
    /// notification text size — Android `Settings.kt`, all live-read).
    Byte(u8),
    /// Raw payload for settings GB itself doesn't parse (e.g. 0x5D limits).
    Raw(Vec<u8>),
}

impl fmt::Display for Setting {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Setting::TimeSurface {
                date_format,
                time_12h,
            } => write!(
                f,
                "date format {date_format}, {} clock",
                if *time_12h { "12h" } else { "24h" }
            ),
            Setting::Signaling {
                antiloss,
                call,
                missed_call,
                sms,
                social,
                email,
                calendar,
                inactivity,
                low_power,
            } => write!(
                f,
                "antiloss {antiloss}, call {call}, missed {missed_call}, sms {sms}, \
                 social {social}, email {email}, calendar {calendar}, \
                 inactivity {inactivity}, low power {low_power}"
            ),
            Setting::DoNotDisturb {
                enabled,
                start,
                end,
            } => write!(
                f,
                "{} ({:02}:{:02} → {:02}:{:02})",
                if *enabled { "on" } else { "off" },
                start.0,
                start.1,
                end.0,
                end.1
            ),
            Setting::AnalogMode(m) => {
                write!(f, "{}", if *m == 1 { "hands + steps" } else { "hands" })
            }
            Setting::ActivityTracking(on) => {
                write!(f, "{}", if *on { "on" } else { "off" })
            }
            Setting::ScreenTime(secs) => write!(f, "{secs}s"),
            Setting::Wrist(w) => write!(f, "{}", if *w == 1 { "right" } else { "left" }),
            Setting::HeartRateInterval(min) => {
                write!(
                    f,
                    "{}",
                    if *min == 0 {
                        "off".into()
                    } else {
                        format!("{min} min")
                    }
                )
            }
            Setting::Inactivity {
                enabled,
                days,
                threshold_min,
                start,
                end,
            } => write!(
                f,
                "{} (days {days:#09b}, {threshold_min} min, {:02}:{:02} → {:02}:{:02})",
                if *enabled { "on" } else { "off" },
                start.0,
                start.1,
                end.0,
                end.1
            ),
            Setting::CaloriesType(t) => {
                write!(f, "{}", if *t == 1 { "all" } else { "active only" })
            }
            Setting::DisplayOnMovement(on) => {
                write!(f, "{}", if *on { "on" } else { "off" })
            }
            Setting::NotificationSwitches {
                calls,
                missed_calls,
                sms,
                social,
                email,
                calendar,
            } => write!(
                f,
                "calls {calls}, missed {missed_calls}, sms {sms}, \
                 social {social}, email {email}, calendar {calendar}"
            ),
            Setting::SleepSwitches {
                tracking,
                auto_sleep,
            } => write!(
                f,
                "tracking {}, auto-sleep {}",
                if *tracking { "on" } else { "off" },
                if *auto_sleep { "on" } else { "off" }
            ),
            Setting::AutoSleepWindow { enter, exit, days } => write!(
                f,
                "{:02}:{:02} → {:02}:{:02} (days {days:#09b})",
                enter.0, enter.1, exit.0, exit.1
            ),
            Setting::Byte(v) => write!(f, "{v}"),
            Setting::Raw(p) => write!(f, "raw {}", super::to_hex(p)),
        }
    }
}

/// Parse a ReadSetting reply payload. Unknown enum values are kept raw —
/// never fails on an unexpected value, only on a short payload.
pub fn parse_setting(id: SettingId, p: &[u8]) -> Result<Setting, ProtocolError> {
    match id {
        SettingId::TimeSurface => {
            need(p, 2, "time surface")?;
            Ok(Setting::TimeSurface {
                date_format: p[0],
                time_12h: p[1] == 2,
            })
        }
        SettingId::Signaling => {
            need(p, 10, "signaling")?;
            Ok(Setting::Signaling {
                antiloss: p[0],
                call: p[2],
                missed_call: p[3],
                sms: p[4],
                social: p[5],
                email: p[6],
                calendar: p[7],
                inactivity: p[8],
                low_power: p[9],
            })
        }
        SettingId::DoNotDisturb => {
            need(p, 5, "do not disturb")?;
            Ok(Setting::DoNotDisturb {
                enabled: p[0] == 1,
                start: (p[1], p[2]),
                end: (p[3], p[4]),
            })
        }
        SettingId::AnalogMode => {
            need(p, 1, "analog mode")?;
            Ok(Setting::AnalogMode(p[0]))
        }
        SettingId::ActivityTracking => {
            need(p, 2, "activity tracking")?;
            Ok(Setting::ActivityTracking(p[1] != 1))
        }
        SettingId::ScreenTime => {
            need(p, 2, "screen time")?;
            Ok(Setting::ScreenTime(u16le(p, 0)))
        }
        SettingId::Wrist => {
            need(p, 1, "wrist")?;
            Ok(Setting::Wrist(p[0]))
        }
        SettingId::HeartRateInterval => {
            need(p, 1, "heart rate interval")?;
            Ok(Setting::HeartRateInterval(p[0]))
        }
        SettingId::HeartRateLimits => {
            // GB doesn't parse this one either.
            Ok(Setting::Raw(p.to_vec()))
        }
        SettingId::Inactivity => {
            need(p, 6, "inactivity")?;
            Ok(Setting::Inactivity {
                enabled: p[0] != 0,
                days: p[0] & 0x7F,
                threshold_min: p[1],
                start: (p[2], p[3]),
                end: (p[4], p[5]),
            })
        }
        SettingId::CaloriesType => {
            need(p, 1, "calories type")?;
            Ok(Setting::CaloriesType(p[0]))
        }
        SettingId::DisplayOnMovement => {
            need(p, 2, "display on movement")?;
            Ok(Setting::DisplayOnMovement(p[1] & 0x40 != 0))
        }
        SettingId::NotificationSwitches => {
            // Same 0x90 response as DisplayOnMovement: mask is LE bits,
            // byte0 = bits 0-7, byte1 = bits 8-15.
            need(p, 2, "notification switches")?;
            let mask = u32::from(p[0]) | (u32::from(p[1]) << 8);
            let bit = |n: u32| mask & (1 << n) != 0;
            Ok(Setting::NotificationSwitches {
                calls: bit(4),
                missed_calls: bit(5),
                sms: bit(6),
                social: bit(7),
                email: bit(8),
                calendar: bit(9),
            })
        }
        SettingId::SleepSwitches => {
            // Same 0x90 mask as NotificationSwitches: bit 2 = sleep
            // tracking, bit 3 = auto-sleep detection.
            need(p, 2, "sleep switches")?;
            let mask = u32::from(p[0]) | (u32::from(p[1]) << 8);
            Ok(Setting::SleepSwitches {
                tracking: mask & (1 << 2) != 0,
                auto_sleep: mask & (1 << 3) != 0,
            })
        }
        SettingId::AutoSleepWindow => {
            need(p, 5, "auto-sleep window")?;
            Ok(Setting::AutoSleepWindow {
                enter: (p[0], p[1]),
                exit: (p[2], p[3]),
                days: p[4],
            })
        }
        SettingId::Units
        | SettingId::Volume
        | SettingId::Brightness
        | SettingId::Snooze
        | SettingId::TextSize
        | SettingId::BrightScreenTime => {
            need(p, 1, "byte setting")?;
            Ok(Setting::Byte(p[0]))
        }
    }
}

/// One stored alarm/reminder, from a 0x97 read response
/// `[slot, type, year:2le, month, day, hour, minute, cycle, enabled, shock]`.
/// `type`: 4 = alarm; other values are reminder types (official app).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlarmEntry {
    pub slot: u8,
    pub alarm_type: u8,
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    /// Weekday bitmask: bit0 Mon … bit6 Sun. 0 never rings (live-confirmed).
    pub cycle: u8,
    pub enabled: bool,
    pub shock: u8,
}

impl AlarmEntry {
    /// The 10 field bytes `[type][year:2le][month][day][hour][minute]
    /// [cycle][enabled][shock]` — the identity block used by the 0x97
    /// add/edit/delete frames (Android `Alarm.kt`, live-confirmed).
    pub fn fields(&self) -> [u8; 10] {
        [
            self.alarm_type,
            (self.year & 0xFF) as u8,
            (self.year >> 8) as u8,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.cycle,
            self.enabled as u8,
            self.shock,
        ]
    }
}

pub fn parse_alarm(p: &[u8]) -> Result<AlarmEntry, ProtocolError> {
    need(p, 11, "alarm")?;
    Ok(AlarmEntry {
        slot: p[0],
        alarm_type: p[1],
        year: u16::from_le_bytes([p[2], p[3]]),
        month: p[4],
        day: p[5],
        hour: p[6],
        minute: p[7],
        cycle: p[8],
        enabled: p[9] != 0,
        shock: p[10],
    })
}

/// Quick-reply entry metadata from a 0xDA reply `[count][crc:2le]×count`
/// (firmware A2.0.55, handler 0x2d2e8). Each `u16` is the
/// CRC-16/CCITT-FALSE of one entry's text — the stable identifier used
/// to read (0xDB GET), replace and delete entries, since indices shift.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickReplyMeta {
    /// One CRC per stored entry, in slot order (index = position + 1).
    pub crcs: Vec<u16>,
}

pub fn parse_quick_reply_meta(p: &[u8]) -> Result<QuickReplyMeta, ProtocolError> {
    need(p, 1, "quick reply metadata")?;
    let count = p[0] as usize;
    if count > super::QUICK_REPLY_MAX_COUNT as usize {
        return Err(ProtocolError::InvalidFrame(format!(
            "quick reply metadata: count {count} out of range (max {})",
            super::QUICK_REPLY_MAX_COUNT
        )));
    }
    need(p, 1 + 2 * count, "quick reply metadata")?;
    Ok(QuickReplyMeta {
        crcs: (0..count).map(|i| u16le(p, 1 + 2 * i)).collect(),
    })
}

/// One quick-reply entry from a 0xDB reply frame
/// `[index:1-based][crc:2le][text]` (reply builder at 0x5a3a8).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickReply {
    /// 1-based position in the reply stream — equals the slot index when
    /// streaming all entries; unstable across insert/delete.
    pub index: u8,
    /// CRC-16/CCITT-FALSE of the raw text bytes — the stable identifier
    /// addressed by `GetQuickReply`/`UpdateQuickReply`/`DeleteQuickReply`.
    pub crc: u16,
    /// Text decoded as UTF-16LE (the picker renders slot bytes as UTF-16;
    /// a trailing odd byte is dropped).
    pub text: String,
}

pub fn parse_quick_reply(p: &[u8]) -> Result<QuickReply, ProtocolError> {
    need(p, 3, "quick reply")?;
    Ok(QuickReply {
        index: p[0],
        crc: u16le(p, 1),
        text: String::from_utf16_lossy(
            &p[3..]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| u16::from_le_bytes(*c))
                .collect::<Vec<u16>>(),
        ),
    })
}

// ---------------------------------------------------------------------------
// Read-backs (Android `Health.kt` / `PersonalInfo.kt` / `NightMode.kt`)
// ---------------------------------------------------------------------------

/// Daily goals read back from a 0x50 REQUEST reply: 5 × `[value:2le][flag]`
/// in order steps / calories / distance / sleep / active-time. Values are
/// already in display units: steps count, kcal, whole km, hours, minutes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Goals {
    pub steps: u16,
    pub calories: u16,
    /// Whole kilometres.
    pub distance_km: u16,
    /// Hours.
    pub sleep_hours: u16,
    /// Minutes.
    pub active_minutes: u16,
}

pub fn parse_goals(p: &[u8]) -> Result<Goals, ProtocolError> {
    need(p, 15, "goals")?;
    let slot = |i: usize| u16le(p, i * 3);
    Ok(Goals {
        // Wire unit is steps/100 (Android `decodeGoals`: raw * 100).
        steps: slot(0).saturating_mul(100),
        calories: slot(1),
        distance_km: slot(2),
        sleep_hours: slot(3),
        active_minutes: slot(4),
    })
}

/// User profile read back from a 0x30 REQUEST reply
/// `[sex][age][height_cm][weight_kg×10:2le]` (Android `PersonalInfo.kt`,
/// live round-trip confirmed).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UserInfo {
    /// 0 = male, 1 = female, 2 = other (same codes as `Gender`).
    pub sex: u8,
    pub age: u8,
    pub height_cm: u8,
    pub weight_kg: f32,
}

pub fn parse_user_info(p: &[u8]) -> Result<UserInfo, ProtocolError> {
    need(p, 5, "user info")?;
    Ok(UserInfo {
        sex: p[0],
        age: p[1],
        height_cm: p[2],
        weight_kg: f32::from(u16le(p, 3)) / 10.0,
    })
}

/// Night-mode screen config from a 0x21 reply `[color][has_dial]`
/// (Android `NightMode.kt`): color 1 = blue, 2 = green, 3 = white;
/// `has_dial` = minute-tick ring, live-confirmed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NightMode {
    pub color: u8,
    pub has_dial: bool,
}

pub fn parse_night_mode(p: &[u8]) -> Result<NightMode, ProtocolError> {
    need(p, 2, "night mode")?;
    Ok(NightMode {
        color: p[0],
        has_dial: p[1] != 0,
    })
}

/// One physical-button assignment from a 0x2E reply.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ButtonFunction {
    /// 1=UP, 2=BOTTOM, 3=OTS_SHORT (crown tap), 4=OTS_LONG (crown hold).
    pub button: u8,
    pub function: u8,
}

/// Parse a 0x2E reply: consecutive `[0x02][buttonId][function]` records.
/// Records with another tag byte are skipped; a trailing partial record is
/// ignored.
pub fn parse_button_functions(p: &[u8]) -> Vec<ButtonFunction> {
    p.as_chunks::<3>()
        .0
        .iter()
        .filter(|r| r[0] == 0x02)
        .map(|r| ButtonFunction {
            button: r[1],
            function: r[2],
        })
        .collect()
}

/// 0x2E GET reply: `[0x02][buttonId][function]` records — same layout as
/// SET. Returns (button_id, function) pairs; names resolved by the caller.
pub fn parse_button_assignments(p: &[u8]) -> Result<Vec<(u8, u8)>, ProtocolError> {
    if p.is_empty() || !p.len().is_multiple_of(3) {
        return Err(ProtocolError::InvalidFrame(format!(
            "button assignments: {} bytes not a multiple of 3",
            p.len()
        )));
    }
    Ok(p.as_chunks::<3>().0.iter().map(|r| (r[1], r[2])).collect())
}

// ---------------------------------------------------------------------------
// Watch → phone events on 0x8004 (ZeTimeDeviceSupport.handleMusicControl / handleCallControl)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MusicCommand {
    Play,
    Pause,
    Previous,
    Next,
    Volume(u8),
    Unknown(u8),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WatchEvent {
    Music(MusicCommand),
    /// State query carries the source picked on the watch's music screen:
    /// 0=Apple Music (default), 1=Spotify, 2=Deezer (live-confirmed).
    MusicStateRequest(u8),
    CallRejected,
    /// 0xD1 — camera-remote screen tap; the watch runs a 3→1 countdown and
    /// waits for the generic ack (return code on 0x8003).
    Camera,
    /// 0xD2 — "find my phone" screen. Payload format undocumented.
    FindPhone,
    /// 0xD9 — SOS trigger. Payload format undocumented.
    Sos,
    /// 0xDD — SMS quick reply, 0xE6 — social quick reply, 0xDE — reply
    /// content follow-up. Decoded per Android `ReplyEvents.kt` + the live
    /// 0xDD capture (`[reply_id:12][notif_title]`).
    QuickReply(QuickReplyEvent),
    /// 0xE2 — real-time heart-rate push `[bpm:1]` (live-observed).
    RealTimeHeartRate {
        bpm: u8,
    },
}

/// Decoded quick-reply event (0xDD SMS / 0xE6 social / 0xDE content).
/// Selection frames carry: bytes 0-7 = emoji `face` (up to first `0xFF`),
/// byte 8 = reply language, byte 9 = command, bytes 10-11 = preset CRC
/// (`0xFFFF` = none), bytes 12+ = SMS sender (0xDD) or notification CRC
/// (0xE6). `0xDE` follow-up frames carry `[index][utf16le content]`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickReplyEvent {
    /// Which event opcode produced this (`CMD_SMS_REPLY`,
    /// `CMD_SOCIAL_REPLY` or `CMD_SMS_REPLY_CONTENT`).
    pub opcode: u8,
    /// CRC-16/CCITT-FALSE of the watch-stored reply preset, when the user
    /// picked one (resolve the text via the 0xDA/0xDB list).
    pub preset_crc: Option<u16>,
    /// Emoji face picked on the watch's built-in keyboard ("" if none —
    /// stored presets and the list-request marker have no face bytes).
    pub face: String,
    /// SMS sender name/number (0xDD only).
    pub sender: Option<String>,
    /// Notification CRC correlating this reply to the notification that
    /// triggered it (0xE6 only).
    pub notification_crc: Option<u16>,
    /// Follow-up content text (0xDE only, UTF-16LE).
    pub content: Option<String>,
    /// Raw payload, kept for the journal/debug panel.
    pub raw: Vec<u8>,
}

fn decode_quick_reply_selection(opcode: u8, payload: &[u8]) -> QuickReplyEvent {
    let mut ev = QuickReplyEvent {
        opcode,
        preset_crc: None,
        face: String::new(),
        sender: None,
        notification_crc: None,
        content: None,
        raw: payload.to_vec(),
    };
    if payload.len() >= 12 {
        // Face = up to 8 bytes ending at the first 0xFF pad.
        let end = payload[..8]
            .iter()
            .position(|&b| b == 0xFF)
            .unwrap_or(payload[..8].len().min(payload.len()));
        ev.face = String::from_utf8_lossy(&payload[..end]).into_owned();
        let crc = u16le(payload, 10);
        if crc != 0xFFFF {
            ev.preset_crc = Some(crc);
        }
        match opcode {
            // 0xDD: bytes 12+ = sender (UTF-8).
            CMD_SMS_REPLY if payload.len() > 12 => {
                ev.sender = Some(String::from_utf8_lossy(&payload[12..]).into_owned());
            }
            // 0xE6: bytes 12-13 = notification CRC.
            CMD_SOCIAL_REPLY if payload.len() >= 14 => {
                ev.notification_crc = Some(u16le(payload, 12));
            }
            _ => {}
        }
    }
    ev
}

fn decode_quick_reply_content(payload: &[u8]) -> QuickReplyEvent {
    QuickReplyEvent {
        opcode: CMD_SMS_REPLY_CONTENT,
        preset_crc: None,
        face: String::new(),
        sender: None,
        notification_crc: None,
        content: Some(String::from_utf16_lossy(
            &payload[1..]
                .as_chunks::<2>()
                .0
                .iter()
                .map(|c| u16::from_le_bytes(*c))
                .collect::<Vec<u16>>(),
        )),
        raw: payload.to_vec(),
    }
}

/// Decode a watch→phone event frame. Returns `None` for frames that aren't
/// events. Events 0xD1/0xD2/0xD9/0xDD/0xDE/0xE6 expect a generic ack
/// (return-code echo) written to the reply characteristic (0x8003) by the
/// caller.
pub fn parse_watch_event(frame: &[u8]) -> Option<WatchEvent> {
    let Ok(Response::Other { cmd, kind, payload }) = decode(frame) else {
        return None;
    };
    match (cmd, kind) {
        (CMD_MUSIC_CONTROL, CMD_SEND) if !payload.is_empty() => {
            Some(WatchEvent::Music(match payload[0] {
                0 => MusicCommand::Play,
                1 => MusicCommand::Pause,
                2 => MusicCommand::Previous,
                3 => MusicCommand::Next,
                4 => MusicCommand::Volume(payload.get(1).copied().unwrap_or(0)),
                v => MusicCommand::Unknown(v),
            }))
        }
        (CMD_MUSIC_CONTROL, _) => Some(WatchEvent::MusicStateRequest(
            payload.first().copied().unwrap_or(0),
        )),
        (CMD_CALL_CONTROL, CMD_SEND) if payload == [0x01] => Some(WatchEvent::CallRejected),
        (CMD_TAKE_PHOTO, CMD_SEND) => Some(WatchEvent::Camera),
        (CMD_FIND_PHONE, CMD_SEND) => Some(WatchEvent::FindPhone),
        (CMD_SEND_SOS, CMD_SEND) => Some(WatchEvent::Sos),
        (CMD_SMS_REPLY | CMD_SOCIAL_REPLY, CMD_SEND) => Some(WatchEvent::QuickReply(
            decode_quick_reply_selection(cmd, &payload),
        )),
        (CMD_SMS_REPLY_CONTENT, CMD_SEND) if payload.len() >= 2 => {
            Some(WatchEvent::QuickReply(decode_quick_reply_content(&payload)))
        }
        (CMD_REAL_TIME_HEART_RATE, CMD_SEND) => payload
            .first()
            .map(|&bpm| WatchEvent::RealTimeHeartRate { bpm }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn button_functions_from_scan() {
        let p = [
            0x02, 0x01, 0x01, 0x02, 0x02, 0x03, 0x02, 0x03, 0x00, 0x02, 0x04, 0x00,
        ];
        let b = super::parse_button_functions(&p);
        assert_eq!(b.len(), 4);
        assert_eq!((b[0].button, b[0].function), (1, 1));
        assert_eq!((b[1].button, b[1].function), (2, 3));
        assert_eq!((b[3].button, b[3].function), (4, 0));
    }

    use super::*;

    #[test]
    fn timestamp_conversion() {
        // raw + 28800 as UTC = local wall time
        let ts = watch_timestamp(0);
        assert_eq!(
            ts,
            NaiveDateTime::parse_from_str("1970-01-01T08:00:00", "%Y-%m-%dT%H:%M:%S").unwrap()
        );
        let ts = watch_timestamp(1_792_972_800); // 2026-10-26T00:00Z + 8h
        assert_eq!(
            ts,
            NaiveDateTime::parse_from_str("2026-10-26T08:00:00", "%Y-%m-%dT%H:%M:%S").unwrap()
        );
    }

    #[test]
    fn parse_watch_id_trims() {
        assert_eq!(parse_watch_id(b"ZT123456\0\0").unwrap(), "ZT123456");
        assert!(parse_watch_id(&[]).is_err());
    }

    #[test]
    fn parse_version_reply() {
        assert_eq!(
            parse_version(&[0x05, b'R', b'1', b'.', b'7', 0]).unwrap(),
            "R1.7"
        );
        assert!(parse_version(&[]).is_err());
    }

    #[test]
    fn parse_available() {
        let d = parse_available_data(&[2, 0, 1, 0, 3, 0]).unwrap();
        assert_eq!(
            d,
            AvailableData {
                steps: 2,
                sleep: 1,
                heart_rate: 3
            }
        );
        assert!(parse_available_data(&[1, 0]).is_err());
    }

    #[test]
    fn parse_step() {
        let mut p = vec![0x02, 0x00]; // index 2
        p.extend_from_slice(&1_792_972_800u32.to_le_bytes()); // ts
        p.extend_from_slice(&5000u32.to_le_bytes()); // steps
        p.extend_from_slice(&250u32.to_le_bytes()); // calories
        p.extend_from_slice(&3500u32.to_le_bytes()); // distance
        p.extend_from_slice(&45u32.to_le_bytes()); // active min
        let r = parse_step_record(&p).unwrap();
        assert_eq!(r.index, 2);
        assert_eq!(r.steps, 5000);
        assert_eq!(r.active_min, 45);
        assert!(parse_step_record(&p[..10]).is_err());
    }

    #[test]
    fn parse_sleep() {
        let mut p = vec![0x01, 0x00];
        p.extend_from_slice(&1_792_972_800u32.to_le_bytes());
        p.push(0x00);
        let r = parse_sleep_record(&p).unwrap();
        assert_eq!(r.kind, SleepKind::Deep);
        // Sessions : 16 = début, 17/18 = fin (app officielle).
        for (code, kind) in [
            (1, SleepKind::Light),
            (16, SleepKind::Begin),
            (17, SleepKind::End),
            (18, SleepKind::End),
            (3, SleepKind::Unknown(3)),
        ] {
            let mut q = p.clone();
            q[6] = code;
            assert_eq!(parse_sleep_record(&q).unwrap().kind, kind, "code {code}");
        }
        let mut p2 = p.clone();
        p2[6] = 7;
        assert_eq!(parse_sleep_record(&p2).unwrap().kind, SleepKind::Unknown(7));
        assert!(parse_sleep_record(&p[..5]).is_err());
    }

    #[test]
    fn parse_heart_rate_single_and_double() {
        let mut p = vec![0x01, 0x00];
        p.extend_from_slice(&1_792_972_800u32.to_le_bytes());
        p.push(72);
        let recs = parse_heart_rate_records(&p).unwrap();
        assert_eq!(recs.len(), 1);
        assert_eq!(recs[0].bpm, 72);

        // 14-byte payload → two records
        let mut p2 = p.clone();
        p2.extend_from_slice(&[0x02, 0x00]);
        p2.extend_from_slice(&1_792_973_160u32.to_le_bytes());
        p2.push(75);
        let recs = parse_heart_rate_records(&p2).unwrap();
        assert_eq!(recs.len(), 2);
        assert_eq!(recs[1].index, 2);
        assert_eq!(recs[1].bpm, 75);
        assert!(parse_heart_rate_records(&p[..4]).is_err());
    }

    #[test]
    fn parse_settings() {
        assert_eq!(
            parse_setting(SettingId::TimeSurface, &[0x01, 0x02]).unwrap(),
            Setting::TimeSurface {
                date_format: 1,
                time_12h: true
            }
        );
        assert_eq!(
            parse_setting(SettingId::Signaling, &[13, 0, 13, 12, 2, 12, 12, 12, 12, 4]).unwrap(),
            Setting::Signaling {
                antiloss: 13,
                call: 13,
                missed_call: 12,
                sms: 2,
                social: 12,
                email: 12,
                calendar: 12,
                inactivity: 12,
                low_power: 4,
            }
        );
        assert_eq!(
            parse_setting(SettingId::DoNotDisturb, &[1, 22, 0, 7, 0]).unwrap(),
            Setting::DoNotDisturb {
                enabled: true,
                start: (22, 0),
                end: (7, 0)
            }
        );
        assert_eq!(
            parse_setting(SettingId::AnalogMode, &[1]).unwrap(),
            Setting::AnalogMode(1)
        );
        assert_eq!(
            parse_setting(SettingId::ActivityTracking, &[0, 0x0A]).unwrap(),
            Setting::ActivityTracking(true)
        );
        assert_eq!(
            parse_setting(SettingId::ScreenTime, &[60, 0]).unwrap(),
            Setting::ScreenTime(60)
        );
        assert_eq!(
            parse_setting(SettingId::Wrist, &[1]).unwrap(),
            Setting::Wrist(1)
        );
        assert_eq!(
            parse_setting(SettingId::HeartRateInterval, &[0]).unwrap(),
            Setting::HeartRateInterval(0)
        );
        assert_eq!(
            parse_setting(SettingId::HeartRateLimits, &[200, 60, 1]).unwrap(),
            Setting::Raw(vec![200, 60, 1])
        );
        assert_eq!(
            parse_setting(SettingId::Inactivity, &[0x85, 60, 9, 0, 18, 0]).unwrap(),
            Setting::Inactivity {
                enabled: true,
                days: 0x05,
                threshold_min: 60,
                start: (9, 0),
                end: (18, 0)
            }
        );
        assert_eq!(
            parse_setting(SettingId::CaloriesType, &[1]).unwrap(),
            Setting::CaloriesType(1)
        );
        assert_eq!(
            parse_setting(SettingId::DisplayOnMovement, &[1, 0x40]).unwrap(),
            Setting::DisplayOnMovement(true)
        );
        // 0x90 mask 0xF2 0xBF (live 2026-10-29) : bits 2-3 (sleep/auto-sleep)
        // à 0, bits 4-9 (notifications) à 1.
        assert_eq!(
            parse_setting(SettingId::SleepSwitches, &[0xF2, 0xBF]).unwrap(),
            Setting::SleepSwitches {
                tracking: false,
                auto_sleep: false,
            }
        );
        // auto-sleep ON = bit 3 → byte0 |= 0x08.
        assert_eq!(
            parse_setting(SettingId::SleepSwitches, &[0xFA, 0xBF]).unwrap(),
            Setting::SleepSwitches {
                tracking: false,
                auto_sleep: true,
            }
        );
        assert_eq!(
            parse_setting(SettingId::AutoSleepWindow, &[23, 0, 9, 0, 0x7F]).unwrap(),
            Setting::AutoSleepWindow {
                enter: (23, 0),
                exit: (9, 0),
                days: 0x7F,
            }
        );
        // short payloads error, unexpected values don't
        assert!(parse_setting(SettingId::ScreenTime, &[1]).is_err());
        assert!(matches!(
            parse_setting(SettingId::Wrist, &[9]).unwrap(),
            Setting::Wrist(9)
        ));
    }

    #[test]
    fn parse_events() {
        // music next on 0xD0
        assert_eq!(
            parse_watch_event(&[0x6F, 0xD0, 0x71, 0x01, 0x00, 0x03, 0x8F]),
            Some(WatchEvent::Music(MusicCommand::Next))
        );
        // volume
        assert_eq!(
            parse_watch_event(&[0x6F, 0xD0, 0x71, 0x02, 0x00, 0x04, 60, 0x8F]),
            Some(WatchEvent::Music(MusicCommand::Volume(60)))
        );
        // music state request (type 0x80)
        assert_eq!(
            parse_watch_event(&[0x6F, 0xD0, 0x80, 0x01, 0x00, 0x00, 0x8F]),
            Some(WatchEvent::MusicStateRequest(0))
        );
        // state query with a source picked on the watch (Spotify=1)
        assert_eq!(
            parse_watch_event(&[0x6F, 0xD0, 0x70, 0x01, 0x00, 0x01, 0x8F]),
            Some(WatchEvent::MusicStateRequest(1))
        );
        // 0x2E GET reply — live capture: up=1 dim, bottom=6 camera,
        // crown-short=4 music, crown-long=6 camera.
        assert_eq!(
            parse_button_assignments(&[2, 1, 1, 2, 2, 6, 2, 3, 4, 2, 4, 6]).unwrap(),
            vec![(1, 1), (2, 6), (3, 4), (4, 6)]
        );
        assert!(parse_button_assignments(&[2, 1]).is_err());
        // call rejected on 0xDC
        assert_eq!(
            parse_watch_event(&[0x6F, 0xDC, 0x71, 0x01, 0x00, 0x01, 0x8F]),
            Some(WatchEvent::CallRejected)
        );
        // not an event
        assert_eq!(
            parse_watch_event(&[0x6F, 0x08, 0x80, 0x01, 0x00, 0x06, 0x8F]),
            None
        );
    }

    #[test]
    fn quick_reply_meta() {
        // 0xDA reply [count][crc:2le]×count
        let m = parse_quick_reply_meta(&[0]).unwrap();
        assert!(m.crcs.is_empty());
        let m = parse_quick_reply_meta(&[2, 0xB1, 0x29, 0x34, 0x12]).unwrap();
        assert_eq!(m.crcs, [0x29B1, 0x1234]);
        // trailing bytes tolerated, short/truncated/over-count rejected
        assert!(parse_quick_reply_meta(&[2, 0xB1, 0x29, 0x34, 0x12, 0xFF]).is_ok());
        assert!(parse_quick_reply_meta(&[]).is_err());
        assert!(parse_quick_reply_meta(&[2, 0xB1, 0x29]).is_err());
        let mut over = vec![11u8]; // count > 10
        over.extend_from_slice(&[0; 22]);
        assert!(parse_quick_reply_meta(&over).is_err());
    }

    #[test]
    fn quick_reply_entry() {
        // 0xDB reply frame [index][crc:2le][text:utf-16le]
        let r = parse_quick_reply(&[3, 0xB1, 0x29, b'S', 0, b'a', 0, b'l', 0, b'u', 0, b't', 0])
            .unwrap();
        assert_eq!(
            r,
            QuickReply {
                index: 3,
                crc: 0x29B1,
                text: "Salut".into()
            }
        );
        // empty text is legal (payload = header only)
        assert_eq!(parse_quick_reply(&[1, 0xFF, 0xFF]).unwrap().text, "");
        // UTF-16LE decode: 'é' = 0x00E9; odd trailing byte dropped
        let r = parse_quick_reply(&[1, 0, 0, b'R', 0, 0xE9, 0x00, 0xFF]).unwrap();
        assert_eq!(r.text, "Ré");
        assert!(parse_quick_reply(&[1, 0x00]).is_err());
    }
}
