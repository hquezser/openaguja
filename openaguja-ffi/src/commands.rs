//! Typed command surface for the app: every safe `protocol::Command` as a
//! UniFFI enum (`WatchCommand`) + typed parsers for the REQUEST replies.
//!
//! Deliberately NOT exposed: upgrade mode (0x0E), watchface SET/DELETE
//! (0x20/0x1F) and hand positions — they can reboot the watch into DFU or
//! are undocumented (see RECOVERY.md).

use chrono::{Datelike, NaiveDate, NaiveDateTime, Timelike};
use openaguja::protocol::{self, Command, SettingId, parse};

use crate::ZeTimeError;

/// Declares a UniFFI mirror of a core C-like enum plus the `From` impl.
macro_rules! mirror_enum {
    ($(#[$m:meta])* $name:ident => $core:path { $($v:ident),+ $(,)? }) => {
        $(#[$m])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, uniffi::Enum)]
        pub enum $name { $($v),+ }

        impl From<$name> for $core {
            fn from(v: $name) -> Self {
                match v { $($name::$v => <$core>::$v),+ }
            }
        }
    };
}

mirror_enum!(Wrist => protocol::Wrist { Left, Right });
mirror_enum!(Gender => protocol::Gender { Male, Female, Other });
mirror_enum!(GoalKind => protocol::GoalKind { Steps, Calories, Distance, Sleep, ActiveTime });
mirror_enum!(AnalogMode => protocol::AnalogMode { Hands, HandsAndSteps });
mirror_enum!(CaloriesType => protocol::CaloriesType { ActiveOnly, All });
mirror_enum!(TimeFormat => protocol::TimeFormat { H24, H12 });
mirror_enum!(DateFormat => protocol::DateFormat { YyMmDd, DdMmYy, MmDdYy });
mirror_enum!(
    /// Event whose alert pattern is configured with `SetSignaling`.
    SignalEvent => protocol::SignalEvent {
        AntiLoss, Call, MissedCall, Sms, Social, Email, Calendar, Inactivity, LowPower,
    }
);
mirror_enum!(SignalPattern => protocol::SignalPattern {
    VibrateOnce, VibrateTwice, Vibrate, BeepOnce, BeepTwice, Beep, VibrateBeepOnce,
    VibrateBeep, None,
});
mirror_enum!(Language => protocol::Language {
    En, ZhCn, ZhTw, Ko, Th, Ja, Fr, Es, De, It, Pl, Pt, Ru, Nl, Ar, El, He, Sv, Cs,
});
mirror_enum!(
    /// Settings that can be read back with `WatchCommand::ReadSetting`.
    SettingKind => SettingId {
        TimeSurface, Signaling, DoNotDisturb, AnalogMode, ActivityTracking, ScreenTime,
        Wrist, HeartRateInterval, HeartRateLimits, Inactivity, CaloriesType,
        DisplayOnMovement, NotificationSwitches, SleepSwitches, AutoSleepWindow,
        Units, Volume, Brightness, Snooze, TextSize, BrightScreenTime,
    }
);
mirror_enum!(
    /// 0x97 alarm/reminder type (Android `Alarm.kt`): 4 = alarm,
    /// 1 = medicine, 2 = water, 7 = custom reminder (renders `content`).
    AlarmKind => protocol::AlarmKind { Medicine, Water, Alarm, Custom }
);

/// Raw code of a signal pattern (as stored in a `Signaling` read-back).
#[uniffi::export]
pub fn signal_pattern_code(pattern: SignalPattern) -> u8 {
    protocol::SignalPattern::from(pattern).code()
}

/// Inverse of `signal_pattern_code` — `None` for a code the app doesn't name.
#[uniffi::export]
pub fn signal_pattern_from_code(code: u8) -> Option<SignalPattern> {
    use SignalPattern::*;
    [
        VibrateOnce,
        VibrateTwice,
        Vibrate,
        BeepOnce,
        BeepTwice,
        Beep,
        VibrateBeepOnce,
        VibrateBeep,
        None,
    ]
    .into_iter()
    .find(|p| signal_pattern_code(*p) == code)
}

/// Wall-clock time as the watch stores it (no timezone).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct WatchDateTime {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

impl From<NaiveDateTime> for WatchDateTime {
    fn from(t: NaiveDateTime) -> Self {
        Self {
            year: t.year().clamp(0, u16::MAX as i32) as u16,
            month: t.month() as u8,
            day: t.day() as u8,
            hour: t.hour() as u8,
            minute: t.minute() as u8,
            second: t.second() as u8,
        }
    }
}

impl TryFrom<WatchDateTime> for NaiveDateTime {
    type Error = ZeTimeError;

    fn try_from(t: WatchDateTime) -> Result<Self, Self::Error> {
        NaiveDate::from_ymd_opt(t.year.into(), t.month.into(), t.day.into())
            .and_then(|d| d.and_hms_opt(t.hour.into(), t.minute.into(), t.second.into()))
            .ok_or_else(|| ZeTimeError::InvalidValue(format!("invalid date/time {t:?}")))
    }
}

/// Hour + minute pair (DND window, inactivity window…).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ClockTime {
    pub hour: u8,
    pub minute: u8,
}

impl From<(u8, u8)> for ClockTime {
    fn from((hour, minute): (u8, u8)) -> Self {
        Self { hour, minute }
    }
}

impl From<ClockTime> for (u8, u8) {
    fn from(t: ClockTime) -> Self {
        (t.hour, t.minute)
    }
}

/// One forecast day (°C, raw ZeTime condition code).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct DayForecast {
    pub min_c: i8,
    pub max_c: i8,
    pub condition: u8,
}

