//! Commands sent to the watch (encode) — layouts verified against
//! Gadgetbridge's ZeTimeDeviceSupport.java.

use super::{
    CMD_ACTIVITY_TRACKING, CMD_ANALOG_MODE, CMD_AUTO_SLEEP_WINDOW, CMD_AVAILABLE_DATA,
    CMD_BATTERY_POWER, CMD_BIND_START, CMD_BRIGHT_SCREEN_TIME, CMD_CALENDAR,
    CMD_CALENDAR_MONTH_VIEW, CMD_CALORIES_TYPE, CMD_CUSTOMIZE_BUTTON, CMD_DATE_TIME,
    CMD_DELETE_HEART_RATE_DATA, CMD_DELETE_SLEEP_DATA, CMD_DELETE_STEP_DATA, CMD_DEVICE_VERSION,
    CMD_DISPLAY_ON_MOVEMENT, CMD_DO_NOT_DISTURB, CMD_FIND_DEVICE, CMD_GOALS, CMD_HEART_RATE_DATA,
    CMD_HEART_RATE_INTERVAL, CMD_HEART_RATE_LIMITS, CMD_INACTIVITY, CMD_INIT, CMD_LANGUAGE,
    CMD_MEMORY_PEEK, CMD_MUSIC_CONTROL, CMD_NIGHT_MODE, CMD_PUSH_EX_MSG, CMD_QUICK_REPLY,
    CMD_QUICK_REPLY_META, CMD_REMIND_COUNT, CMD_REMINDERS, CMD_REQUEST, CMD_REQUEST_RESPOND,
    CMD_RETURN_CODE, CMD_SCREEN_BRIGHTNESS, CMD_SCREEN_TIME, CMD_SEND, CMD_SHOCK_STRENGTH,
    CMD_SIGNALING, CMD_SLEEP_DATA, CMD_SNOOZE, CMD_STEP_DATA, CMD_TEXT_SIZE, CMD_TIME_SURFACE,
    CMD_TIMEZONE, CMD_UNIT, CMD_UPGRADE_MODE, CMD_USER_INFO, CMD_WATCH_ID, CMD_WATCH_MOVE_KEEP,
    CMD_WATCH_MOVE_ONE, CMD_WATCH_VOLUME, CMD_WATCHFACE_DELETE, CMD_WATCHFACE_SET, CMD_WEATHER,
    CMD_WRIST, NOTIFICATION_CALL_OFF, NOTIFICATION_INCOME_CALL, ProtocolError,
    QUICK_REPLY_MAX_COUNT, QUICK_REPLY_TEXT_MAX, TYPE_RETURN_CODE, frame, timestamp15,
    truncate_utf8,
};
use chrono::{DateTime, Datelike, FixedOffset, NaiveDateTime, Timelike};
use clap::ValueEnum;