/// Weather pushed to the watch (0x77). `forecasts` beyond 3 are dropped,
/// missing ones repeat today's values.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WeatherReport {
    pub location: String,
    pub current_c: i8,
    pub min_c: i8,
    pub max_c: i8,
    pub condition: u8,
    pub forecasts: Vec<DayForecast>,
}

/// One stored alarm/reminder (0x97 read).
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AlarmEntry {
    pub slot: u8,
    /// 4 = alarm, other values = reminder kinds of the official app.
    pub alarm_type: u8,
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    /// Weekday bitmask: bit0 Mon … bit6 Sun. 0 never rings.
    pub cycle: u8,
    pub enabled: bool,
    pub shock: u8,
}

impl From<parse::AlarmEntry> for AlarmEntry {
    fn from(a: parse::AlarmEntry) -> Self {
        Self {
            slot: a.slot,
            alarm_type: a.alarm_type,
            year: a.year,
            month: a.month,
            day: a.day,
            hour: a.hour,
            minute: a.minute,
            cycle: a.cycle,
            enabled: a.enabled,
            shock: a.shock,
        }
    }
}

impl AlarmEntry {
    /// The 10 field bytes the delete-by-collision frame expects.
    fn fields(&self) -> [u8; 10] {
        let y = self.year.to_le_bytes();
        [
            self.alarm_type,
            y[0],
            y[1],
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

/// Every command the app may send on TX (0x8001 + ack byte). Time-stamped
/// pushes (time sync, notifications, calls) keep their dedicated encoders.
#[derive(Debug, Clone, uniffi::Enum)]
pub enum WatchCommand {
    GetWatchId,
    GetFirmwareVersion,
    GetHardwareVersion,
    GetBattery,
    GetAvailableData,
    GetStepData,
    GetSleepData,
    GetHeartRateData,
    GetAlarmCount,
    GetAlarms,
    GetButtonFunctions,
    /// 0xDA — quick-reply metadata `[count][crc:2le]×count`.
    GetQuickReplies,
    /// 0xDB GET — `None` streams every stored reply, `Some(crc)` only the
    /// entry whose text CRC matches. One reply frame per entry:
    /// `[index][crc:2le][text]` (see `parse_quick_reply`).
    GetQuickReply {
        crc: Option<u16>,
    },
    /// 0xDB SET sub0 — insert `text` at 1-based `index` (later replies
    /// shift down; a full list drops its 10th). Rewrites the region.
    InsertQuickReply {
        index: u8,
        text: String,
    },
    /// 0xDB SET sub1 — replace the text of the reply identified by `crc`
    /// (stable id — indices shift on insert/delete).
    UpdateQuickReply {
        crc: u16,
        text: String,
    },
    /// 0xDB SET sub2 — delete the reply identified by `crc`.
    DeleteQuickReply {
        crc: u16,
    },
    /// 0xEE GET — lab-only memory peek `[addr:4be][len]` (len ≤ 0x40
    /// confirmed live). Unsafe on unmapped addresses (bus fault → boot
    /// hang); the app only dumps ranges already validated over nRF
    /// Connect.
    ReadMemory {
        addr: u32,
        len: u8,
    },
    /// 0x94 GET `checkInit` — reply `[initFlag]` (0 = écran QR / init en
    /// attente, 1 = init terminée). Confirmé live.
    GetInitFlag,
    /// 0x94 SET `[0x00]` — complète l'init out-of-box (défauts + display +
    /// flag persisté) : quitte le QR vers le cadran. Équivalent de l'init
    /// de l'app officielle ; vérif. live post-factory-reset.
    CompleteInit,
    /// 0x93 SET `[0x02]` — QR bind start (Android pairing flow).
    QrBindStart,
    /// 0x94 SET `[0x01]` — bind end, last step of the QR pairing sequence
    /// (QrBindStart → SetTime → BindEnd). Distinct from `CompleteInit`.
    BindEnd,
    ReadSetting {
        setting: SettingKind,
    },
    /// 0x50 GET — daily goals read-back (15-byte reply).
    GetGoals,
    /// 0x30 GET — user profile read-back (5-byte reply).
    GetUserInfo,
    /// 0x21 GET — night-mode config `[color][has_dial]`.
    GetNightMode,
    FindDevice {
        start: bool,
    },
    SetWrist {
        wrist: Wrist,
    },
    /// Seconds, ≥ 10.
    SetScreenTime {
        seconds: u16,
    },
    SetUserInfo {
        gender: Gender,
        age: u8,
        height_cm: u8,
        weight_kg: f32,
    },
    /// `value` in watch units: steps in hundreds, km, h, min, kcal.
    SetGoal {
        kind: GoalKind,
        value: u16,
    },
    SetHeartRateLimits {
        max: u8,
        min: u8,
        alarm: bool,
    },
    /// Minutes between measurements; 0 disables.
    SetHeartRateInterval {
        minutes: u8,
    },
    SetAnalogMode {
        mode: AnalogMode,
    },
    SetActivityTracking {
        enabled: bool,
    },
    /// 0x1A CONTROL_DEVICE — raw sub-command byte (decompiled SDK):
    /// 3 = jump to real-time heart rate, 15 = exit it, 11 = camera jump.
    /// Heart-rate subs NOT live-verified on A2.0.55.
    ControlDevice {
        sub: u8,
    },
    SetDisplayOnMovement {
        enabled: bool,
    },
    /// One bit of the 0x90 switch mask (calls=4 … calendar=9, see core docs).
    SetSwitchSetting {
        index: u8,
        enabled: bool,
    },
    SetDoNotDisturb {
        enabled: bool,
        start: ClockTime,
        end: ClockTime,
    },
    SetCaloriesType {
        kind: CaloriesType,
    },
    SetTimeFormat {
        format: TimeFormat,
    },
    SetDateFormat {
        format: DateFormat,
    },
    /// `days`: bit0 Mon … bit6 Sun.
    SetInactivityAlert {
        enabled: bool,
        threshold_min: u8,
        start: ClockTime,
        end: ClockTime,
        days: u8,
    },
    /// Fenêtre de détection auto-sleep (`0x58`) — à envoyer avec
    /// `SetSwitchSetting { index: 3 }` pour activer la détection ;
    /// `days` = bitmask jours (127 = tous les jours).
    SetAutoSleepWindow {
        enter: ClockTime,
        exit: ClockTime,
        days: u8,
    },
    SetShockStrength {
        level: u8,
    },
    SetSignaling {
        event: SignalEvent,
        pattern: SignalPattern,
    },
    SetLanguage {
        language: Language,
    },
    /// Home-city line on digital faces; `offset_minutes` = that city's UTC
    /// offset (refresh on DST flips).
    SetTimezone {
        offset_minutes: i16,
        city: String,
    },
    /// `days`: bit0 Mon … bit6 Sun; 0 = ring once.
    /// `alarm_type`: 4 = alarm, 1 = medicine, 2 = water, 7 = custom.
    /// `content` is appended verbatim — only rendered for custom reminders.
    AddAlarm {
        hour: u8,
        minute: u8,
        days: u8,
        enabled: bool,
        pattern: SignalPattern,
        alarm_type: AlarmKind,
        content: String,
    },
    /// 0x97 edit (Android `encodeAlarmEdit`, live-confirmed):
    /// `[0x01] + existing.fields() + new fields + content`. `existing`
    /// must be the entry as read back by `GetAlarms` — the field block is
    /// the alarm's identity (there is no stable id).
    EditAlarm {
        existing: AlarmEntry,
        hour: u8,
        minute: u8,
        days: u8,
        enabled: bool,
        pattern: SignalPattern,
        alarm_type: AlarmKind,
        content: String,
    },
    /// Delete the alarm as read back by `GetAlarms`.
    DeleteAlarm {
        alarm: AlarmEntry,
    },
    SendWeather {
        report: WeatherReport,
    },
    /// `first` = true for the first event of a batch (opcode 1), then 2.
    CalendarEvent {
        first: bool,
        at: WatchDateTime,
        title: String,
    },
    /// 0x99 opcode 4 — clear the watch's calendar (Android full-replace
    /// flow: clear → day events → month view).
    ClearCalendar,
    /// 0x98 — calendar month view: exactly 8 u32 day-bitmasks
    /// ([this month, last month, next month … +5]); bit `dayOfMonth-1`
    /// per event day.
    CalendarMonthView {
        mask: Vec<u32>,
    },
    /// 0x21 — night-mode screen: crown press shows a colored face.
    /// `color`: 1 = blue, 2 = green, 3 = white; `has_dial` = tick ring.
    SetNightMode {
        color: u8,
        has_dial: bool,
    },
    /// 0x0C — units: false = metric, true = imperial.
    SetUnits {
        imperial: bool,
    },
    /// 0x09 — watch notification/alarm volume level.
    SetWatchVolume {
        level: u8,
    },
    /// 0x07 — screen brightness level.
    SetBrightness {
        level: u8,
    },
    /// 0x14 — alarm snooze duration (raw byte).
    SetSnooze {
        value: u8,
    },
    /// 0x19 — notification text size level.
    SetTextSize {
        level: u8,
    },
    /// 0x13 — bright-screen time (write-only; GET times out upstream).
    SetBrightScreenTime {
        value: u8,
    },
    /// 0x2E — 1=UP 2=BOTTOM 3=crown tap 4=crown hold; function 0-19.
    SetButtonFunction {
        button: u8,
        function: u8,
    },
    DeleteStepData,
    DeleteSleepData,
    DeleteHeartRateData,
}

impl WatchCommand {
    fn to_core(&self) -> Result<Command, ZeTimeError> {
        use WatchCommand as W;
        Ok(match self.clone() {
            W::GetWatchId => Command::GetWatchId,
            W::GetFirmwareVersion => Command::GetFirmwareVersion,
            W::GetHardwareVersion => Command::GetHardwareVersion,
            W::GetBattery => Command::GetBattery,
            W::GetAvailableData => Command::GetAvailableData,
            W::GetStepData => Command::GetStepData,
            W::GetSleepData => Command::GetSleepData,
            W::GetHeartRateData => Command::GetHeartRateData,
            W::GetAlarmCount => Command::GetAlarmCount,
            W::GetAlarms => Command::GetAlarms,
            W::GetButtonFunctions => Command::GetButtonFunctions,
            W::GetQuickReplies => Command::GetQuickReplies,
            W::GetQuickReply { crc } => Command::GetQuickReply { crc },
            W::InsertQuickReply { index, text } => Command::InsertQuickReply { index, text },
            W::UpdateQuickReply { crc, text } => Command::UpdateQuickReply { crc, text },
            W::DeleteQuickReply { crc } => Command::DeleteQuickReply { crc },
            W::ReadMemory { addr, len } => Command::PeekMemory { addr, len },
            W::GetInitFlag => Command::GetInitFlag,
            W::CompleteInit => Command::CompleteInit,
            W::QrBindStart => Command::QrBindStart,
            W::BindEnd => Command::BindEnd,
            W::GetGoals => Command::GetGoals,
            W::GetUserInfo => Command::GetUserInfo,
            W::GetNightMode => Command::GetNightMode,
            W::ReadSetting { setting } => Command::ReadSetting(setting.into()),
            W::FindDevice { start } => Command::FindDevice { start },
            W::SetWrist { wrist } => Command::SetWrist(wrist.into()),
            W::SetScreenTime { seconds } => Command::SetScreenTime(seconds),
            W::SetUserInfo {
                gender,
                age,
                height_cm,
                weight_kg,
            } => Command::SetUserInfo {
                gender: gender.into(),
                age,
                height_cm,
                weight_kg,
            },
            W::SetGoal { kind, value } => Command::SetGoal {
                kind: kind.into(),
                value,
            },
            W::SetHeartRateLimits { max, min, alarm } => {
                Command::SetHeartRateLimits { max, min, alarm }
            }
            W::SetHeartRateInterval { minutes } => Command::SetHeartRateInterval { minutes },
            W::SetAnalogMode { mode } => Command::SetAnalogMode(mode.into()),
            W::SetActivityTracking { enabled } => Command::SetActivityTracking(enabled),
            W::ControlDevice { sub } => Command::ControlDevice { sub },
            W::SetDisplayOnMovement { enabled } => Command::SetDisplayOnMovement(enabled),
            W::SetSwitchSetting { index, enabled } => Command::SetSwitchSetting { index, enabled },
            W::SetDoNotDisturb {
                enabled,
                start,
                end,
            } => Command::SetDoNotDisturb {
                enabled,
                start: start.into(),
                end: end.into(),
            },
            W::SetCaloriesType { kind } => Command::SetCaloriesType(kind.into()),
            W::SetTimeFormat { format } => Command::SetTimeFormat(format.into()),
            W::SetDateFormat { format } => Command::SetDateFormat(format.into()),
            W::SetInactivityAlert {
                enabled,
                threshold_min,
                start,
                end,
                days,
            } => Command::SetInactivityAlert {
                enabled,
                threshold_min,
                start: start.into(),
                end: end.into(),
                days,
            },
            W::SetAutoSleepWindow { enter, exit, days } => Command::SetAutoSleepWindow {
                enter: enter.into(),
                exit: exit.into(),
                days,
            },
            W::SetShockStrength { level } => Command::SetShockStrength(level),
            W::SetSignaling { event, pattern } => Command::SetSignaling {
                event: event.into(),
                pattern: pattern.into(),
            },
            W::SetLanguage { language } => Command::SetLanguage(language.into()),
            W::SetTimezone {
                offset_minutes,
                city,
            } => Command::SetTimezone {
                offset_minutes,
                city,
            },
            W::AddAlarm {
                hour,
                minute,
                days,
                enabled,
                pattern,
                alarm_type,
                content,
            } => Command::AddAlarm {
                hour,
                minute,
                days,
                enabled,
                pattern: pattern.into(),
                alarm_type: alarm_type.into(),
                content,
            },
            W::EditAlarm {
                existing,
                hour,
                minute,
                days,
                enabled,
                pattern,
                alarm_type,
                content,
            } => Command::EditAlarm {
                existing: existing.fields(),
                hour,
                minute,
                days,
                enabled,
                pattern: pattern.into(),
                alarm_type: alarm_type.into(),
                content,
            },
            W::DeleteAlarm { alarm } => Command::DeleteAlarm {
                fields: alarm.fields(),
            },
            W::SendWeather { report } => {
                let today = DayForecast {
                    min_c: report.min_c,
                    max_c: report.max_c,
                    condition: report.condition,
                };
                let day = |i: usize| {
                    let f = report.forecasts.get(i).copied().unwrap_or(today);
                    (f.min_c, f.max_c, f.condition)
                };
                Command::SendWeather {
                    location: report.location,
                    current_c: report.current_c,
                    min_c: report.min_c,
                    max_c: report.max_c,
                    condition: report.condition,
                    forecasts: [day(0), day(1), day(2)],
                }
            }
            W::CalendarEvent { first, at, title } => Command::CalendarEvent {
                opcode: if first { 1 } else { 2 },
                at: at.try_into()?,
                title,
            },
            W::ClearCalendar => Command::CalendarEvent {
                opcode: 4,
                at: NaiveDateTime::default(),
                title: String::new(),
            },
            W::CalendarMonthView { mask } => {
                let mask: [u32; 8] = mask.try_into().map_err(|_| {
                    ZeTimeError::InvalidValue("calendar month mask needs 8 u32".into())
                })?;
                Command::CalendarMonthView { mask }
            }
            W::SetNightMode { color, has_dial } => Command::SetNightMode { color, has_dial },
            W::SetUnits { imperial } => Command::SetUnits { imperial },
            W::SetWatchVolume { level } => Command::SetWatchVolume { level },
            W::SetBrightness { level } => Command::SetBrightness { level },
            W::SetSnooze { value } => Command::SetSnooze { value },
            W::SetTextSize { level } => Command::SetTextSize { level },
            W::SetBrightScreenTime { value } => Command::SetBrightScreenTime { value },
            W::SetButtonFunction { button, function } => {
                Command::SetButtonFunction { button, function }
            }
            W::DeleteStepData => Command::DeleteStepData,
            W::DeleteSleepData => Command::DeleteSleepData,
            W::DeleteHeartRateData => Command::DeleteHeartRateData,
        })
    }
}

/// Encode a command for TX (0x8001, chunked, followed by the ack byte).
#[uniffi::export]
pub fn encode_command(command: WatchCommand) -> Result<Vec<u8>, ZeTimeError> {
    Ok(command.to_core()?.encode(NaiveDateTime::default())?)
}

/// Command byte of `command` — what its reply/ack will carry.
#[uniffi::export]
pub fn command_code(command: WatchCommand) -> Result<u8, ZeTimeError> {
    Ok(command.to_core()?.code())
}

/// True for REQUEST commands (answered with data, 0x80), false for SEND
/// commands (answered with a return-code ack).
#[uniffi::export]
pub fn command_is_request(command: WatchCommand) -> Result<bool, ZeTimeError> {
    Ok(command.to_core()?.kind() == protocol::CMD_REQUEST)
}

// ---------------------------------------------------------------------------
// Reply parsers (payload = frame bytes 5..len-1, as in WatchFrame::Other)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct AvailableData {
    pub steps: u16,
    pub sleep: u16,
    pub heart_rate: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct StepRecord {
    pub index: u16,
    pub time: WatchDateTime,
    pub steps: u32,
    pub calories: u32,
    pub distance_m: u32,
    pub active_min: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum SleepKind {
    Deep,
    Light,
    Begin,
    End,
    Unknown { code: u8 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct SleepRecord {
    pub index: u16,
    pub time: WatchDateTime,
    pub kind: SleepKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct HeartRateRecord {
    pub index: u16,
    pub time: WatchDateTime,
    pub bpm: u8,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ButtonFunction {
    pub button: u8,
    pub function: u8,
}

/// A setting read back from the watch. Enum-like values stay raw codes
/// (the app maps the ones it knows).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum SettingValue {
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
        start: ClockTime,
        end: ClockTime,
    },
    AnalogMode {
        code: u8,
    },
    ActivityTracking {
        enabled: bool,
    },
    ScreenTime {
        seconds: u16,
    },
    Wrist {
        code: u8,
    },
    HeartRateInterval {
        minutes: u8,
    },
    Inactivity {
        enabled: bool,
        days: u8,
        threshold_min: u8,
        start: ClockTime,
        end: ClockTime,
    },
    CaloriesType {
        code: u8,
    },
    DisplayOnMovement {
        enabled: bool,
    },
    NotificationSwitches {
        calls: bool,
        missed_calls: bool,
        sms: bool,
        social: bool,
        email: bool,
        calendar: bool,
    },
    /// 0x90 mask bits 2-3 : suivi sommeil manuel / auto-sleep.
    SleepSwitches {
        tracking: bool,
        auto_sleep: bool,
    },
    /// Fenêtre auto-sleep lue sur 0x58.
    AutoSleepWindow {
        enter: ClockTime,
        exit: ClockTime,
        days: u8,
    },
    /// Réglage simple sur un octet (unités, volume, luminosité, rappel,
    /// taille du texte) — la valeur brute est renvoyée, l'app la mappe.
    Byte {
        value: u8,
    },
    Raw {
        payload: Vec<u8>,
    },
}

impl From<parse::Setting> for SettingValue {
    fn from(s: parse::Setting) -> Self {
        use parse::Setting as S;
        match s {
            S::TimeSurface {
                date_format,
                time_12h,
            } => Self::TimeSurface {
                date_format,
                time_12h,
            },
            S::Signaling {
                antiloss,
                call,
                missed_call,
                sms,
                social,
                email,
                calendar,
                inactivity,
                low_power,
            } => Self::Signaling {
                antiloss,
                call,
                missed_call,
                sms,
                social,
                email,
                calendar,
                inactivity,
                low_power,
            },
            S::DoNotDisturb {
                enabled,
                start,
                end,
            } => Self::DoNotDisturb {
                enabled,
                start: start.into(),
                end: end.into(),
            },
            S::AnalogMode(code) => Self::AnalogMode { code },
            S::ActivityTracking(enabled) => Self::ActivityTracking { enabled },
            S::ScreenTime(seconds) => Self::ScreenTime { seconds },
            S::Wrist(code) => Self::Wrist { code },
            S::HeartRateInterval(minutes) => Self::HeartRateInterval { minutes },
            S::Inactivity {
                enabled,
                days,
                threshold_min,
                start,
                end,
            } => Self::Inactivity {
                enabled,
                days,
                threshold_min,
                start: start.into(),
                end: end.into(),
            },
            S::CaloriesType(code) => Self::CaloriesType { code },
            S::DisplayOnMovement(enabled) => Self::DisplayOnMovement { enabled },
            S::NotificationSwitches {
                calls,
                missed_calls,
                sms,
                social,
                email,
                calendar,
            } => Self::NotificationSwitches {
                calls,
                missed_calls,
                sms,
                social,
                email,
                calendar,
            },
            S::SleepSwitches {
                tracking,
                auto_sleep,
            } => Self::SleepSwitches {
                tracking,
                auto_sleep,
            },
            S::AutoSleepWindow { enter, exit, days } => Self::AutoSleepWindow {
                enter: enter.into(),
                exit: exit.into(),
                days,
            },
            S::Byte(value) => Self::Byte { value },
            S::Raw(payload) => Self::Raw { payload },
        }
    }
}

#[uniffi::export]
pub fn parse_watch_id(payload: Vec<u8>) -> Result<String, ZeTimeError> {
    Ok(parse::parse_watch_id(&payload)?)
}

/// Firmware or hardware version string (payload[0] echoes which).
#[uniffi::export]
pub fn parse_version(payload: Vec<u8>) -> Result<String, ZeTimeError> {
    Ok(parse::parse_version(&payload)?)
}

#[uniffi::export]
pub fn parse_available_data(payload: Vec<u8>) -> Result<AvailableData, ZeTimeError> {
    let d = parse::parse_available_data(&payload)?;
    Ok(AvailableData {
        steps: d.steps,
        sleep: d.sleep,
        heart_rate: d.heart_rate,
    })
}

#[uniffi::export]
pub fn parse_step_record(payload: Vec<u8>) -> Result<StepRecord, ZeTimeError> {
    let r = parse::parse_step_record(&payload)?;
    Ok(StepRecord {
        index: r.index,
        time: r.timestamp.into(),
        steps: r.steps,
        calories: r.calories,
        distance_m: r.distance_m,
        active_min: r.active_min,
    })
}

#[uniffi::export]
pub fn parse_sleep_record(payload: Vec<u8>) -> Result<SleepRecord, ZeTimeError> {
    let r = parse::parse_sleep_record(&payload)?;
    Ok(SleepRecord {
        index: r.index,
        time: r.timestamp.into(),
        kind: match r.kind {
            parse::SleepKind::Deep => SleepKind::Deep,
            parse::SleepKind::Light => SleepKind::Light,
            parse::SleepKind::Begin => SleepKind::Begin,
            parse::SleepKind::End => SleepKind::End,
            parse::SleepKind::Unknown(code) => SleepKind::Unknown { code },
        },
    })
}

/// One frame carries one or two records.
#[uniffi::export]
pub fn parse_heart_rate_records(payload: Vec<u8>) -> Result<Vec<HeartRateRecord>, ZeTimeError> {
    Ok(parse::parse_heart_rate_records(&payload)?
        .into_iter()
        .map(|r| HeartRateRecord {
            index: r.index,
            time: r.timestamp.into(),
            bpm: r.bpm,
        })
        .collect())
}

#[uniffi::export]
pub fn parse_alarm(payload: Vec<u8>) -> Result<AlarmEntry, ZeTimeError> {
    Ok(parse::parse_alarm(&payload)?.into())
}

#[uniffi::export]
pub fn parse_button_functions(payload: Vec<u8>) -> Vec<ButtonFunction> {
    parse::parse_button_functions(&payload)
        .into_iter()
        .map(|b| ButtonFunction {
            button: b.button,
            function: b.function,
        })
        .collect()
}

/// Quick-reply metadata from a 0xDA reply — one text CRC per stored
/// reply, in slot order (the stable ids used by read/update/delete).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuickReplyMeta {
    pub crcs: Vec<u16>,
}

/// One quick reply from a 0xDB reply frame `[index][crc:2le][text]`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct QuickReply {
    /// 1-based slot — unstable across insert/delete.
    pub index: u8,
    /// CRC-16/CCITT-FALSE of `text` — pass to Update/Delete/GetQuickReply.
    pub crc: u16,
    pub text: String,
}

#[uniffi::export]
pub fn parse_quick_reply_meta(payload: Vec<u8>) -> Result<QuickReplyMeta, ZeTimeError> {
    let m = parse::parse_quick_reply_meta(&payload)?;
    Ok(QuickReplyMeta { crcs: m.crcs })
}

#[uniffi::export]
pub fn parse_quick_reply(payload: Vec<u8>) -> Result<QuickReply, ZeTimeError> {
    let r = parse::parse_quick_reply(&payload)?;
    Ok(QuickReply {
        index: r.index,
        crc: r.crc,
        text: r.text,
    })
}

/// CRC-16/CCITT-FALSE of a reply text — the id the watch stores and the
/// read/update/delete commands address. Computed over the UTF-16LE bytes
/// the slot holds, same as the wire encoding.
#[uniffi::export]
pub fn quick_reply_crc(text: String) -> u16 {
    protocol::crc16_ccitt(
        &text
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect::<Vec<u8>>(),
    )
}

#[uniffi::export]
pub fn parse_setting(setting: SettingKind, payload: Vec<u8>) -> Result<SettingValue, ZeTimeError> {
    Ok(parse::parse_setting(setting.into(), &payload)?.into())
}

// ---------------------------------------------------------------------------
// Read-back records (goals / profile / night mode)
// ---------------------------------------------------------------------------

/// Daily goals read back from the watch (0x50 GET). Values are already in
/// display units: steps count, kcal, whole km, hours, minutes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct Goals {
    pub steps: u16,
    pub calories: u16,
    pub distance_km: u16,
    pub sleep_hours: u16,
    pub active_minutes: u16,
}

/// User profile read back from the watch (0x30 GET).
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct UserInfo {
    /// 0 = male, 1 = female, 2 = other.
    pub sex: u8,
    pub age: u8,
    pub height_cm: u8,
    pub weight_kg: f32,
}

/// Night-mode screen config (0x21): `color` 1 = blue, 2 = green, 3 = white;
/// `has_dial` = minute-tick ring.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct NightMode {
    pub color: u8,
    pub has_dial: bool,
}

#[uniffi::export]
pub fn parse_goals(payload: Vec<u8>) -> Result<Goals, ZeTimeError> {
    let g = parse::parse_goals(&payload)?;
    Ok(Goals {
        steps: g.steps,
        calories: g.calories,
        distance_km: g.distance_km,
        sleep_hours: g.sleep_hours,
        active_minutes: g.active_minutes,
    })
}

#[uniffi::export]
pub fn parse_user_info(payload: Vec<u8>) -> Result<UserInfo, ZeTimeError> {
    let u = parse::parse_user_info(&payload)?;
    Ok(UserInfo {
        sex: u.sex,
        age: u.age,
        height_cm: u.height_cm,
        weight_kg: u.weight_kg,
    })
}

#[uniffi::export]
pub fn parse_night_mode(payload: Vec<u8>) -> Result<NightMode, ZeTimeError> {
    let n = parse::parse_night_mode(&payload)?;
    Ok(NightMode {
        color: n.color,
        has_dial: n.has_dial,
    })
}

/// Command byte a `ReadSetting` reply for `setting` carries.
#[uniffi::export]
pub fn setting_command_code(setting: SettingKind) -> u8 {
    SettingId::from(setting).cmd()
}

// ---------------------------------------------------------------------------
// Weather
// ---------------------------------------------------------------------------

/// WMO weather code (Open-Meteo `weather_code`) → ZeTime condition icon,
/// firmware ≥ R1.7 table (Gadgetbridge `WeatherMapper.mapToZeTimeCondition`,
/// whose OpenWeatherMap groups are matched to the WMO codes here).
#[uniffi::export]
pub fn zetime_condition_from_wmo(wmo_code: u8, is_day: bool) -> u8 {
    match wmo_code {
        0 => {
            if is_day {
                19 // sunny
            } else {
                18 // clear night
            }
        }
        1 | 2 => {
            if is_day {
                17 // partly cloudy (day)
            } else {
                16 // partly cloudy (night)
            }
        }
        3 => 15,                          // cloudy
        45 | 48 => 13,                    // foggy
        51 | 53 | 55 => 7,                // drizzle
        56 | 57 | 66 | 67 => 6,           // freezing drizzle/rain
        61 | 63 | 65 | 80 | 81 | 82 => 8, // rain / showers
        71 | 73 => 11,                    // snow
        75 => 24,                         // heavy snow
        77 => 9,                          // snow grains → flurries
        85 | 86 => 23,                    // snow showers
        95 => 20,                         // thundershower
        96 | 99 => 3,                     // thunderstorm with hail
        _ => 5,                           // unavailable
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_matches_core() {
        let cases: Vec<(WatchCommand, Command)> = vec![
            (
                WatchCommand::GetButtonFunctions,
                Command::GetButtonFunctions,
            ),
            (
                WatchCommand::SetScreenTime { seconds: 15 },
                Command::SetScreenTime(15),
            ),
            (
                WatchCommand::SetDoNotDisturb {
                    enabled: true,
                    start: ClockTime {
                        hour: 22,
                        minute: 30,
                    },
                    end: ClockTime { hour: 7, minute: 0 },
                },
                Command::SetDoNotDisturb {
                    enabled: true,
                    start: (22, 30),
                    end: (7, 0),
                },
            ),
            (
                WatchCommand::SetLanguage {
                    language: Language::Fr,
                },
                Command::SetLanguage(protocol::Language::Fr),
            ),
        ];
        for (ffi, core) in cases {
            assert_eq!(
                encode_command(ffi).unwrap(),
                core.encode(NaiveDateTime::default()).unwrap()
            );
        }
    }

    #[test]
    fn get_buttons_frame() {
        assert_eq!(
            encode_command(WatchCommand::GetButtonFunctions).unwrap(),
            [0x6F, 0x2E, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        assert!(command_is_request(WatchCommand::GetButtonFunctions).unwrap());
        assert!(!command_is_request(WatchCommand::FindDevice { start: true }).unwrap());
    }

    #[test]
    fn weather_pads_forecasts() {
        let frame = encode_command(WatchCommand::SendWeather {
            report: WeatherReport {
                location: "GENEVA".into(),
                current_c: 12,
                min_c: 8,
                max_c: 15,
                condition: 17,
                forecasts: vec![DayForecast {
                    min_c: 5,
                    max_c: 10,
                    condition: 8,
                }],
            },
        })
        .unwrap();
        // header(5) + unit,cur,min,max,cond(5) + 3×5 forecasts + "GENEVA" + end
        assert_eq!(frame.len(), 5 + 5 + 15 + 6 + 1);
        assert_eq!(&frame[10..15], &[0x00, 0xFF, 5, 10, 8]);
        assert_eq!(&frame[15..20], &[0x00, 0xFF, 8, 15, 17]); // padded with today
    }

    #[test]
    fn delete_alarm_uses_fields() {
        let alarm = AlarmEntry {
            slot: 1,
            alarm_type: 4,
            year: 0,
            month: 0,
            day: 0,
            hour: 7,
            minute: 30,
            cycle: 0x1F,
            enabled: true,
            shock: 2,
        };
        let frame = encode_command(WatchCommand::DeleteAlarm { alarm }).unwrap();
        let fields = [4, 0, 0, 0, 0, 7, 30, 0x1F, 1, 2];
        assert_eq!(frame[5], 0x02);
        assert_eq!(&frame[6..16], &fields);
        assert_eq!(&frame[16..26], &fields);
    }

    #[test]
    fn parses_scan_replies() {
        // 0x2E GET reply captured during the opcode scan
        let b = parse_button_functions(vec![2, 1, 1, 2, 2, 3, 2, 3, 0, 2, 4, 0]);
        assert_eq!(
            b[1],
            ButtonFunction {
                button: 2,
                function: 3
            }
        );
        // 0x25 screen time reply `0A 00` = 10 s
        assert_eq!(
            parse_setting(SettingKind::ScreenTime, vec![0x0A, 0x00]).unwrap(),
            SettingValue::ScreenTime { seconds: 10 }
        );
        // 0x31 wrist reply `00`
        assert_eq!(
            parse_setting(SettingKind::Wrist, vec![0]).unwrap(),
            SettingValue::Wrist { code: 0 }
        );
    }

    #[test]
    fn quick_reply_frames_and_parsers() {
        let cases: Vec<(WatchCommand, Command)> = vec![
            (WatchCommand::GetQuickReplies, Command::GetQuickReplies),
            (
                WatchCommand::GetQuickReply { crc: None },
                Command::GetQuickReply { crc: None },
            ),
            (
                WatchCommand::GetQuickReply { crc: Some(0x29B1) },
                Command::GetQuickReply { crc: Some(0x29B1) },
            ),
            (
                WatchCommand::InsertQuickReply {
                    index: 2,
                    text: "OK".into(),
                },
                Command::InsertQuickReply {
                    index: 2,
                    text: "OK".into(),
                },
            ),
            (
                WatchCommand::UpdateQuickReply {
                    crc: 0x29B1,
                    text: "Oui".into(),
                },
                Command::UpdateQuickReply {
                    crc: 0x29B1,
                    text: "Oui".into(),
                },
            ),
            (
                WatchCommand::DeleteQuickReply { crc: 0x29B1 },
                Command::DeleteQuickReply { crc: 0x29B1 },
            ),
            (
                WatchCommand::ReadMemory {
                    addr: 0x200,
                    len: 0x40,
                },
                Command::PeekMemory {
                    addr: 0x200,
                    len: 0x40,
                },
            ),
        ];
        for (ffi, core) in cases {
            assert_eq!(
                encode_command(ffi).unwrap(),
                core.encode(NaiveDateTime::default()).unwrap()
            );
        }
        assert!(command_is_request(WatchCommand::GetQuickReplies).unwrap());
        assert!(!command_is_request(WatchCommand::DeleteQuickReply { crc: 0 }).unwrap());
        // CRC-16/CCITT-FALSE over the UTF-16LE bytes (0x4D64 for
        // "123456789".utf16-le — differs from the ASCII vector 0x29B1).
        assert_eq!(quick_reply_crc("123456789".into()), 0x4D64);
        let r = parse_quick_reply(vec![2, 0xB1, 0x29, b'O', 0, b'K', 0]).unwrap();
        assert_eq!((r.index, r.crc, r.text.as_str()), (2, 0x29B1, "OK"));
        assert_eq!(
            parse_quick_reply_meta(vec![1, 0xB1, 0x29]).unwrap().crcs,
            [0x29B1]
        );
    }

    #[test]
    fn calendar_rejects_bad_date() {
        let at = WatchDateTime {
            year: 2026,
            month: 2,
            day: 30,
            hour: 9,
            minute: 0,
            second: 0,
        };
        assert!(matches!(
            encode_command(WatchCommand::CalendarEvent {
                first: true,
                at,
                title: "x".into()
            }),
            Err(ZeTimeError::InvalidValue(_))
        ));
    }

    #[test]
    fn wmo_mapping() {
        assert_eq!(zetime_condition_from_wmo(0, true), 19);
        assert_eq!(zetime_condition_from_wmo(0, false), 18);
        assert_eq!(zetime_condition_from_wmo(63, true), 8);
        assert_eq!(zetime_condition_from_wmo(95, true), 20);
        assert_eq!(zetime_condition_from_wmo(200, true), 5);
    }

    #[test]
    fn signal_pattern_roundtrip() {
        for p in [
            SignalPattern::VibrateOnce,
            SignalPattern::Beep,
            SignalPattern::None,
        ] {
            assert_eq!(signal_pattern_from_code(signal_pattern_code(p)), Some(p));
        }
        assert_eq!(signal_pattern_from_code(0), None);
    }
}