// ---------------------------------------------------------------------------
// Setting enums (wire code + clap CLI name)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Wrist {
    Left = 0,
    Right = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Gender {
    Male = 0,
    Female = 1,
    Other = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum GoalKind {
    Steps = 0,
    Calories = 1,
    Distance = 2,
    Sleep = 3,
    #[value(name = "active-time")]
    ActiveTime = 4,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum AnalogMode {
    Hands = 0,
    #[value(name = "hands-and-steps")]
    HandsAndSteps = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum CaloriesType {
    #[value(name = "active")]
    ActiveOnly = 0,
    All = 1,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum TimeFormat {
    #[value(name = "24h")]
    H24 = 1,
    #[value(name = "12h")]
    H12 = 2,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum DateFormat {
    YyMmDd = 1,
    DdMmYy = 2,
    MmDdYy = 3,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum SignalEvent {
    AntiLoss = 0,
    Call = 2,
    MissedCall = 3,
    Sms = 4,
    Social = 5,
    Email = 6,
    Calendar = 7,
    Inactivity = 8,
    LowPower = 9,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum SignalPattern {
    VibrateOnce = 2,
    VibrateTwice = 4,
    Vibrate = 7,
    BeepOnce = 9,
    BeepTwice = 10,
    Beep = 11,
    VibrateBeepOnce = 12,
    VibrateBeep = 13,
    None = 14,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum Language {
    En = 0,
    #[value(name = "zh-cn")]
    ZhCn = 1,
    #[value(name = "zh-tw")]
    ZhTw = 2,
    Ko = 3,
    Th = 4,
    Ja = 5,
    // A2.0.55/Appscomm SDK table (smali j.c.a): es=6, fr=7 — GB has them
    // swapped. Sending GB's 6 sets Spanish, not French.
    Es = 6,
    Fr = 7,
    De = 8,
    It = 9,
    Pl = 10,
    Pt = 11,
    Ru = 12,
    Nl = 13,
    Ar = 14,
    El = 15,
    He = 16,
    Sv = 17,
    Cs = 18,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum NotificationKind {
    #[value(name = "missed-call")]
    MissedCall = 0,
    Sms = 1,
    Social = 2,
    Email = 3,
    Calendar = 4,
    #[value(name = "wechat")]
    WeChat = 7,
    Viber = 8,
    Snapchat = 9,
    #[value(name = "whatsapp")]
    WhatsApp = 10,
    Qq = 11,
    Facebook = 12,
    Hangouts = 13,
    Gmail = 14,
    Messenger = 15,
    Instagram = 16,
    Twitter = 17,
    LinkedIn = 18,
    Uber = 19,
    Line = 20,
    Skype = 21,
}

/// Quick-reply slot text is UTF-16LE (live-verified A2.0.55: the picker
/// renders slot bytes as UTF-16, so ASCII writes display as CJK pairs).
/// The `len` field counts bytes — 180 max = 90 UTF-16 code units; reject
/// rather than truncate so a surrogate pair is never split.
fn quick_reply_text(text: &str) -> Result<Vec<u8>, ProtocolError> {
    let bytes: Vec<u8> = text.encode_utf16().flat_map(u16::to_le_bytes).collect();
    if bytes.len() > QUICK_REPLY_TEXT_MAX {
        return Err(ProtocolError::InvalidValue(format!(
            "quick-reply text too long: {} UTF-16 bytes (max {QUICK_REPLY_TEXT_MAX})",
            bytes.len()
        )));
    }
    Ok(bytes)
}

macro_rules! code {
    ($e:ty) => {
        impl $e {
            pub fn code(self) -> u8 {
                self as u8
            }
        }
    };
}
code!(Wrist);
code!(Gender);
code!(GoalKind);
code!(AnalogMode);
code!(CaloriesType);
code!(TimeFormat);
code!(DateFormat);
code!(SignalEvent);
code!(SignalPattern);
code!(Language);
code!(NotificationKind);

/// 0x97 alarm/reminder types (Android `Alarm.kt`): 4 = alarm, 1 = medicine,
/// 2 = water, 7 = custom reminder (renders `content`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, ValueEnum)]
pub enum AlarmKind {
    Medicine = 1,
    Water = 2,
    Alarm = 4,
    #[value(name = "custom")]
    Custom = 7,
}
code!(AlarmKind);

/// Settings that can be read back with a REQUEST frame (ZeTimeDeviceSupport.onReadConfiguration).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SettingId {
    TimeSurface,
    Signaling,
    DoNotDisturb,
    AnalogMode,
    ActivityTracking,
    ScreenTime,
    Wrist,
    HeartRateInterval,
    HeartRateLimits,
    Inactivity,
    CaloriesType,
    DisplayOnMovement,
    /// Also reads 0x90 — the same mask, decoded as notification categories.
    NotificationSwitches,
    /// Also reads 0x90 — the same mask, decoded as sleep switches (bits 2-3).
    SleepSwitches,
    /// Reads 0x58 — the auto-sleep detection window.
    AutoSleepWindow,
    /// 0x0C — units (0 = metric, 1 = imperial).
    Units,
    /// 0x09 — watch volume level.
    Volume,
    /// 0x07 — screen brightness level.
    Brightness,
    /// 0x14 — alarm snooze duration.
    Snooze,
    /// 0x19 — notification text size.
    TextSize,
    /// 0x13 — bright-screen time. Write-only upstream (GET times out) —
    /// kept for SET symmetry, not in `ALL`.
    BrightScreenTime,
}

impl SettingId {
    pub const ALL: [SettingId; 20] = [
        Self::TimeSurface,
        Self::Signaling,
        Self::DoNotDisturb,
        Self::AnalogMode,
        Self::ActivityTracking,
        Self::ScreenTime,
        Self::Wrist,
        Self::HeartRateInterval,
        Self::HeartRateLimits,
        Self::Inactivity,
        Self::CaloriesType,
        Self::DisplayOnMovement,
        Self::NotificationSwitches,
        Self::SleepSwitches,
        Self::AutoSleepWindow,
        Self::Units,
        Self::Volume,
        Self::Brightness,
        Self::Snooze,
        Self::TextSize,
    ];

    pub fn cmd(self) -> u8 {
        match self {
            Self::TimeSurface => CMD_TIME_SURFACE,
            Self::Signaling => CMD_SIGNALING,
            Self::DoNotDisturb => CMD_DO_NOT_DISTURB,
            Self::AnalogMode => CMD_ANALOG_MODE,
            Self::ActivityTracking => CMD_ACTIVITY_TRACKING,
            Self::ScreenTime => CMD_SCREEN_TIME,
            Self::Wrist => CMD_WRIST,
            Self::HeartRateInterval => CMD_HEART_RATE_INTERVAL,
            Self::HeartRateLimits => CMD_HEART_RATE_LIMITS,
            Self::Inactivity => CMD_INACTIVITY,
            Self::CaloriesType => CMD_CALORIES_TYPE,
            Self::DisplayOnMovement => CMD_DISPLAY_ON_MOVEMENT,
            Self::NotificationSwitches => CMD_DISPLAY_ON_MOVEMENT,
            Self::SleepSwitches => CMD_DISPLAY_ON_MOVEMENT,
            Self::AutoSleepWindow => CMD_AUTO_SLEEP_WINDOW,
            Self::Units => CMD_UNIT,
            Self::Volume => CMD_WATCH_VOLUME,
            Self::Brightness => CMD_SCREEN_BRIGHTNESS,
            Self::Snooze => CMD_SNOOZE,
            Self::TextSize => CMD_TEXT_SIZE,
            Self::BrightScreenTime => CMD_BRIGHT_SCREEN_TIME,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::TimeSurface => "time surface",
            Self::Signaling => "signaling",
            Self::DoNotDisturb => "do not disturb",
            Self::AnalogMode => "analog mode",
            Self::ActivityTracking => "activity tracking",
            Self::ScreenTime => "screen time",
            Self::Wrist => "wrist",
            Self::HeartRateInterval => "heart rate interval",
            Self::HeartRateLimits => "heart rate limits",
            Self::Inactivity => "inactivity alert",
            Self::CaloriesType => "calories type",
            Self::DisplayOnMovement => "display on movement",
            Self::NotificationSwitches => "notification switches",
            Self::SleepSwitches => "sleep switches",
            Self::AutoSleepWindow => "auto-sleep window",
            Self::Units => "units",
            Self::Volume => "watch volume",
            Self::Brightness => "screen brightness",
            Self::Snooze => "snooze",
            Self::TextSize => "notification text size",
            Self::BrightScreenTime => "bright screen time",
        }
    }
}

// ---------------------------------------------------------------------------
// Command
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub enum Command {
    // -- REQUEST frames (answered with type 0x80 on 0x8002) ------------------
    GetWatchId,
    GetFirmwareVersion,
    GetHardwareVersion,
    GetBattery,
    GetAvailableData,
    GetStepData,
    GetSleepData,
    GetHeartRateData,
    /// 0x91 — total stored alarm/reminder slots (official app, confirmed live).
    GetAlarmCount,
    /// 0x97 with CHECK payload — streams one 11-byte frame per stored
    /// alarm/reminder (GB wire format, confirmed live).
    GetAlarms,
    /// 0x2E GET — current button assignments, answered with the same
    /// `[0x02][buttonId][function]` records as the SET (seen live in the
    /// 2026-10-27 opcode scan: `02 01 01 02 02 03 02 03 00 02 04 00`).
    GetButtonFunctions,
    /// 0xDA GET — quick-reply metadata reply `[count][crc:2le]×count`
    /// (region 0xA2000, disassembly-verified on A2.0.55).
    GetQuickReplies,
    /// 0xDB GET — `Some(crc)` streams only the entry whose stored
    /// CRC-16/CCITT-FALSE(text) matches; `None` streams every entry
    /// (one `6F DB 80` reply frame per entry: `[index][crc:2le][text]`).
    GetQuickReply {
        crc: Option<u16>,
    },
    /// 0xEE GET — absolute memory peek `[addr:4be][len]` (lab only):
    /// len ≤ 0x40 confirmed live on A2.0.55; larger payloads return the
    /// unknown-opcode frame. Unsafe on unmapped addresses (bus fault).
    PeekMemory {
        addr: u32,
        len: u8,
    },
    /// 0x94 GET `checkInit` — reply `[initFlag]` (0 = QR en attente,
    /// 1 = init terminée). Confirmé live.
    GetInitFlag,
    ReadSetting(SettingId),
    /// 0x50 GET `[0x00]` — daily goals read-back (15-byte reply, 5×3).
    /// Android `Health.kt`, live round-trip confirmed.
    GetGoals,
    /// 0x30 GET `[0x00]` — user profile read-back (5-byte reply).
    /// Android `PersonalInfo.kt`, live round-trip confirmed.
    GetUserInfo,
    /// 0x21 GET `[0x00]` — night-mode config `[color][has_dial]`.
    GetNightMode,
    // -- SEND frames (acked via return-code 0x01/0x81) ------------------------
    /// 0x94 SET `[0x00]` — complète l'init out-of-box : big init (défauts,
    /// display, messages) + `initFlag=1` persisté si la session le permet —
    /// quitte l'écran QR vers le cadran. Équivalent de l'init de l'app
    /// officielle ; vérif. live post-factory-reset.
    CompleteInit,
    /// 0x93 SET `[0x02]` — QR bind start (Android pairing flow): sent
    /// after `SetTime`, followed by `BindEnd`, to close the watch's
    /// pairing-QR screen. Distinct from `CompleteInit` (0x94 `[0x00]`,
    /// post-factory-reset init).
    QrBindStart,
    /// 0x94 SET `[0x01]` — bind completion, last step of the Android QR
    /// pairing sequence (QrBindStart → SetTime → BindEnd).
    BindEnd,
    SetTime(DateTime<FixedOffset>),
    FindDevice {
        start: bool,
    },
    SetWrist(Wrist),
    /// Seconds; the watch rejects values < 10.
    SetScreenTime(u16),
    SetUserInfo {
        gender: Gender,
        age: u8,
        height_cm: u8,
        weight_kg: f32,
    },
    /// `value` already converted to watch units (steps in hundreds, km, h, min, kcal).
    SetGoal {
        kind: GoalKind,
        value: u16,
    },
    SetHeartRateLimits {
        max: u8,
        min: u8,
        alarm: bool,
    },
    /// Minutes between automatic measurements; 0 disables.
    SetHeartRateInterval {
        minutes: u8,
    },
    SetAnalogMode(AnalogMode),
    SetActivityTracking(bool),
    /// 0x1A CONTROL_DEVICE — raw sub-command byte (decompiled Appscomm SDK).
    /// Same opcode/payload shape as `SetActivityTracking`. Known subs:
    /// 3 = SET_JUMP_REAL_TIME_HEART_RATE, 15 = SET_EXITS_REAL_TIME_HEART_RATE,
    /// 11 = SET_JUMP_TAKE_PHOTO — the jump subs are NO-OPs on A2.0.55
    /// (live-tested 2026-11-08 for 3/15, 2026-10-29 for 11 → ack=2).
    ControlDevice {
        sub: u8,
    },
    SetDisplayOnMovement(bool),
    /// Single-bit switch under 0x90: anti-lost=0, auto-sync=1, sleep=2,
    /// auto-sleep=3, calls=4, missed-calls=5, sms=6, social=7, email=8,
    /// calendar=9, sedentary=10, low-power=11, 2nd reminder=12, ring=13,
    /// raise-to-wake=14, goal=15, rt-heart-rate=16, super-alarm=17,
    /// hr-monitor=18, 3-axis=19 (decompiled official app).
    SetSwitchSetting {
        index: u8,
        enabled: bool,
    },
    SetDoNotDisturb {
        enabled: bool,
        start: (u8, u8),
        end: (u8, u8),
    },
    SetCaloriesType(CaloriesType),
    SetTimeFormat(TimeFormat),
    SetDateFormat(DateFormat),
    /// `days`: bit0 Mon … bit6 Sun.
    SetInactivityAlert {
        enabled: bool,
        threshold_min: u8,
        start: (u8, u8),
        end: (u8, u8),
        days: u8,
    },
    /// Fenêtre de détection auto-sleep `0x58` :
    /// `[enterH][enterM][exitH][exitM][days]` — `days` = bitmask jours
    /// (bit0 lun … bit6 dim ; l'app officielle envoie 127 = tous les jours).
    /// L'app officielle envoie aussi `SetSwitchSetting { index: 3 }` à la
    /// sauvegarde : les deux sont nécessaires au démarrage de la détection
    /// (déduit du `goSave` décompilé, pas confirmé sur hardware).
    SetAutoSleepWindow {
        enter: (u8, u8),
        exit: (u8, u8),
        days: u8,
    },
    SetShockStrength(u8),
    SetSignaling {
        event: SignalEvent,
        pattern: SignalPattern,
    },
    SetLanguage(Language),
    /// 0x18 — the "home city" second-timezone line shown on faces with a
    /// digital clock. `offset_minutes` is the stored home offset (e.g.
    /// +60 for Paris winter); the watch displays
    /// `primary_time + (this offset − offset sent with the last 0x04)`,
    /// so it must be updated when DST flips.
    SetTimezone {
        offset_minutes: i16,
        city: String,
    },
    /// `days`: bit0 Mon(1) … bit6 Sun(64); 0 = ring once.
    /// `alarm_type`: `AlarmKind` code (4 = alarm, 1 = medicine, 2 = water,
    /// 7 = custom). `content` is appended verbatim (UTF-8) — only rendered
    /// by the watch for custom reminders (Android `Alarm.kt`).
    AddAlarm {
        hour: u8,
        minute: u8,
        days: u8,
        enabled: bool,
        pattern: SignalPattern,
        alarm_type: AlarmKind,
        content: String,
    },
    /// 0x97 edit — `[0x01] + existing_fields(10) + new_fields(10) +
    /// optional UTF-8 content` (Android `encodeAlarmEdit`, live-confirmed
    /// via the sibling Python project). `existing` must be the verbatim
    /// 10-byte field block read from the watch (there is no stable alarm
    /// id); `hour`/`minute`/`days`/`enabled`/`pattern`/`alarm_type`/`content`
    /// describe the new entry.
    EditAlarm {
        existing: [u8; 10],
        hour: u8,
        minute: u8,
        days: u8,
        enabled: bool,
        pattern: SignalPattern,
        alarm_type: AlarmKind,
        content: String,
    },
    /// Delete the stored alarm/reminder whose 10 field bytes are `fields`
    /// (obtained via a 0x97 read). Exploits the edit frame: with an
    /// `edit_flag` ≠ 0x01 and a "new" block identical to the "existing"
    /// block, the watch deletes the matching entry (live-confirmed trick).
    DeleteAlarm {
        fields: [u8; 10],
    },
    SendNotification {
        kind: NotificationKind,
        title: String,
        body: String,
    },
    IncomingCall {
        caller: String,
    },
    CallEnded,
    /// Music state + track info, sent on the reply characteristic (0x8003)
    /// in response to the watch's music-state request and on player changes
    /// — NOT written to TX, no 0x03 ack byte (GB onSetMusicState /
    /// replyMsgToWatch). `playing` → state byte 0, paused → 1.
    MusicInfo {
        playing: bool,
        title: String,
    },
    /// Music volume echo (GB initMusicVolume + the reply to the watch's
    /// volume buttons). Same reply channel as `MusicInfo`: 0x8003, no ack.
    MusicVolume(u8),
    /// Return-code frame echoing `echoed_cmd` — the generic ack the watch
    /// waits for after its 0xD1/0xD2/0xD9/0xDD events (confirmed live in
    /// the MyKronoz apps for 0xD1 and 0xDD). Same reply channel as
    /// `MusicInfo`: 0x8003, no ack byte.
    GenericAck {
        echoed_cmd: u8,
        status: u8,
    },
    /// 0x2E — reassign a physical button, one 3-byte record
    /// `[0x02][buttonId][function]`: buttonId 1=UP, 2=BOTTOM,
    /// 3=OTS_SHORT, 4=OTS_LONG; function 0-19 (1 dim screen, 4 music,
    /// 6 camera, 16 find phone). Live-confirmed (bind test + GET reply).
    SetButtonFunction {
        button: u8,
        function: u8,
    },
    /// 0x0E — single-chip "Apollo" upgrade-mode trigger: the watch acks,
    /// then reboots into DFU mode under a renamed identity (§8.4).
    /// `address` = the target .bin's first 4 bytes, copied verbatim like
    /// the official app (OtaUtil.getAddressSectorCount).
    EnterUpgradeMode {
        address: [u8; 4],
    },
    /// 0x0E with a bare `[0x01]` payload — on firmware A2.0.55 this is the
    /// form that actually reboots into DFU; the address-carrying form and
    /// the 0x20 is_ota SET are ack'd but never fire the reboot.
    EnterDfu,
    /// `condition`/`forecasts[i].2` are RAW ZeTime condition codes —
    /// Gadgetbridge's WeatherMapper tables are firmware-version-dependent,
    /// so we pass the user's code straight through.
    SendWeather {
        location: String,
        current_c: i8,
        min_c: i8,
        max_c: i8,
        condition: u8,
        forecasts: [(i8, i8, u8); 3],
    },
    CalendarEvent {
        opcode: u8,
        at: NaiveDateTime,
        title: String,
    },
    /// 0x98 SET — calendar month view: 8 × u32le day-of-month bitmasks,
    /// order [this month, previous month, next month … +5 months] per
    /// Android `Calendar.kt`; bit `dayOfMonth-1` set for each day that has
    /// events. Send after the 0x99 day events.
    CalendarMonthView {
        mask: [u32; 8],
    },
    /// 0x21 — night-mode screen: crown press shows a colored face for
    /// ~10 s. `color`: 1 = blue, 2 = green, 3 = white; `has_dial` = the
    /// minute-tick ring (Android `NightMode.kt`, has_dial live-confirmed).
    SetNightMode {
        color: u8,
        has_dial: bool,
    },
    /// 0x0C — units: 0 = metric, 1 = imperial.
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
    /// 0x14 — alarm snooze duration (raw byte, same units as the watch).
    SetSnooze {
        value: u8,
    },
    /// 0x19 — notification text size level.
    SetTextSize {
        level: u8,
    },
    /// 0x13 — bright-screen time (write-only upstream; GET times out).
    SetBrightScreenTime {
        value: u8,
    },
    /// 0xB8 SET `[hand][direction][mode]` — hand calibration control
    /// (Android `HandCalibration.kt`, live-confirmed on hardware):
    /// mode 0 = stop, 1 = continuous rotation, 2 = unlock, 3 = lock.
    /// Hand/direction semantics unverified — CLI/lab use only.
    CalibrateHands {
        hand: u8,
        direction: u8,
        mode: u8,
    },
    /// 0xB6 SET `[hand][direction][angle:2le]` — single hand nudge
    /// (fire-and-forget: the watch does not ack a response; send via the
    /// `fire` path, not `perform`). `angle` 0-359, minimum effective step
    /// observed = 2 units.
    MoveHandOnce {
        hand: u8,
        direction: u8,
        angle: u16,
    },
    /// 0x20 CHECK — CRC-only slot query; the watch replies
    /// [watch_face_number][ota_address:4le] (0 = already installed).
    WatchfaceCheck {
        crc: u16,
    },
    /// 0x20 SET — full 23-byte negotiation payload built by
    /// `watchface::WidgetLayout::set_payload` (flag/is_ota, crc, widget
    /// positions). With is_ota=1 the watch reboots into DFU mode.
    WatchfaceSet {
        payload: [u8; 23],
    },
    /// 0x1F — `Some(crc)` deletes that installed face by content match,
    /// `None` deletes all custom faces (live-confirmed).
    WatchfaceDelete {
        crc: Option<u16>,
    },
    /// 0xDB SET sub-command 0 — INSERT `text` at 1-based `index`; later
    /// entries shift down (the 10th is lost). Marks the region `USER`,
    /// recomputes count/CRCs, erases+rewrites the whole 0xA2000 region.
    /// `text` is stored as UTF-16LE (≤ 180 bytes = 90 code units).
    InsertQuickReply {
        index: u8,
        text: String,
    },
    /// 0xDB SET sub-command 1 — replace, in place, the text of the entry
    /// whose stored CRC is `crc` (indices shift on insert/delete, so the
    /// CRC is the stable identifier — read it from a 0xDA/0xDB reply).
    /// `text` is stored as UTF-16LE (≤ 180 bytes = 90 code units).
    UpdateQuickReply {
        crc: u16,
        text: String,
    },
    /// 0xDB SET sub-command 2 — delete the entry whose stored CRC is
    /// `crc`; later entries shift up.
    DeleteQuickReply {
        crc: u16,
    },
    DeleteStepData,
    DeleteSleepData,
    DeleteHeartRateData,
    /// No documented frame format exists for this command, so it is never
    /// sent — `encode` always returns `ProtocolError::Unsupported`.
    #[allow(dead_code)] // public protocol surface; only exercised in tests
    SetHandsPosition {
        hour_angle: u16,
        minute_angle: u16,
    },
}

impl Command {
    /// The `cmd` byte this command encodes to. SetHandsPosition returns 0x00
    /// (never sent — `encode` is Unsupported anyway).
    pub fn code(&self) -> u8 {
        match self {
            Command::GetWatchId => CMD_WATCH_ID,
            Command::GetFirmwareVersion | Command::GetHardwareVersion => CMD_DEVICE_VERSION,
            Command::GetBattery => CMD_BATTERY_POWER,
            Command::GetAvailableData => CMD_AVAILABLE_DATA,
            Command::GetStepData => CMD_STEP_DATA,
            Command::GetSleepData => CMD_SLEEP_DATA,
            Command::GetHeartRateData => CMD_HEART_RATE_DATA,
            Command::GetAlarmCount => CMD_REMIND_COUNT,
            Command::GetAlarms => CMD_REMINDERS,
            Command::GetButtonFunctions => CMD_CUSTOMIZE_BUTTON,
            Command::GetQuickReplies => CMD_QUICK_REPLY_META,
            Command::GetQuickReply { .. }
            | Command::InsertQuickReply { .. }
            | Command::UpdateQuickReply { .. }
            | Command::DeleteQuickReply { .. } => CMD_QUICK_REPLY,
            Command::PeekMemory { .. } => CMD_MEMORY_PEEK,
            Command::GetInitFlag | Command::CompleteInit | Command::BindEnd => CMD_INIT,
            Command::QrBindStart => CMD_BIND_START,
            Command::ReadSetting(id) => id.cmd(),
            Command::GetGoals => CMD_GOALS,
            Command::GetUserInfo => CMD_USER_INFO,
            Command::GetNightMode => CMD_NIGHT_MODE,
            Command::SetTime(_) => CMD_DATE_TIME,
            Command::FindDevice { .. } => CMD_FIND_DEVICE,
            Command::SetWrist(_) => CMD_WRIST,
            Command::SetScreenTime(_) => CMD_SCREEN_TIME,
            Command::SetUserInfo { .. } => CMD_USER_INFO,
            Command::SetGoal { .. } => CMD_GOALS,
            Command::SetNightMode { .. } => CMD_NIGHT_MODE,
            Command::SetUnits { .. } => CMD_UNIT,
            Command::SetWatchVolume { .. } => CMD_WATCH_VOLUME,
            Command::SetBrightness { .. } => CMD_SCREEN_BRIGHTNESS,
            Command::SetSnooze { .. } => CMD_SNOOZE,
            Command::SetTextSize { .. } => CMD_TEXT_SIZE,
            Command::SetBrightScreenTime { .. } => CMD_BRIGHT_SCREEN_TIME,
            Command::SetHeartRateLimits { .. } => CMD_HEART_RATE_LIMITS,
            Command::SetHeartRateInterval { .. } => CMD_HEART_RATE_INTERVAL,
            Command::SetAnalogMode(_) => CMD_ANALOG_MODE,
            Command::SetActivityTracking(_) | Command::ControlDevice { .. } => {
                CMD_ACTIVITY_TRACKING
            }
            Command::SetDisplayOnMovement(_) => CMD_DISPLAY_ON_MOVEMENT,
            Command::SetSwitchSetting { .. } => CMD_DISPLAY_ON_MOVEMENT,
            Command::SetDoNotDisturb { .. } => CMD_DO_NOT_DISTURB,
            Command::SetCaloriesType(_) => CMD_CALORIES_TYPE,
            Command::SetTimeFormat(_) | Command::SetDateFormat(_) => CMD_TIME_SURFACE,
            Command::SetInactivityAlert { .. } => CMD_INACTIVITY,
            Command::SetAutoSleepWindow { .. } => CMD_AUTO_SLEEP_WINDOW,
            Command::SetShockStrength(_) => CMD_SHOCK_STRENGTH,
            Command::SetSignaling { .. } => CMD_SIGNALING,
            Command::SetLanguage(_) => CMD_LANGUAGE,
            Command::SetTimezone { .. } => CMD_TIMEZONE,
            Command::AddAlarm { .. } | Command::EditAlarm { .. } | Command::DeleteAlarm { .. } => {
                CMD_REMINDERS
            }
            Command::SendNotification { .. }
            | Command::IncomingCall { .. }
            | Command::CallEnded => CMD_PUSH_EX_MSG,
            Command::MusicInfo { .. } | Command::MusicVolume(_) => CMD_MUSIC_CONTROL,
            Command::GenericAck { .. } => CMD_RETURN_CODE,
            Command::SetButtonFunction { .. } => CMD_CUSTOMIZE_BUTTON,
            Command::EnterUpgradeMode { .. } | Command::EnterDfu => CMD_UPGRADE_MODE,
            Command::SendWeather { .. } => CMD_WEATHER,
            Command::CalendarEvent { .. } => CMD_CALENDAR,
            Command::CalendarMonthView { .. } => CMD_CALENDAR_MONTH_VIEW,
            Command::CalibrateHands { .. } => CMD_WATCH_MOVE_KEEP,
            Command::MoveHandOnce { .. } => CMD_WATCH_MOVE_ONE,
            Command::WatchfaceCheck { .. } | Command::WatchfaceSet { .. } => CMD_WATCHFACE_SET,
            Command::WatchfaceDelete { .. } => CMD_WATCHFACE_DELETE,
            Command::DeleteStepData => CMD_DELETE_STEP_DATA,
            Command::DeleteSleepData => CMD_DELETE_SLEEP_DATA,
            Command::DeleteHeartRateData => CMD_DELETE_HEART_RATE_DATA,
            Command::SetHandsPosition { .. } => 0x00,
        }
    }

    /// Frame type: 0x70 REQUEST (watch answers with data), 0x71 SEND
    /// (watch answers with a return-code ack).
    #[allow(dead_code)] // protocol surface; exercised in tests
    pub fn kind(&self) -> u8 {
        match self {
            Command::GetWatchId
            | Command::GetFirmwareVersion
            | Command::GetHardwareVersion
            | Command::GetBattery
            | Command::GetAvailableData
            | Command::GetStepData
            | Command::GetSleepData
            | Command::GetHeartRateData
            | Command::GetAlarmCount
            | Command::GetAlarms
            | Command::GetButtonFunctions
            | Command::GetQuickReplies
            | Command::GetQuickReply { .. }
            | Command::PeekMemory { .. }
            | Command::GetInitFlag
            | Command::ReadSetting(_)
            | Command::GetGoals
            | Command::GetUserInfo
            | Command::GetNightMode
            | Command::WatchfaceCheck { .. } => CMD_REQUEST,
            Command::MusicInfo { .. } | Command::MusicVolume(_) => CMD_REQUEST_RESPOND,
            Command::GenericAck { .. } => TYPE_RETURN_CODE,
            _ => CMD_SEND,
        }
    }

    /// `now` is only used to stamp notification/call timestamps; passing it
    /// explicitly keeps encoding deterministic for tests.
    pub fn encode(&self, now: NaiveDateTime) -> Result<Vec<u8>, ProtocolError> {
        let send = CMD_SEND;
        let request = CMD_REQUEST;
        match self {
            Command::GetWatchId => frame(CMD_WATCH_ID, request, &[0x00]),
            // ZeTimeDeviceSupport.handleDeviceInfo: same cmd, payload 0x05 = fw, 0x02 = hw
            Command::GetFirmwareVersion => frame(CMD_DEVICE_VERSION, request, &[0x05]),
            Command::GetHardwareVersion => frame(CMD_DEVICE_VERSION, request, &[0x02]),
            // ZeTimeDeviceSupport.requestBatteryInfo
            Command::GetBattery => frame(CMD_BATTERY_POWER, request, &[0x00]),
            // ZeTimeDeviceSupport.handleActivityFetching
            Command::GetAvailableData => frame(CMD_AVAILABLE_DATA, request, &[0x00]),
            // ZeTimeDeviceSupport.handleStepsData / handleSleepData / handleHeartRateData
            Command::GetStepData => frame(CMD_STEP_DATA, request, &[0x00, 0x00]),
            Command::GetSleepData => frame(CMD_SLEEP_DATA, request, &[0x00, 0x00]),
            Command::GetHeartRateData => frame(CMD_HEART_RATE_DATA, request, &[0x00]),
            Command::GetAlarmCount => frame(CMD_REMIND_COUNT, request, &[0x00]),
            Command::GetAlarms => frame(CMD_REMINDERS, request, &[0x00]),
            Command::GetButtonFunctions => frame(CMD_CUSTOMIZE_BUTTON, request, &[0x00]),
            // 0xDA: metadata reply [count][crc:2le]×count (handler 0x2d2e8)
            Command::GetQuickReplies => frame(CMD_QUICK_REPLY_META, request, &[0x00]),
            // 0xDB GET (handler 0x5a1dc): payload[0]==0 streams every
            // entry; payload[0]!=0 treats payload[1:] as CRC-16 pairs and
            // streams only the matching entries.
            Command::GetQuickReply { crc } => match crc {
                Some(crc) => {
                    let mut p = vec![0x01];
                    p.extend_from_slice(&crc.to_le_bytes());
                    frame(CMD_QUICK_REPLY, request, &p)
                }
                None => frame(CMD_QUICK_REPLY, request, &[0x00]),
            },
            // 0xEE memory peek — lab only; wire format confirmed 2026-11-05
            // (`6F EE 70 05 00 <addr:4be> <len> 8F`, len ≤ 0x40).
            Command::PeekMemory { addr, len } => {
                let mut p = addr.to_be_bytes().to_vec();
                p.push(*len);
                frame(CMD_MEMORY_PEEK, request, &p)
            }
            // 0x94: GET [0x00] → reply [initFlag]; SET [0x00] → init complète
            Command::GetInitFlag => frame(CMD_INIT, request, &[0x00]),
            Command::CompleteInit => frame(CMD_INIT, send, &[0x00]),
            Command::QrBindStart => frame(CMD_BIND_START, send, &[0x02]),
            Command::BindEnd => frame(CMD_INIT, send, &[0x01]),
            Command::GetGoals => frame(CMD_GOALS, request, &[0x00]),
            Command::GetUserInfo => frame(CMD_USER_INFO, request, &[0x00]),
            Command::GetNightMode => frame(CMD_NIGHT_MODE, request, &[0x00]),
            // ZeTimeDeviceSupport.onReadConfiguration
            Command::ReadSetting(id) => frame(id.cmd(), request, &[0x00]),

            // ZeTimeDeviceSupport.synchronizeTime
            Command::SetTime(dt) => {
                let offset_secs = dt.offset().local_minus_utc();
                let payload = [
                    (dt.year() & 0xFF) as u8,
                    (dt.year() >> 8) as u8,
                    dt.month() as u8,
                    dt.day() as u8,
                    dt.hour() as u8,
                    dt.minute() as u8,
                    dt.second() as u8,
                    0x00,                             // is 24h
                    0x00,                             // SetTime after calibration
                    0x01,                             // Unit
                    (offset_secs / 3600) as i8 as u8, // TimeZone hour (+ DST baked into offset)
                    0x00,                             // TimeZone minute (Gadgetbridge hardcodes 0)
                ];
                frame(CMD_DATE_TIME, send, &payload)
            }
            // ZeTimeDeviceSupport.onFindDevice
            Command::FindDevice { start } => frame(CMD_FIND_DEVICE, send, &[*start as u8]),
            // ZeTimeDeviceSupport.setWrist
            Command::SetWrist(w) => frame(CMD_WRIST, send, &[w.code()]),
            // ZeTimeDeviceSupport.setScreenTime
            Command::SetScreenTime(secs) => {
                if *secs < 10 {
                    return Err(ProtocolError::InvalidValue(
                        "screen time must be at least 10 seconds".into(),
                    ));
                }
                frame(
                    CMD_SCREEN_TIME,
                    send,
                    &[(*secs & 0xFF) as u8, (*secs >> 8) as u8],
                )
            }
            // ZeTimeDeviceSupport.setUserInfo: weight sent as kg × 10
            Command::SetUserInfo {
                gender,
                age,
                height_cm,
                weight_kg,
            } => {
                let w10 = (weight_kg * 10.0).round();
                if !(0.0..=65535.0).contains(&w10) {
                    return Err(ProtocolError::InvalidValue(format!(
                        "weight {weight_kg} kg out of range"
                    )));
                }
                let w10 = w10 as u16;
                frame(
                    CMD_USER_INFO,
                    send,
                    &[
                        gender.code(),
                        *age,
                        *height_cm,
                        (w10 & 0xFF) as u8,
                        (w10 >> 8) as u8,
                    ],
                )
            }
            // ZeTimeDeviceSupport.setUserGoals
            Command::SetGoal { kind, value } => frame(
                CMD_GOALS,
                send,
                &[
                    kind.code(),
                    (*value & 0xFF) as u8,
                    (*value >> 8) as u8,
                    0x01,
                ],
            ),
            // Android NightMode.kt: [color][has_dial] both ways.
            Command::SetNightMode { color, has_dial } => {
                frame(CMD_NIGHT_MODE, send, &[*color, *has_dial as u8])
            }
            // Android Settings.kt: single-byte GET/SET for all of these.
            Command::SetUnits { imperial } => frame(CMD_UNIT, send, &[*imperial as u8]),
            Command::SetWatchVolume { level } => frame(CMD_WATCH_VOLUME, send, &[*level]),
            Command::SetBrightness { level } => frame(CMD_SCREEN_BRIGHTNESS, send, &[*level]),
            Command::SetSnooze { value } => frame(CMD_SNOOZE, send, &[*value]),
            Command::SetTextSize { level } => frame(CMD_TEXT_SIZE, send, &[*level]),
            Command::SetBrightScreenTime { value } => {
                frame(CMD_BRIGHT_SCREEN_TIME, send, &[*value])
            }
            // ZeTimeDeviceSupport.setHeartRateLimits
            Command::SetHeartRateLimits { max, min, alarm } => {
                frame(CMD_HEART_RATE_LIMITS, send, &[*max, *min, *alarm as u8])
            }
            // ZeTimeDeviceSupport.onSetHeartRateMeasurementInterval (minutes; 0 = off)
            Command::SetHeartRateInterval { minutes } => {
                frame(CMD_HEART_RATE_INTERVAL, send, &[*minutes])
            }
            // ZeTimeDeviceSupport.setAnalogMode
            Command::SetAnalogMode(m) => frame(CMD_ANALOG_MODE, send, &[m.code()]),
            // ZeTimeDeviceSupport.setActivityTracking
            Command::SetActivityTracking(on) => frame(
                CMD_ACTIVITY_TRACKING,
                send,
                &[if *on { 0x0A } else { 0x09 }],
            ),
            // CONTROL_DEVICE : payload = l'octet de sous-commande seul
            // (même forme que ci-dessus — GB envoie [0x09]/[0x0A]).
            Command::ControlDevice { sub } => frame(CMD_ACTIVITY_TRACKING, send, &[*sub]),
            // ZeTimeDeviceSupport.setDisplayOnMovement
            Command::SetDisplayOnMovement(on) => {
                frame(CMD_DISPLAY_ON_MOVEMENT, send, &[0x01, 0x0E, *on as u8])
            }
            // Same single-bit form GB uses for raise-to-wake (0x0E), but
            // for any switch index — verified live: bits are applied one
            // [idx][val] pair at a time, extras are ignored.
            Command::SetSwitchSetting { index, enabled } => frame(
                CMD_DISPLAY_ON_MOVEMENT,
                send,
                &[0x01, *index, *enabled as u8],
            ),
            // ZeTimeDeviceSupport.setDoNotDisturb
            Command::SetDoNotDisturb {
                enabled,
                start,
                end,
            } => frame(
                CMD_DO_NOT_DISTURB,
                send,
                &[*enabled as u8, start.0, start.1, end.0, end.1],
            ),
            // ZeTimeDeviceSupport.setCaloriesType
            Command::SetCaloriesType(t) => frame(CMD_CALORIES_TYPE, send, &[t.code()]),
            // ZeTimeDeviceSupport.setTimeFormate: 0xFF = leave unchanged on the watch
            Command::SetTimeFormat(f) => frame(
                CMD_TIME_SURFACE,
                send,
                &[0xFF, f.code(), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            ),
            // ZeTimeDeviceSupport.setDateFormate
            Command::SetDateFormat(f) => frame(
                CMD_TIME_SURFACE,
                send,
                &[f.code(), 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
            ),
            // ZeTimeDeviceSupport.setInactivityAlert: bit7 of reps = enabled, bits 0-6 = days;
            // disabled → reps 0 and the 4 time bytes 0 (threshold stays).
            Command::SetInactivityAlert {
                enabled,
                threshold_min,
                start,
                end,
                days,
            } => {
                let (reps, sh, sm, eh, em) = if *enabled {
                    (0x80 | days, start.0, start.1, end.0, end.1)
                } else {
                    (0, 0, 0, 0, 0)
                };
                frame(
                    CMD_INACTIVITY,
                    send,
                    &[reps, *threshold_min, sh, sm, eh, em, 0x64, 0x00],
                )
            }
            // Fenêtre auto-sleep : [enterH][enterM][exitH][exitM][days].
            Command::SetAutoSleepWindow { enter, exit, days } => frame(
                CMD_AUTO_SLEEP_WINDOW,
                send,
                &[enter.0, enter.1, exit.0, exit.1, *days],
            ),
            // ZeTimeDeviceSupport.setShockStrength
            Command::SetShockStrength(v) => frame(CMD_SHOCK_STRENGTH, send, &[*v]),
            // ZeTimeDeviceSupport.setSignaling
            Command::SetSignaling { event, pattern } => {
                frame(CMD_SIGNALING, send, &[event.code(), pattern.code()])
            }
            // ZeTimeDeviceSupport.setLanguage
            Command::SetLanguage(l) => frame(CMD_LANGUAGE, send, &[l.code()]),
            // §3: [sign(0=neg,1=pos)][hour][min][cityCountry utf8]
            Command::SetTimezone {
                offset_minutes,
                city,
            } => {
                let sign = u8::from(*offset_minutes >= 0);
                let abs = offset_minutes.unsigned_abs();
                if abs > 14 * 60 {
                    return Err(ProtocolError::InvalidValue(format!(
                        "timezone offset {offset_minutes} out of range (±14h)"
                    )));
                }
                let mut p = Vec::with_capacity(3 + city.len());
                p.push(sign);
                p.push((abs / 60) as u8);
                p.push((abs % 60) as u8);
                p.extend_from_slice(truncate_utf8(city, u8::MAX as usize));
                frame(CMD_TIMEZONE, send, &p)
            }
            // ZeTimeDeviceSupport.onSetAlarms ("new alarm" branch; p[1] = REMINDER_ALARM) +
            // Android Alarm.kt: [0x00] + [type][year:2][month][day]
            // [hour][minute][cycle][enabled][shock] + optional UTF-8
            // custom content.
            Command::AddAlarm {
                hour,
                minute,
                days,
                enabled,
                pattern,
                alarm_type,
                content,
            } => {
                let mut p = vec![
                    0x00,
                    alarm_type.code(),
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                    *hour,
                    *minute,
                    *days,
                    *enabled as u8,
                    pattern.code(),
                ];
                p.extend_from_slice(content.as_bytes());
                frame(CMD_REMINDERS, send, &p)
            }
            // Android encodeAlarmEdit: [0x01] + existing(10) + new(10) +
            // optional content — the field blocks carry year/month/day too.
            Command::EditAlarm {
                existing,
                hour,
                minute,
                days,
                enabled,
                pattern,
                alarm_type,
                content,
            } => {
                let new_fields = [
                    alarm_type.code(),
                    0x00,
                    0x00,
                    0x00,
                    0x00,
                    *hour,
                    *minute,
                    *days,
                    *enabled as u8,
                    pattern.code(),
                ];
                let mut p = Vec::with_capacity(21 + content.len());
                p.push(0x01);
                p.extend_from_slice(existing);
                p.extend_from_slice(&new_fields);
                p.extend_from_slice(content.as_bytes());
                frame(CMD_REMINDERS, send, &p)
            }
            // Edit-with-collision delete: edit_flag 0x02 (any non-0x01),
            // existing fields + identical "new" fields → watch deletes the
            // matching entry and compacts (confirmed live upstream).
            Command::DeleteAlarm { fields } => {
                let mut p = Vec::with_capacity(21);
                p.push(0x02);
                p.extend_from_slice(fields);
                p.extend_from_slice(fields);
                frame(CMD_REMINDERS, send, &p)
            }
            // ZeTimeDeviceSupport.onNotification
            Command::SendNotification { kind, title, body } => {
                let title = truncate_utf8(title, u8::MAX as usize);
                let body = truncate_utf8(body, u8::MAX as usize);
                let mut payload = Vec::with_capacity(4 + title.len() + body.len() + 15);
                payload.push(kind.code());
                payload.push(0x01);
                payload.push(title.len() as u8);
                payload.push(body.len() as u8);
                payload.extend_from_slice(title);
                payload.extend_from_slice(body);
                payload.extend_from_slice(&timestamp15(now));
                frame(CMD_PUSH_EX_MSG, send, &payload)
            }
            // ZeTimeDeviceSupport.onSetCallState (incoming call: subject = caller, no body)
            Command::IncomingCall { caller } => {
                let caller = truncate_utf8(caller, u8::MAX as usize);
                let mut payload = Vec::with_capacity(4 + caller.len() + 15);
                payload.push(NOTIFICATION_INCOME_CALL);
                payload.push(0x01);
                payload.push(caller.len() as u8);
                payload.push(0x00);
                payload.extend_from_slice(caller);
                payload.extend_from_slice(&timestamp15(now));
                frame(CMD_PUSH_EX_MSG, send, &payload)
            }
            // ZeTimeDeviceSupport.onSetCallState
            Command::CallEnded => {
                let mut payload = vec![NOTIFICATION_CALL_OFF, 0x01, 0x00, 0x00];
                payload.extend_from_slice(&timestamp15(now));
                frame(CMD_PUSH_EX_MSG, send, &payload)
            }
            // GB onSetMusicState / initMusicVolume: reply channel 0x8003
            // (type 0x80, chunked, NO ack byte after the frame).
            Command::MusicInfo { playing, title } => {
                let title = truncate_utf8(title, u8::MAX as usize);
                let mut payload = Vec::with_capacity(1 + title.len());
                payload.push(u8::from(!playing));
                payload.extend_from_slice(title);
                frame(CMD_MUSIC_CONTROL, CMD_REQUEST_RESPOND, &payload)
            }
            Command::MusicVolume(volume) => {
                frame(CMD_MUSIC_CONTROL, CMD_REQUEST_RESPOND, &[0x02, *volume])
            }
            // Generic ack for watch-initiated 0xD1/0xD2/0xD9/0xDD events —
            // same wire shape as the watch's own return-code frame.
            Command::GenericAck { echoed_cmd, status } => {
                frame(CMD_RETURN_CODE, TYPE_RETURN_CODE, &[*echoed_cmd, *status])
            }
            Command::SetButtonFunction { button, function } => {
                frame(CMD_CUSTOMIZE_BUTTON, send, &[0x02, *button, *function])
            }
            // §8.4 — `[0x01][file_addr:4]` : forme mono-fichier, adresse lue
            // dans les 4 premiers octets du .bin (voir app::ota).
            Command::EnterUpgradeMode { address } => {
                let mut payload = [0x01, 0, 0, 0, 0];
                payload[1..].copy_from_slice(address);
                frame(CMD_UPGRADE_MODE, send, &payload)
            }
            Command::EnterDfu => frame(CMD_UPGRADE_MODE, send, &[0x01]),
            // ZeTimeDeviceSupport.onSendWeather: 20-byte weather header + location bytes
            Command::SendWeather {
                location,
                current_c,
                min_c,
                max_c,
                condition,
                forecasts,
            } => {
                let mut payload = Vec::with_capacity(20 + location.len());
                payload.push(0x00); // celsius
                payload.push(*current_c as u8);
                payload.push(*min_c as u8);
                payload.push(*max_c as u8);
                payload.push(*condition);
                for &(fmin, fmax, fcond) in forecasts {
                    payload.extend_from_slice(&[0x00, 0xFF, fmin as u8, fmax as u8, fcond]);
                }
                payload.extend_from_slice(location.as_bytes());
                frame(CMD_WEATHER, send, &payload)
            }
            // ZeTimeDeviceSupport.encodeCalendarEvent
            Command::CalendarEvent { opcode, at, title } => {
                let title = truncate_utf8(title, u8::MAX as usize);
                let mut payload = Vec::with_capacity(10 + title.len());
                payload.push(*opcode);
                payload.push((at.year() & 0xFF) as u8);
                payload.push((at.year() >> 8) as u8);
                payload.push(at.month() as u8);
                payload.push(at.day() as u8);
                payload.push(at.hour() as u8);
                payload.push(at.minute() as u8);
                payload.extend_from_slice(&[0x00, 0x00]);
                payload.push(title.len() as u8);
                payload.extend_from_slice(title);
                frame(CMD_CALENDAR, send, &payload)
            }
            // Android Calendar.kt: 8 LE u32 day-bitmasks covering
            // [this month, previous month, next month … +5].
            Command::CalendarMonthView { mask } => {
                let mut p = Vec::with_capacity(32);
                for m in mask {
                    p.extend_from_slice(&m.to_le_bytes());
                }
                frame(CMD_CALENDAR_MONTH_VIEW, send, &p)
            }
            // §8.2: CHECK = 2-byte CRC16 of the pixel payload alone (LE,
            // matching the §8.3 trailer's byte order).
            Command::WatchfaceCheck { crc } => {
                frame(CMD_WATCHFACE_SET, request, &crc.to_le_bytes())
            }
            // §8.2: SET = the 23-byte negotiation; is_ota=1 hands the watch
            // to DFU mode.
            Command::WatchfaceSet { payload } => frame(CMD_WATCHFACE_SET, send, payload),
            // §8.2b: SET delete-by-CRC `[0x00][crc:2le]`, or `[0x01]` =
            // delete all (live-confirmed upstream).
            Command::WatchfaceDelete { crc } => match crc {
                Some(crc) => {
                    let mut p = vec![0x00];
                    p.extend_from_slice(&crc.to_le_bytes());
                    frame(CMD_WATCHFACE_DELETE, send, &p)
                }
                None => frame(CMD_WATCHFACE_DELETE, send, &[0x01]),
            },
            // 0xDB SET (handler 0x5a1dc → 0x5a1f2): [sub][index][crc:2le]
            // <text>. payload[1] (index) is only read by sub 0 — the
            // insert position; subs 1/2 address entries purely by the
            // CRC-16/CCITT-FALSE of their current text at payload[2:4].
            Command::InsertQuickReply { index, text } => {
                if !(1..=QUICK_REPLY_MAX_COUNT).contains(index) {
                    return Err(ProtocolError::InvalidValue(format!(
                        "quick-reply index {index} out of range (1..={QUICK_REPLY_MAX_COUNT})"
                    )));
                }
                let mut p = vec![0x00, *index, 0x00, 0x00];
                p.extend_from_slice(&quick_reply_text(text)?);
                frame(CMD_QUICK_REPLY, send, &p)
            }
            Command::UpdateQuickReply { crc, text } => {
                let mut p = vec![0x01, 0x00];
                p.extend_from_slice(&crc.to_le_bytes());
                p.extend_from_slice(&quick_reply_text(text)?);
                frame(CMD_QUICK_REPLY, send, &p)
            }
            Command::DeleteQuickReply { crc } => {
                let mut p = vec![0x02, 0x00];
                p.extend_from_slice(&crc.to_le_bytes());
                frame(CMD_QUICK_REPLY, send, &p)
            }
            // ZeTimeDeviceSupport.deleteStepData / deleteHeartRateData / deleteSleepData
            Command::DeleteStepData => frame(CMD_DELETE_STEP_DATA, send, &[0x00]),
            Command::DeleteSleepData => frame(CMD_DELETE_SLEEP_DATA, send, &[0x00]),
            Command::DeleteHeartRateData => frame(CMD_DELETE_HEART_RATE_DATA, send, &[0x00]),

            // Android HandCalibration.kt: [hand][direction][mode].
            Command::CalibrateHands {
                hand,
                direction,
                mode,
            } => frame(CMD_WATCH_MOVE_KEEP, send, &[*hand, *direction, *mode]),
            // [hand][direction][angle:2le]; angle clamped to 0-359.
            Command::MoveHandOnce {
                hand,
                direction,
                angle,
            } => {
                let angle = (*angle).min(359);
                frame(
                    CMD_WATCH_MOVE_ONE,
                    send,
                    &[*hand, *direction, (angle & 0xFF) as u8, (angle >> 8) as u8],
                )
            }
            Command::SetHandsPosition { .. } => Err(ProtocolError::Unsupported(
                "SetHandsPosition has no documented frame format",
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{NaiveDate, TimeZone};

    fn naive(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(y, mo, d)
            .unwrap()
            .and_hms_opt(h, mi, s)
            .unwrap()
    }

    fn enc(cmd: &Command) -> Vec<u8> {
        cmd.encode(naive(2026, 10, 26, 17, 30, 45)).unwrap()
    }

    // -- requests ----------------------------------------------------------

    #[test]
    fn encode_requests() {
        // ZeTimeDeviceSupport.requestDeviceInfo
        assert_eq!(
            enc(&Command::GetWatchId),
            [0x6F, 0x02, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        // ZeTimeDeviceSupport.handleDeviceInfo
        assert_eq!(
            enc(&Command::GetFirmwareVersion),
            [0x6F, 0x03, 0x70, 0x01, 0x00, 0x05, 0x8F]
        );
        assert_eq!(
            enc(&Command::GetHardwareVersion),
            [0x6F, 0x03, 0x70, 0x01, 0x00, 0x02, 0x8F]
        );
        // ZeTimeDeviceSupport.requestBatteryInfo
        assert_eq!(
            enc(&Command::GetBattery),
            [0x6F, 0x08, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        // ZeTimeDeviceSupport.handleActivityFetching
        assert_eq!(
            enc(&Command::GetAvailableData),
            [0x6F, 0x52, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        assert_eq!(
            enc(&Command::GetStepData),
            [0x6F, 0x54, 0x70, 0x02, 0x00, 0x00, 0x00, 0x8F]
        );
        assert_eq!(
            enc(&Command::GetSleepData),
            [0x6F, 0x56, 0x70, 0x02, 0x00, 0x00, 0x00, 0x8F]
        );
        assert_eq!(
            enc(&Command::GetHeartRateData),
            [0x6F, 0x61, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        // ZeTimeDeviceSupport.onReadConfiguration
        assert_eq!(
            enc(&Command::ReadSetting(SettingId::ScreenTime)),
            [0x6F, 0x25, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        assert_eq!(Command::GetBattery.kind(), CMD_REQUEST);
        assert_eq!(Command::SetWrist(Wrist::Left).kind(), CMD_SEND);
    }

    // -- sends -------------------------------------------------------------

    #[test]
    fn encode_get_battery_and_time() {
        // ZeTimeDeviceSupport.synchronizeTime (already verified on hardware)
        let dt = FixedOffset::east_opt(3600)
            .unwrap()
            .with_ymd_and_hms(2026, 10, 26, 17, 30, 45)
            .unwrap();
        let frame = Command::SetTime(dt)
            .encode(naive(2000, 1, 1, 0, 0, 0))
            .unwrap();
        assert_eq!(
            frame,
            [
                0x6F, 0x04, 0x71, 0x0C, 0x00, 0xEA, 0x07, 0x0A, 0x1A, 0x11, 0x1E, 0x2D, 0x00, 0x00,
                0x01, 0x01, 0x00, 0x8F
            ]
        );
        let dt = FixedOffset::west_opt(5 * 3600)
            .unwrap()
            .with_ymd_and_hms(2026, 10, 26, 17, 30, 45)
            .unwrap();
        assert_eq!(enc(&Command::SetTime(dt))[15], 0xFB);
    }

    #[test]
    fn encode_find_device() {
        // ZeTimeDeviceSupport.onFindDevice
        assert_eq!(
            enc(&Command::FindDevice { start: true }),
            [0x6F, 0xFA, 0x71, 0x01, 0x00, 0x01, 0x8F]
        );
        assert_eq!(
            enc(&Command::FindDevice { start: false }),
            [0x6F, 0xFA, 0x71, 0x01, 0x00, 0x00, 0x8F]
        );
    }

    #[test]
    fn encode_set_wrist() {
        // ZeTimeDeviceSupport.setWrist
        assert_eq!(
            enc(&Command::SetWrist(Wrist::Right)),
            [0x6F, 0x31, 0x71, 0x01, 0x00, 0x01, 0x8F]
        );
    }

    #[test]
    fn encode_set_screen_time() {
        // ZeTimeDeviceSupport.setScreenTime: 60s = 0x003C LE
        assert_eq!(
            enc(&Command::SetScreenTime(60)),
            [0x6F, 0x25, 0x71, 0x02, 0x00, 0x3C, 0x00, 0x8F]
        );
        assert!(matches!(
            Command::SetScreenTime(9).encode(naive(2026, 10, 26, 0, 0, 0)),
            Err(ProtocolError::InvalidValue(_))
        ));
    }

    #[test]
    fn encode_set_user_info() {
        // ZeTimeDeviceSupport.setUserInfo: 72.5kg → 725 = 0x02D5 LE
        assert_eq!(
            enc(&Command::SetUserInfo {
                gender: Gender::Male,
                age: 34,
                height_cm: 178,
                weight_kg: 72.5,
            }),
            [
                0x6F, 0x30, 0x71, 0x05, 0x00, 0x00, 34, 178, 0xD5, 0x02, 0x8F
            ]
        );
    }

    #[test]
    fn encode_set_goal() {
        // ZeTimeDeviceSupport.setUserGoals: 10000 steps → watch units 100
        assert_eq!(
            enc(&Command::SetGoal {
                kind: GoalKind::Steps,
                value: 100
            }),
            [0x6F, 0x50, 0x71, 0x04, 0x00, 0x00, 100, 0x00, 0x01, 0x8F]
        );
    }

    #[test]
    fn encode_heart_rate() {
        // ZeTimeDeviceSupport.setHeartRateLimits
        assert_eq!(
            enc(&Command::SetHeartRateLimits {
                max: 190,
                min: 50,
                alarm: true
            }),
            [0x6F, 0x5D, 0x71, 0x03, 0x00, 190, 50, 0x01, 0x8F]
        );
        // ZeTimeDeviceSupport.onSetHeartRateMeasurementInterval
        assert_eq!(
            enc(&Command::SetHeartRateInterval { minutes: 30 }),
            [0x6F, 0x5C, 0x71, 0x01, 0x00, 30, 0x8F]
        );
    }

    #[test]
    fn encode_modes() {
        // ZeTimeDeviceSupport.setAnalogMode / setActivityTracking / setDisplayOnMovement
        assert_eq!(
            enc(&Command::SetAnalogMode(AnalogMode::HandsAndSteps)),
            [0x6F, 0x17, 0x71, 0x01, 0x00, 0x01, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetActivityTracking(true)),
            [0x6F, 0x1A, 0x71, 0x01, 0x00, 0x0A, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetActivityTracking(false)),
            [0x6F, 0x1A, 0x71, 0x01, 0x00, 0x09, 0x8F]
        );
        // CONTROL_DEVICE subs : 3 = jump cardio temps réel, 15 = sortie.
        assert_eq!(
            enc(&Command::ControlDevice { sub: 0x03 }),
            [0x6F, 0x1A, 0x71, 0x01, 0x00, 0x03, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetDisplayOnMovement(true)),
            [0x6F, 0x90, 0x71, 0x03, 0x00, 0x01, 0x0E, 0x01, 0x8F]
        );
    }

    #[test]
    fn encode_dnd() {
        // ZeTimeDeviceSupport.setDoNotDisturb: enabled, 22:00 → 07:30
        assert_eq!(
            enc(&Command::SetDoNotDisturb {
                enabled: true,
                start: (22, 0),
                end: (7, 30),
            }),
            [0x6F, 0x15, 0x71, 0x05, 0x00, 0x01, 22, 0x00, 7, 30, 0x8F]
        );
    }

    #[test]
    fn encode_calories_type() {
        // ZeTimeDeviceSupport.setCaloriesType
        assert_eq!(
            enc(&Command::SetCaloriesType(CaloriesType::All)),
            [0x6F, 0x60, 0x71, 0x01, 0x00, 0x01, 0x8F]
        );
    }

    #[test]
    fn encode_time_date_format() {
        // ZeTimeDeviceSupport.setTimeFormate / setDateFormate
        assert_eq!(
            enc(&Command::SetTimeFormat(TimeFormat::H12)),
            [
                0x6F, 0x05, 0x71, 0x08, 0x00, 0xFF, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x8F
            ]
        );
        assert_eq!(
            enc(&Command::SetDateFormat(DateFormat::DdMmYy)),
            [
                0x6F, 0x05, 0x71, 0x08, 0x00, 0x02, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x8F
            ]
        );
    }

    #[test]
    fn encode_inactivity() {
        // ZeTimeDeviceSupport.setInactivityAlert: enabled, mon+wed (0b0000101), 60min, 09:00-18:00
        assert_eq!(
            enc(&Command::SetInactivityAlert {
                enabled: true,
                threshold_min: 60,
                start: (9, 0),
                end: (18, 0),
                days: 0b000_0101,
            }),
            [
                0x6F, 0x5E, 0x71, 0x08, 0x00, 0x85, 60, 9, 0, 18, 0, 0x64, 0x00, 0x8F
            ]
        );
        // disabled → reps 0 and time bytes 0
        assert_eq!(
            enc(&Command::SetInactivityAlert {
                enabled: false,
                threshold_min: 60,
                start: (9, 0),
                end: (18, 0),
                days: 0x7F,
            }),
            [
                0x6F, 0x5E, 0x71, 0x08, 0x00, 0x00, 60, 0, 0, 0, 0, 0x64, 0x00, 0x8F
            ]
        );
    }

    #[test]
    fn encode_auto_sleep_window() {
        // 23:00 → 09:00, tous les jours (127) — forme déduite de
        // `SettingAdvancedSettingPresetSleepUI.goSave` (non confirmée hw).
        assert_eq!(
            enc(&Command::SetAutoSleepWindow {
                enter: (23, 0),
                exit: (9, 0),
                days: 0x7F,
            }),
            [0x6F, 0x58, 0x71, 0x05, 0x00, 23, 0, 9, 0, 0x7F, 0x8F]
        );
    }

    #[test]
    fn encode_shock_signaling_language() {
        // ZeTimeDeviceSupport.setShockStrength
        assert_eq!(
            enc(&Command::SetShockStrength(200)),
            [0x6F, 0x10, 0x71, 0x01, 0x00, 200, 0x8F]
        );
        // ZeTimeDeviceSupport.setSignaling: SMS event (4) + vibrate-beep (13)
        assert_eq!(
            enc(&Command::SetSignaling {
                event: SignalEvent::Sms,
                pattern: SignalPattern::VibrateBeep,
            }),
            [0x6F, 0x0A, 0x71, 0x02, 0x00, 0x04, 0x0D, 0x8F]
        );
        // Appscomm SDK table (decompiled j.c.a): french = 7, spanish = 6 —
        // GB's table swaps them and sets Spanish instead.
        assert_eq!(
            enc(&Command::SetLanguage(Language::Fr)),
            [0x6F, 0x0B, 0x71, 0x01, 0x00, 0x07, 0x8F]
        );
    }

    #[test]
    fn encode_timezone() {
        // §3 — verified live: [01 01 00 "Paris"] puts the digital
        // home-time line at UTC+1.
        let frame = enc(&Command::SetTimezone {
            offset_minutes: 60,
            city: "Paris".into(),
        });
        let expected: Vec<u8> = [
            &[0x6F, 0x18, 0x71, 0x08, 0x00, 0x01, 0x01, 0x00][..],
            b"Paris",
            &[0x8F],
        ]
        .concat();
        assert_eq!(frame, expected);
        // -5:30 → sign 0, 5, 30
        let f = enc(&Command::SetTimezone {
            offset_minutes: -330,
            city: "".into(),
        });
        assert_eq!(f, [0x6F, 0x18, 0x71, 0x03, 0x00, 0x00, 0x05, 30, 0x8F]);
        assert!(matches!(
            Command::SetTimezone {
                offset_minutes: 15 * 60,
                city: "".into()
            }
            .encode(naive(2026, 10, 26, 0, 0, 0)),
            Err(ProtocolError::InvalidValue(_))
        ));
    }

    #[test]
    fn encode_alarm() {
        // ZeTimeDeviceSupport.onSetAlarms ("new alarm"): 07:30, mon-fri (0x1F), enabled, beep (11)
        assert_eq!(
            enc(&Command::AddAlarm {
                hour: 7,
                minute: 30,
                days: 0x1F,
                enabled: true,
                pattern: SignalPattern::Beep,
                alarm_type: AlarmKind::Alarm,
                content: String::new(),
            }),
            [
                0x6F, 0x97, 0x71, 0x0B, 0x00, 0x00, 0x04, 0, 0, 0, 0, 7, 30, 0x1F, 0x01, 0x0B, 0x8F
            ]
        );
    }

    #[test]
    fn encode_alarm_edit_and_custom() {
        // Custom reminder (type 7) with UTF-8 content.
        let f = enc(&Command::AddAlarm {
            hour: 9,
            minute: 0,
            days: 0,
            enabled: true,
            pattern: SignalPattern::Vibrate,
            alarm_type: AlarmKind::Custom,
            content: "Boire".into(),
        });
        assert_eq!(f[5], 0x00);
        assert_eq!(f[6], 0x07);
        assert_eq!(&f[16..21], b"Boire");

        // Edit: [0x01] + existing(10) + new(10) + content.
        let existing = [4, 0, 0, 0, 0, 7, 30, 0x1F, 1, 2];
        let f = enc(&Command::EditAlarm {
            existing,
            hour: 8,
            minute: 15,
            days: 0x7F,
            enabled: false,
            pattern: SignalPattern::None,
            alarm_type: AlarmKind::Alarm,
            content: String::new(),
        });
        assert_eq!(f[5], 0x01);
        assert_eq!(&f[6..16], &existing);
        assert_eq!(&f[16..26], &[4, 0, 0, 0, 0, 8, 15, 0x7F, 0, 14]);
        assert_eq!(f.len(), 26 + 1);
    }

    #[test]
    fn encode_new_settings_and_bind() {
        // Single-byte settings (Android Settings.kt).
        assert_eq!(
            enc(&Command::SetUnits { imperial: true }),
            [0x6F, 0x0C, 0x71, 0x01, 0x00, 0x01, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetWatchVolume { level: 3 }),
            [0x6F, 0x09, 0x71, 0x01, 0x00, 0x03, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetBrightness { level: 5 }),
            [0x6F, 0x07, 0x71, 0x01, 0x00, 0x05, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetSnooze { value: 10 }),
            [0x6F, 0x14, 0x71, 0x01, 0x00, 0x0A, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetTextSize { level: 2 }),
            [0x6F, 0x19, 0x71, 0x01, 0x00, 0x02, 0x8F]
        );
        assert_eq!(
            enc(&Command::SetNightMode {
                color: 1,
                has_dial: true
            }),
            [0x6F, 0x21, 0x71, 0x02, 0x00, 0x01, 0x01, 0x8F]
        );
        // Read-backs are REQUESTs.
        for c in [
            Command::GetGoals,
            Command::GetUserInfo,
            Command::GetNightMode,
        ] {
            assert_eq!(c.kind(), CMD_REQUEST);
        }
        // QR bind sequence.
        assert_eq!(
            enc(&Command::QrBindStart),
            [0x6F, 0x93, 0x71, 0x01, 0x00, 0x02, 0x8F]
        );
        assert_eq!(
            enc(&Command::BindEnd),
            [0x6F, 0x94, 0x71, 0x01, 0x00, 0x01, 0x8F]
        );
        // Calendar month view: 8 × u32le.
        let mut mask = [0u32; 8];
        mask[0] = 0b101;
        let f = enc(&Command::CalendarMonthView { mask });
        assert_eq!(&f[..8], &[0x6F, 0x98, 0x71, 0x20, 0x00, 0x05, 0x00, 0x00]);
        // Hand calibration (lab only).
        assert_eq!(
            enc(&Command::CalibrateHands {
                hand: 1,
                direction: 0,
                mode: 2
            }),
            [0x6F, 0xB8, 0x71, 0x03, 0x00, 0x01, 0x00, 0x02, 0x8F]
        );
        assert_eq!(
            enc(&Command::MoveHandOnce {
                hand: 0,
                direction: 1,
                angle: 300
            }),
            [0x6F, 0xB6, 0x71, 0x04, 0x00, 0x00, 0x01, 0x2C, 0x01, 0x8F]
        );
        // angle clamped to 0-359 → LE bytes [0x67, 0x01]
        let f = enc(&Command::MoveHandOnce {
            hand: 0,
            direction: 0,
            angle: 999,
        });
        assert_eq!(&f[7..9], &[0x67, 0x01]);
    }

    #[test]
    fn encode_notification() {
        // ZeTimeDeviceSupport.onNotification; "Réunion" is 8 UTF-8 bytes; kind sms = 1
        let frame = enc(&Command::SendNotification {
            kind: NotificationKind::Sms,
            title: "Rappel".into(),
            body: "Réunion".into(),
        });
        let expected: Vec<u8> = [
            &[0x6F, 0x76, 0x71, 0x21, 0x00, 0x01, 0x01, 0x06, 0x08][..],
            b"Rappel",
            "Réunion".as_bytes(),
            b"20261026T173045",
            &[0x8F],
        ]
        .concat();
        assert_eq!(frame, expected);
        assert_eq!(frame.len(), 39);
    }

    #[test]
    fn encode_notification_truncates_on_char_boundary() {
        // 300 'é' = 600 bytes → 127 chars = 254 bytes (255 is mid-char)
        let frame = enc(&Command::SendNotification {
            kind: NotificationKind::Social,
            title: "t".into(),
            body: "é".repeat(300),
        });
        assert_eq!(frame[8], 254); // body_len byte
        let len = frame[3] as usize | (frame[4] as usize) << 8;
        assert_eq!(frame.len(), len + 6);
        assert_eq!(*frame.last().unwrap(), crate::protocol::CMD_END);
    }

    #[test]
    fn encode_incoming_call() {
        // ZeTimeDeviceSupport.onSetCallState
        let frame = enc(&Command::IncomingCall {
            caller: "Alice".into(),
        });
        let expected: Vec<u8> = [
            &[0x6F, 0x76, 0x71, 0x18, 0x00, 0x05, 0x01, 0x05, 0x00][..],
            b"Alice",
            b"20261026T173045",
            &[0x8F],
        ]
        .concat();
        assert_eq!(frame, expected);
    }

    #[test]
    fn encode_call_ended() {
        // ZeTimeDeviceSupport.onSetCallState
        let frame = enc(&Command::CallEnded);
        let expected: Vec<u8> = [
            &[0x6F, 0x76, 0x71, 0x13, 0x00, 0x06, 0x01, 0x00, 0x00][..],
            b"20261026T173045",
            &[0x8F],
        ]
        .concat();
        assert_eq!(frame, expected);
    }

    #[test]
    fn encode_music_reply_frames() {
        // GB onSetMusicState / initMusicVolume — type 0x80, canal 0x8003
        // (pas d'octet ack 0x03 après la trame).
        assert_eq!(
            enc(&Command::MusicInfo {
                playing: true,
                title: "Source".into(),
            }),
            [
                0x6F, 0xD0, 0x80, 0x07, 0x00, 0x00, b'S', b'o', b'u', b'r', b'c', b'e', 0x8F
            ]
        );
        assert_eq!(
            enc(&Command::MusicInfo {
                playing: false,
                title: "Source".into(),
            })[5],
            0x01 // state : pause
        );
        assert_eq!(
            enc(&Command::MusicVolume(50)),
            [0x6F, 0xD0, 0x80, 0x02, 0x00, 0x02, 50, 0x8F]
        );
        assert_eq!(
            Command::MusicInfo {
                playing: true,
                title: String::new()
            }
            .kind(),
            0x80
        );
        assert_eq!(Command::MusicVolume(0).kind(), 0x80);
    }

    #[test]
    fn encode_generic_ack_and_button() {
        // Return-code echo answering a watch-initiated event (here 0xD1
        // camera) — reply channel 0x8003, no ack byte.
        assert_eq!(
            enc(&Command::GenericAck {
                echoed_cmd: 0xD1,
                status: 0
            }),
            [0x6F, 0x01, 0x81, 0x02, 0x00, 0xD1, 0x00, 0x8F]
        );
        assert_eq!(
            Command::GenericAck {
                echoed_cmd: 0xD1,
                status: 0
            }
            .kind(),
            0x81
        );
        // Physical button UP (1) → camera (6): one [0x02][id][fn] record.
        assert_eq!(
            enc(&Command::SetButtonFunction {
                button: 1,
                function: 6
            }),
            [0x6F, 0x2E, 0x71, 0x03, 0x00, 0x02, 0x01, 0x06, 0x8F]
        );
        // 0x2E GET: standard singleton request (live-confirmed reply).
        assert_eq!(
            enc(&Command::GetButtonFunctions),
            [0x6F, 0x2E, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
    }

    #[test]
    fn encode_upgrade_mode() {
        // §8.4 single-file form: [0x01] + the .bin's own 4-byte address.
        // Apollo_2.0.55.bin starts `00 00 02 05 …`.
        assert_eq!(
            enc(&Command::EnterUpgradeMode {
                address: [0x00, 0x00, 0x02, 0x05]
            }),
            [
                0x6F, 0x0E, 0x71, 0x05, 0x00, 0x01, 0x00, 0x00, 0x02, 0x05, 0x8F
            ]
        );
    }

    #[test]
    fn encode_weather() {
        // ZeTimeDeviceSupport.onSendWeather: Paris, 5/-3/12°C, cond 2, 3 forecasts
        let frame = enc(&Command::SendWeather {
            location: "Paris".into(),
            current_c: 5,
            min_c: -3,
            max_c: 12,
            condition: 2,
            forecasts: [(-3, 5, 2), (0, 8, 4), (2, 10, 1)],
        });
        let expected: Vec<u8> = [
            &[
                0x6F, 0x77, 0x71, 25, 0x00, // len 0x25 = 37 = 20 + 5 (Paris)
                0x00, 5, 0xFD, 12, 2, // cur, min(-3=0xFD), max, cond
                0x00, 0xFF, 0xFD, 5, 2, // forecast 1
                0x00, 0xFF, 0, 8, 4, // forecast 2
                0x00, 0xFF, 2, 10, 1, // forecast 3
            ][..],
            b"Paris",
            &[0x8F],
        ]
        .concat();
        assert_eq!(frame, expected);
    }

    #[test]
    fn encode_calendar_event() {
        // ZeTimeDeviceSupport.encodeCalendarEvent
        let frame = enc(&Command::CalendarEvent {
            opcode: 1,
            at: naive(2026, 11, 2, 9, 15, 0),
            title: "Standup".into(),
        });
        let expected: Vec<u8> = [
            &[
                0x6F, 0x99, 0x71, 17, 0x00, // len 0x11 = 17 = 10 + 7
                0x01, 0xEA, 0x07, 11, 2, 9, 15, 0, 0, 7,
            ][..],
            b"Standup",
            &[0x8F],
        ]
        .concat();
        assert_eq!(frame, expected);
    }

    #[test]
    fn encode_deletes() {
        // ZeTimeDeviceSupport.deleteStepData / deleteHeartRateData / deleteSleepData
        assert_eq!(
            enc(&Command::DeleteStepData),
            [0x6F, 0x53, 0x71, 0x01, 0x00, 0x00, 0x8F]
        );
        assert_eq!(
            enc(&Command::DeleteSleepData),
            [0x6F, 0x55, 0x71, 0x01, 0x00, 0x00, 0x8F]
        );
        assert_eq!(
            enc(&Command::DeleteHeartRateData),
            [0x6F, 0x5A, 0x71, 0x01, 0x00, 0x00, 0x8F]
        );
    }

    #[test]
    fn encode_set_hands_position_unsupported() {
        let err = Command::SetHandsPosition {
            hour_angle: 0,
            minute_angle: 0,
        }
        .encode(naive(2026, 10, 26, 17, 30, 45))
        .unwrap_err();
        assert!(matches!(err, ProtocolError::Unsupported(_)));
    }

    #[test]
    fn encode_watchface() {
        // §8.2: CHECK = action 0x70 + CRC16 LE only
        assert_eq!(
            enc(&Command::WatchfaceCheck { crc: 0xBEEF }),
            [0x6F, 0x20, 0x70, 0x02, 0x00, 0xEF, 0xBE, 0x8F]
        );
        // §8.2: SET = action 0x71 + 23-byte negotiation payload
        let mut p = [0x01u8; 23];
        p[0] = 0x01;
        let frame = enc(&Command::WatchfaceSet { payload: p });
        assert_eq!(&frame[..6], &[0x6F, 0x20, 0x71, 0x17, 0x00, 0x01]);
        assert_eq!(frame.len(), 23 + 6);
        // §8.2b: delete-by-CRC / delete-all
        assert_eq!(
            enc(&Command::WatchfaceDelete { crc: Some(0x1234) }),
            [0x6F, 0x1F, 0x71, 0x03, 0x00, 0x00, 0x34, 0x12, 0x8F]
        );
        assert_eq!(
            enc(&Command::WatchfaceDelete { crc: None }),
            [0x6F, 0x1F, 0x71, 0x01, 0x00, 0x01, 0x8F]
        );
        assert_eq!(Command::WatchfaceCheck { crc: 0 }.kind(), CMD_REQUEST);
    }

    #[test]
    fn encode_quick_replies() {
        // Firmware A2.0.55, handlers 0x2d2e8 (0xDA) / 0x5a1dc (0xDB).
        // 0xDA GET: metadata [count][crc:2le]×count
        assert_eq!(
            enc(&Command::GetQuickReplies),
            [0x6F, 0xDA, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        // 0xDB GET [0x00]: stream every entry
        assert_eq!(
            enc(&Command::GetQuickReply { crc: None }),
            [0x6F, 0xDB, 0x70, 0x01, 0x00, 0x00, 0x8F]
        );
        // 0xDB GET [0x01][crc:2le]: stream entries matching a CRC
        assert_eq!(
            enc(&Command::GetQuickReply { crc: Some(0x29B1) }),
            [0x6F, 0xDB, 0x70, 0x03, 0x00, 0x01, 0xB1, 0x29, 0x8F]
        );
        // 0xEE peek: `6F EE 70 05 00 <addr:4be> <len> 8F` (live 2026-11-05)
        assert_eq!(
            enc(&Command::PeekMemory {
                addr: 0x200,
                len: 0x40
            }),
            [
                0x6F, 0xEE, 0x70, 0x05, 0x00, 0x00, 0x00, 0x02, 0x00, 0x40, 0x8F
            ]
        );
        // 0xDB SET sub0 [0][index][0][0]<text>: insert at position —
        // text is UTF-16LE (the picker reads slot bytes as UTF-16)
        assert_eq!(
            enc(&Command::InsertQuickReply {
                index: 2,
                text: "OK".into()
            }),
            [
                0x6F, 0xDB, 0x71, 0x08, 0x00, 0x00, 0x02, 0x00, 0x00, b'O', 0x00, b'K', 0x00, 0x8F
            ]
        );
        // 0xDB SET sub1 [1][_][crc:2le]<text>: replace text by CRC
        assert_eq!(
            enc(&Command::UpdateQuickReply {
                crc: 0x29B1,
                text: "é".into()
            }),
            [
                0x6F, 0xDB, 0x71, 0x06, 0x00, 0x01, 0x00, 0xB1, 0x29, 0xE9, 0x00, 0x8F
            ]
        );
        // 0xDB SET sub2 [2][_][crc:2le]: delete by CRC
        assert_eq!(
            enc(&Command::DeleteQuickReply { crc: 0x29B1 }),
            [0x6F, 0xDB, 0x71, 0x04, 0x00, 0x02, 0x00, 0xB1, 0x29, 0x8F]
        );
        assert_eq!(Command::GetQuickReplies.kind(), CMD_REQUEST);
        assert_eq!(Command::GetQuickReply { crc: None }.kind(), CMD_REQUEST);
        assert_eq!(Command::GetQuickReply { crc: None }.code(), 0xDB);
        assert_eq!(
            Command::InsertQuickReply {
                index: 1,
                text: String::new()
            }
            .kind(),
            CMD_SEND
        );
    }

    #[test]
    fn encode_quick_reply_validation() {
        let now = naive(2026, 10, 26, 0, 0, 0);
        // index is 1-based, range 1..=10
        for index in [0u8, 11] {
            assert!(matches!(
                Command::InsertQuickReply {
                    index,
                    text: "x".into()
                }
                .encode(now),
                Err(ProtocolError::InvalidValue(_))
            ));
        }
        // text is bounded at 180 BYTES (firmware slot len field)
        let ok = "é".repeat(90); // 90 × 2 bytes = 180
        assert!(
            Command::InsertQuickReply { index: 1, text: ok }
                .encode(now)
                .is_ok()
        );
        let too_long = "é".repeat(91); // 182 bytes
        for cmd in [
            Command::InsertQuickReply {
                index: 1,
                text: too_long.clone(),
            },
            Command::UpdateQuickReply {
                crc: 0,
                text: too_long,
            },
        ] {
            assert!(matches!(
                cmd.encode(now),
                Err(ProtocolError::InvalidValue(_))
            ));
        }
    }

    #[test]
    fn chunks_split_20() {
        let frame = enc(&Command::SendNotification {
            kind: NotificationKind::Social,
            title: "Rappel".into(),
            body: "Réunion".into(),
        });
        let lens: Vec<usize> = crate::protocol::chunks(&frame).map(|c| c.len()).collect();
        assert_eq!(lens, [20, 19]);
    }
}
