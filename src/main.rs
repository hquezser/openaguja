mod app;
mod dfu;
mod transport;
mod watchface;

use app::Delivery;
use chrono::{DateTime, Datelike, FixedOffset, Local, NaiveDateTime, TimeZone};
use clap::{Parser, Subcommand, ValueEnum};
use openaguja::protocol;
use protocol::{
    AlarmKind, AnalogMode, CaloriesType, Command, DateFormat, Gender, GoalKind, Language,
    NotificationKind, SignalEvent, SignalPattern, TimeFormat, Wrist,
};
use std::path::PathBuf;
use std::time::Duration;
use transport::{BleTransport, BtleplugTransport, MockTransport};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error + Send + Sync>>;

const SCAN_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Parser)]
#[command(version, about = "BLE client for the MyKronoz ZeTime watch")]
struct Cli {
    /// Run against an offline mock instead of real Bluetooth
    #[arg(long, global = true)]
    mock: bool,

    /// Verbose: GATT dump and raw RX/TX hex
    #[arg(short, long, global = true)]
    verbose: bool,

    /// Keep the connection alive for N seconds after the command,
    /// printing incoming frames (e.g. to see/interact with a call screen)
    #[arg(long, global = true, value_name = "SECONDS")]
    stay: Option<u64>,

    /// Ack watch-initiated events (0xD0/0xD1/0xD2/0xD9/0xDD) like the iOS
    /// app: generic return-code echo on 0x8003 for each event received
    /// during monitor/stay
    #[arg(long, global = true)]
    ack_events: bool,

    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Set the watch's date/time
    SyncTime {
        /// Explicit local time "YYYY-MM-DD HH:MM[:SS]" instead of now
        #[arg(long)]
        at: Option<String>,
    },
    /// Push a notification to the watch
    Notify {
        #[arg(long)]
        title: String,
        #[arg(long)]
        body: String,
        /// Notification kind (icon shown on the watch)
        #[arg(long, value_enum, default_value_t = NotificationKind::Social)]
        kind: NotificationKind,
    },
    /// Read the battery level
    Battery,
    /// Serial, firmware, hardware and battery level
    Info,
    /// Read back every watch setting
    Config,
    /// Fetch buffered activity records (steps, sleep, heart rate)
    Activity {
        /// Delete the records on the watch after a complete fetch
        #[arg(long)]
        delete: bool,
    },
    /// Raw 0x1A CONTROL_DEVICE sub-command (lab): 3 = jump cardio temps
    /// réel, 15 = sortie, 11 = saut caméra — sous-commandes cardio NON
    /// vérifiées en live sur A2.0.55
    ControlDevice { sub: u8 },
    /// Make the watch ring
    Find {
        /// Stop the ringing instead of starting it
        #[arg(long)]
        stop: bool,
    },
    /// Simulate a phone call
    Call {
        #[command(subcommand)]
        action: CallAction,
    },
    /// Push weather data
    Weather {
        #[arg(long)]
        location: String,
        /// Current temperature in °C
        #[arg(long, allow_hyphen_values = true)]
        temp: i8,
        /// Today's min temperature in °C
        #[arg(long, allow_hyphen_values = true)]
        min: i8,
        /// Today's max temperature in °C
        #[arg(long, allow_hyphen_values = true)]
        max: i8,
        /// Raw ZeTime condition code (firmware-dependent)
        #[arg(long)]
        condition: u8,
        /// "MIN,MAX,COND" forecast — repeat exactly 3 times
        #[arg(
            long = "forecast",
            value_name = "MIN,MAX,COND",
            allow_hyphen_values = true,
            required = true
        )]
        forecasts: Vec<String>,
    },
    /// Push calendar events (max 17)
    Calendar {
        /// "YYYY-MM-DD HH:MM|Title" — repeatable
        #[arg(long = "event", value_name = "DATE|TITLE", required = true)]
        events: Vec<String>,
    },
    /// Manage alarms
    Alarm {
        #[command(subcommand)]
        action: AlarmAction,
    },
    /// Read the daily goals stored on the watch (0x50)
    Goals,
    /// Read the user profile stored on the watch (0x30)
    Profile,
    /// Night-mode screen config (0x21): colored face on crown press
    NightMode {
        #[command(subcommand)]
        action: NightModeAction,
    },
    /// Android QR pairing tail: 0x93 bind start → time sync → 0x94 bind
    /// end. Closes the watch's pairing-QR screen.
    QrBind,
    /// Hand calibration (lab): 0xB8 mode control + 0xB6 single nudges.
    /// Unlock shows a white face with a red dot — verify on hardware
    /// before trusting hand/direction semantics.
    Calibrate {
        #[command(subcommand)]
        action: CalibrateAction,
    },
    /// Calendar month-view bitmask (0x98) built from event dates —
    /// send after the 0x99 day events
    CalendarMonth {
        /// "YYYY-MM-DD HH:MM|Title" — repeatable (dates drive the mask)
        #[arg(long = "event", value_name = "DATE|TITLE", required = true)]
        events: Vec<String>,
    },
    /// Manage the quick-reply texts stored on the watch (used to answer
    /// notifications from its screen). Writes reflash a small region —
    /// keep the watch connected for the full command.
    Replies {
        #[command(subcommand)]
        action: RepliesAction,
    },
    /// Custom watchfaces: upload, switch, delete (PNG/JPEG)
    Watchface {
        #[command(subcommand)]
        action: WatchfaceAction,
    },
    /// Print incoming frames until Ctrl+C
    Monitor,
    /// Send raw hex frames, in order (prefix a frame with "reply:" to
    /// write it to 0x8003 instead of 0x8001, "read:" reads 0x8003,
    /// "sleep:N" waits N seconds). Combine with --stay.
    Raw {
        /// Frames in hex, e.g. "6F 93 71 00 00 8F" or "reply:6FD080020002328F" or "read:" or "sleep:5"
        #[arg(required = true, value_name = "HEX|reply:HEX|read:|sleep:N")]
        frames: Vec<String>,
    },
    /// Firmware OTA: flash an official .bin package (Apollo/TouchPanel/
    /// Picture). The watch reboots into DFU mode for a several-minute
    /// transfer — keep it on its charger, and disconnect the iPhone.
    /// An interrupted transfer is recoverable, but a successfully
    /// flashed wrong image can brick the watch.
    Ota {
        /// Official firmware .bin file
        file: PathBuf,
        /// DFU update type override (1=Apollo, 2=TouchPanel, 3=Heartrate,
        /// 4=Picture/resources, 6=GPS); guessed from the filename by default
        #[arg(long = "type", value_name = "N")]
        update_type: Option<u8>,
    },
    /// Push a packed payload to a watch already advertising its DFU
    /// identity — second half of `watchface upload --manual`. No normal
    /// BLE connection is opened.
    DfuPush {
        /// Packed payload file (e.g. from watchface upload --manual)
        file: PathBuf,
        /// DFU target address (e.g. 0x06820000, given by the prepare step)
        #[arg(long, value_parser = parse_u32)]
        addr: u32,
        /// DFU update type (default 4 = watchface/resources)
        #[arg(long = "type", value_name = "N", default_value = "4")]
        update_type: u8,
    },
    /// Change a watch setting
    Set {
        #[command(subcommand)]
        setting: SetCommand,
    },
}

#[derive(Subcommand)]
enum CallAction {
    /// Show an incoming call on the watch
    Incoming {
        #[arg(long)]
        caller: String,
    },
    /// Clear the incoming-call screen
    End,
}

#[derive(Subcommand)]
enum WatchfaceAction {
    /// Upload an image as a custom watchface (resized to 240×240).
    /// The watch reboots into DFU mode for a ~180KB transfer that takes
    /// a few minutes — keep it close and on its charger.
    Upload {
        /// Image file (PNG/JPEG)
        file: PathBuf,
        /// Place a data widget at x,y on the 240×240 face — repeatable.
        /// Names: heart-rate, steps, calories, distance, date, weather,
        /// battery, active-minutes, home-time (position 0|1, color 0-7)
        #[arg(long = "widget", value_name = "NAME:X,Y")]
        widgets: Vec<String>,
        /// Show the running-seconds indicator
        #[arg(long)]
        seconds_dot: bool,
        /// Stop after the 0x20 handshake and print the two commands to run
        /// (raw EnterDfu, then dfu-push) — for firmwares where the DFU scan
        /// only works from a fresh process
        #[arg(long)]
        manual: bool,
    },
    /// Switch the active face to an already-installed image (CRC match —
    /// no transfer needed)
    Switch {
        /// Image file (PNG/JPEG) identical to the uploaded one
        file: PathBuf,
        /// Reposition widgets while switching — see `upload --widget`
        #[arg(long = "widget", value_name = "NAME:X,Y")]
        widgets: Vec<String>,
        /// Show the running-seconds indicator
        #[arg(long)]
        seconds_dot: bool,
    },
    /// Delete the installed custom face(s) matching image file(s) by CRC
    Delete {
        /// Image file(s) (PNG/JPEG) identical to the uploaded one(s)
        files: Vec<PathBuf>,
    },
    /// Delete ALL custom watchfaces (falls back to a built-in face)
    DeleteAll,
}

#[derive(Subcommand)]
enum AlarmAction {
    /// Add an alarm
    Add {
        /// "HH:MM"
        #[arg(long)]
        time: String,
        /// Repeat days, e.g. "mon,tue,sun" (default: today only — cycle=0
        /// never rings, confirmed live)
        #[arg(long)]
        days: Option<String>,
        /// Create the alarm disabled
        #[arg(long)]
        disabled: bool,
        /// Ring pattern
        #[arg(long, value_enum, default_value_t = SignalPattern::Beep)]
        signal: SignalPattern,
    },
    /// List alarms/reminders stored on the watch
    List,
    /// Edit an existing alarm/reminder (0x97 edit frame — Android
    /// `encodeAlarmEdit`, live-confirmed). Omitted fields keep the
    /// stored values.
    Edit {
        /// Slot number (see `alarm list`)
        #[arg(long)]
        slot: u8,
        /// New time "HH:MM"
        #[arg(long)]
        time: Option<String>,
        /// New repeat days, e.g. "mon,tue,sun"
        #[arg(long)]
        days: Option<String>,
        /// Enable/disable
        #[arg(long)]
        enabled: Option<bool>,
        /// New ring pattern
        #[arg(long, value_enum)]
        signal: Option<SignalPattern>,
        /// New type (medicine/water/alarm/custom)
        #[arg(long, value_enum)]
        kind: Option<AlarmKind>,
        /// Custom reminder text (type `custom` only)
        #[arg(long)]
        content: Option<String>,
    },
    /// Delete the alarm/reminder at a slot (see `alarm list`)
    Delete {
        /// Slot number
        #[arg(long)]
        slot: u8,
    },
}

#[derive(Subcommand)]
enum NightModeAction {
    /// Read the current night-mode config
    Get,
    /// Set color (1=blue, 2=green, 3=white) and tick ring
    Set {
        #[arg(long)]
        color: u8,
        /// Show the minute-tick ring
        #[arg(long)]
        dial: bool,
    },
}

#[derive(Subcommand)]
enum CalibrateAction {
    /// 0xB8 mode 2 — unlock (white face + red dot = success)
    Unlock,
    /// 0xB8 mode 3 — lock (restores normal hands + time)
    Lock,
    /// 0xB8 mode 0 — stop continuous rotation
    Stop,
    /// 0xB8 mode 1 — continuous rotation
    Rotate,
    /// Safe sequence: unlock → sync time → lock
    Sync,
    /// 0xB6 single nudge: hand, direction, angle (0-359, min step 2)
    Move { hand: u8, direction: u8, angle: u16 },
}

#[derive(Subcommand)]
enum RepliesAction {
    /// List the quick replies stored on the watch (index, crc, text)
    List,
    /// Insert a new reply at a position — later replies shift down and a
    /// full list drops its 10th entry
    Insert {
        /// 1-based position (1-10)
        #[arg(long)]
        index: u8,
        /// Reply text, 180 bytes max
        #[arg(long)]
        text: String,
    },
    /// Replace the text of an existing reply
    Update {
        /// 1-based position (see `replies list`)
        #[arg(long)]
        index: u8,
        /// New reply text, 180 bytes max
        #[arg(long)]
        text: String,
    },
    /// Delete a reply
    Delete {
        /// 1-based position (see `replies list`)
        #[arg(long)]
        index: u8,
    },
}

#[derive(Subcommand)]
enum SetCommand {
    /// Which wrist the watch is worn on
    Wrist {
        #[arg(value_enum)]
        wrist: Wrist,
    },
    /// Screen-on time in seconds (min 10)
    ScreenTime { seconds: u16 },
    /// User profile used for calorie/distance estimates
    User {
        #[arg(long, value_enum)]
        gender: Gender,
        #[arg(long)]
        age: u8,
        /// Height in cm
        #[arg(long)]
        height: u8,
        /// Weight in kg
        #[arg(long)]
        weight: f32,
    },
    /// Daily goal: steps (count), distance (km), sleep (h), active-time (min), calories (kcal)
    Goal {
        #[arg(value_enum)]
        kind: GoalKind,
        value: u32,
    },
    /// Heart rate alarm limits in bpm
    HrLimits {
        #[arg(long)]
        max: u8,
        #[arg(long)]
        min: u8,
        /// Vibrate when out of range
        #[arg(long)]
        alarm: bool,
    },
    /// Automatic heart rate measurement interval in minutes (0 = off)
    HrInterval { minutes: u8 },
    /// What the analog hands display
    AnalogMode {
        #[arg(value_enum)]
        mode: AnalogMode,
    },
    /// Step/sleep/heart tracking
    ActivityTracking {
        #[arg(value_parser = parse_on_off, action = clap::ArgAction::Set)]
        on: bool,
    },
    /// Wake the display on wrist movement
    DisplayOnMove {
        #[arg(value_parser = parse_on_off, action = clap::ArgAction::Set)]
        on: bool,
    },
    /// Do-not-disturb window: "off" or "HH:MM-HH:MM"
    Dnd {
        #[arg(value_parser = parse_dnd)]
        window: DndWindow,
    },
    /// Which calories the watch counts
    CaloriesType {
        #[arg(value_enum)]
        kind: CaloriesType,
    },
    /// 24h or 12h clock
    TimeFormat {
        #[arg(value_enum)]
        format: TimeFormat,
    },
    /// Date display order
    DateFormat {
        #[arg(value_enum)]
        format: DateFormat,
    },
    /// Inactivity (sedentary) alert
    Inactivity {
        /// Turn the alert off
        #[arg(long)]
        off: bool,
        /// Alert after this many minutes of inactivity
        #[arg(long)]
        threshold: Option<u8>,
        /// Window start "HH:MM"
        #[arg(long)]
        from: Option<String>,
        /// Window end "HH:MM"
        #[arg(long)]
        to: Option<String>,
        /// Active days, e.g. "mon,tue,wed,thu,fri"
        #[arg(long)]
        days: Option<String>,
    },
    /// Vibration strength (0-255)
    ShockStrength { value: u8 },
    /// Ring pattern for an event
    Signal {
        #[arg(value_enum)]
        event: SignalEvent,
        #[arg(value_enum)]
        pattern: SignalPattern,
    },
    /// Watch language
    Language {
        #[arg(value_enum)]
        language: Language,
    },
    /// Units: metric or imperial (0x0C)
    Units {
        #[arg(value_enum)]
        system: UnitsSystem,
    },
    /// Watch notification/alarm volume level (0x09)
    Volume { level: u8 },
    /// Screen brightness level (0x07)
    Brightness { level: u8 },
    /// Alarm snooze duration, raw byte (0x14)
    Snooze { value: u8 },
    /// Notification text size level (0x19)
    TextSize { level: u8 },
    /// Home-city timezone line shown on faces with a digital clock
    /// (0x18). Update it when DST flips: the displayed second time is
    /// primary + (this offset − offset used by the last sync-time)
    Timezone {
        /// UTC offset "+H[:MM]" or "-H[:MM]", e.g. "+1", "-5:30"
        #[arg(long, allow_hyphen_values = true)]
        offset: String,
        /// City/country label shown on the face
        #[arg(long, default_value = "")]
        city: String,
    },
    /// Enable/disable a notification category (0x90 switch mask bits 4-9).
    /// The watch only displays pushes for enabled categories.
    Notifications {
        #[arg(value_enum)]
        category: NotificationCategory,
        #[arg(value_parser = parse_on_off, action = clap::ArgAction::Set)]
        on: bool,
    },
    /// Raw 0x90 switch bit (0-24; see docs — e.g. 0 anti-lost, 1 auto-sync,
    /// 13 ring, 14 raise-to-wake)
    Switch {
        index: u8,
        #[arg(value_parser = parse_on_off, action = clap::ArgAction::Set)]
        on: bool,
    },
}

/// Units system for `set units` (0x0C).
#[derive(ValueEnum, Clone, Copy, Debug)]
enum UnitsSystem {
    Metric,
    Imperial,
}

/// Notification category bits in the 0x90 switch mask.
#[derive(ValueEnum, Clone, Copy, Debug)]
enum NotificationCategory {
    /// Incoming calls (bit 4)
    Calls,
    /// Missed calls (bit 5)
    MissedCalls,
    /// SMS (bit 6)
    Sms,
    /// Social/apps (bit 7)
    Social,
    /// Email (bit 8)
    Email,
    /// Calendar (bit 9)
    Calendar,
}

impl NotificationCategory {
    fn index(self) -> u8 {
        match self {
            Self::Calls => 4,
            Self::MissedCalls => 5,
            Self::Sms => 6,
            Self::Social => 7,
            Self::Email => 8,
            Self::Calendar => 9,
        }
    }
}

// ---------------------------------------------------------------------------
// Input parsing (all before connecting)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy)]
enum DndWindow {
    Off,
    Window((u8, u8), (u8, u8)),
}

fn parse_hhmm(s: &str) -> std::result::Result<(u8, u8), String> {
    let (h, m) = s.split_once(':').ok_or("expected HH:MM")?;
    let h: u8 = h.parse().map_err(|_| format!("bad hour in '{s}'"))?;
    let m: u8 = m.parse().map_err(|_| format!("bad minute in '{s}'"))?;
    if h > 23 || m > 59 {
        return Err(format!("'{s}' is not a valid time"));
    }
    Ok((h, m))
}

fn parse_on_off(s: &str) -> std::result::Result<bool, String> {
    match s {
        "on" => Ok(true),
        "off" => Ok(false),
        _ => Err(format!("expected on|off, got '{s}'")),
    }
}

fn parse_dnd(s: &str) -> std::result::Result<DndWindow, String> {
    if s == "off" {
        return Ok(DndWindow::Off);
    }
    let (from, to) = s.split_once('-').ok_or("expected off|HH:MM-HH:MM")?;
    Ok(DndWindow::Window(parse_hhmm(from)?, parse_hhmm(to)?))
}

/// Day mask: bit0 Mon … bit6 Sun.
fn parse_days(s: &str) -> Result<u8> {
    let mut mask = 0u8;
    for d in s.split(',') {
        mask |= match d.trim().to_lowercase().as_str() {
            "mon" => 0x01,
            "tue" => 0x02,
            "wed" => 0x04,
            "thu" => 0x08,
            "fri" => 0x10,
            "sat" => 0x20,
            "sun" => 0x40,
            other => return Err(format!("unknown day '{other}'").into()),
        };
    }
    if mask == 0 {
        return Err("no days given".into());
    }
    Ok(mask)
}

/// "+H[:MM]" / "-H[:MM]" → signed minutes (±14h max, real-world range).
fn parse_utc_offset(s: &str) -> std::result::Result<i16, String> {
    let (sign, rest) = match s.strip_prefix('-') {
        Some(r) => (-1i16, r),
        None => (1, s.strip_prefix('+').unwrap_or(s)),
    };
    let (h, m) = match rest.split_once(':') {
        Some((h, m)) => (h, m),
        None => (rest, "0"),
    };
    let h: i16 = h.parse().map_err(|_| format!("bad hour in offset '{s}'"))?;
    let m: i16 = m
        .parse()
        .map_err(|_| format!("bad minute in offset '{s}'"))?;
    if h > 14 || m > 59 || (h == 14 && m != 0) {
        return Err(format!("offset '{s}' out of range (±14h)"));
    }
    Ok(sign * (h * 60 + m))
}

fn parse_forecast(s: &str) -> Result<(i8, i8, u8)> {
    let parts: Vec<&str> = s.split(',').collect();
    if parts.len() != 3 {
        return Err(format!("expected MIN,MAX,COND, got '{s}'").into());
    }
    let min: i8 = parts[0].parse().map_err(|_| format!("bad min in '{s}'"))?;
    let max: i8 = parts[1].parse().map_err(|_| format!("bad max in '{s}'"))?;
    let cond: u8 = parts[2].parse().map_err(|_| format!("bad cond in '{s}'"))?;
    Ok((min, max, cond))
}

/// "NAME:X,Y" — places a widget on the 240×240 face (0-240; for
/// home-time, X=position 0|1 and Y=color 0-7).
fn parse_widget(s: &str, layout: &mut watchface::WidgetLayout) -> Result<()> {
    let (name, coords) = s.split_once(':').ok_or("expected NAME:X,Y")?;
    let (x, y) = coords.split_once(',').ok_or("expected NAME:X,Y")?;
    let x: u8 = x.parse().map_err(|_| format!("bad x in '{s}'"))?;
    let y: u8 = y.parse().map_err(|_| format!("bad y in '{s}'"))?;
    if name != "home-time" && (x > 240 || y > 240) {
        return Err(format!("widget coordinates must be 0-240 in '{s}'").into());
    }
    layout.place(name, x, y).map_err(|e| e.into())
}

fn parse_calendar_event(s: &str) -> Result<(NaiveDateTime, String)> {
    let (date, title) = s
        .split_once('|')
        .ok_or("expected \"YYYY-MM-DD HH:MM|Title\"")?;
    let at = NaiveDateTime::parse_from_str(date, "%Y-%m-%d %H:%M")
        .map_err(|e| format!("bad event date '{date}': {e}"))?;
    if title.is_empty() {
        return Err("empty event title".into());
    }
    Ok((at, title.to_string()))
}

/// Parse `--at` as a local naive datetime, in the machine's timezone.
fn parse_at(s: &str) -> Result<DateTime<FixedOffset>> {
    let naive = ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M"]
        .iter()
        .find_map(|fmt| NaiveDateTime::parse_from_str(s, fmt).ok())
        .ok_or_else(|| format!("invalid --at value '{s}' (expected \"YYYY-MM-DD HH:MM[:SS]\")"))?;
    Local
        .from_local_datetime(&naive)
        .single()
        .map(|dt| dt.fixed_offset())
        .ok_or_else(|| {
            format!("'{s}' is ambiguous or does not exist in the local timezone (DST transition)")
                .into()
        })
}

/// 8 × u32le day-bitmasks for 0x98: index 0 = current month, 1 = previous
/// month, 2..7 = next months (Android `Calendar.kt` order); bit
/// `dayOfMonth-1` per event day.
fn month_view_mask(events: &[(NaiveDateTime, String)]) -> [u32; 8] {
    let today = Local::now().date_naive();
    let mut mask = [0u32; 8];
    for (at, _) in events {
        let d = at.date();
        let months_ago = (today.year() - d.year()) * 12 + today.month() as i32 - d.month() as i32;
        // slot: 0 = this month, 1 = last month, 2..7 = next +1..+6 months
        // (Android CalendarMonthView.kt: wire[0]=this, wire[1]=last,
        // wire[i]=+i for i>=2).
        let slot = match months_ago {
            0 => 0usize,
            1 => 1,
            m if m < 0 => 1 + (-m) as usize,
            _ => continue, // past beyond last month
        };
        if slot >= 8 || d.day() == 0 || d.day() > 31 {
            continue;
        }
        mask[slot] |= 1u32 << (d.day() - 1);
    }
    mask
}

/// User value → watch units for `set goal` (ZeTimeDeviceSupport.setUserGoals):
/// steps in hundreds, distance in km, sleep in hours, active in minutes,
/// calories in kcal. Errors if out of u16 after conversion.
fn goal_watch_units(kind: GoalKind, value: u32) -> Result<u16> {
    let converted = match kind {
        GoalKind::Steps => value / 100,
        _ => value,
    };
    u16::try_from(converted).map_err(|_| {
        format!("goal value {value} out of range after conversion ({converted})").into()
    })
}

// ---------------------------------------------------------------------------
// Plan: resolve all CLI input into protocol commands BEFORE connecting
// ---------------------------------------------------------------------------

/// One step of a `raw` command: a frame to 0x8001, to 0x8003, a 0x8003
/// read, or a pause.
enum RawStep {
    Send(Vec<u8>),
    SendReply(Vec<u8>),
    ReadReply,
    Sleep(u64),
}

enum Plan {
    /// A single SEND command, reported via report_delivery.
    Send(Command, String),
    Notify {
        kind: NotificationKind,
        title: String,
        body: String,
    },
    SyncTime(DateTime<FixedOffset>),
    Calendar(Vec<(NaiveDateTime, String)>),
    Battery,
    Info,
    Config,
    Activity {
        delete: bool,
    },
    Monitor,
    AlarmList,
    AlarmDelete(u8),
    AlarmEdit {
        slot: u8,
        /// `None` keeps the stored value (resolved after connecting).
        time: Option<(u8, u8)>,
        days: Option<u8>,
        enabled: Option<bool>,
        pattern: Option<SignalPattern>,
        alarm_type: Option<AlarmKind>,
        content: Option<String>,
    },
    Goals,
    Profile,
    NightModeGet,
    NightModeSet {
        color: u8,
        has_dial: bool,
    },
    QrBind,
    CalendarMonth([u32; 8]),
    /// unlock → sync time → lock (never leave the watch unlocked).
    CalibrateSync,
    RepliesList,
    RepliesInsert {
        index: u8,
        text: String,
    },
    RepliesUpdate {
        index: u8,
        text: String,
    },
    RepliesDelete(u8),
    /// Image already decoded/resized + widget layout resolved.
    WatchfaceUpload {
        pixels: Vec<u8>,
        layout: watchface::WidgetLayout,
        manual: bool,
    },
    /// Packed payload ready for the DFU identity — no normal BLE connect.
    DfuPush {
        content: Vec<u8>,
        ota_address: u32,
        update_type: u8,
    },
    WatchfaceSwitch {
        pixels: Vec<u8>,
        layout: watchface::WidgetLayout,
    },
    /// Image CRCs to delete.
    WatchfaceDelete(Vec<u16>),
    WatchfaceDeleteAll,
    /// Raw steps, in order.
    Raw(Vec<RawStep>),
    /// Firmware .bin: basename + full bytes + optional type override.
    Ota {
        file_name: String,
        bytes: Vec<u8>,
        update_type: Option<u8>,
    },
}

fn label(cmd: &Command) -> String {
    let name = protocol::command_name(cmd.code());
    let mut c = name.chars();
    match c.next() {
        Some(first) => format!(
            "{} sent",
            first.to_uppercase().collect::<String>() + c.as_str()
        ),
        None => "Command sent".to_string(),
    }
}

/// `--addr` accepts 0x-prefixed hex or decimal.
fn parse_u32(s: &str) -> std::result::Result<u32, String> {
    let s = s.trim();
    match s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        Some(h) => u32::from_str_radix(h, 16).map_err(|e| e.to_string()),
        None => s.parse::<u32>().map_err(|e| e.to_string()),
    }
}

/// Build a `Plan::Send` — validates the frame immediately so encoding
/// errors surface before we connect.
fn send_plan(command: Command) -> Result<Plan> {
    command.encode(NaiveDateTime::default())?;
    let label = label(&command);
    Ok(Plan::Send(command, label))
}

fn plan(cli: &Cli) -> Result<Plan> {
    match &cli.command {
        Commands::SyncTime { at } => {
            let dt = match at {
                Some(s) => parse_at(s)?,
                None => Local::now().fixed_offset(),
            };
            Ok(Plan::SyncTime(dt))
        }
        Commands::Notify { title, body, kind } => Ok(Plan::Notify {
            kind: *kind,
            title: title.clone(),
            body: body.clone(),
        }),
        Commands::Battery => Ok(Plan::Battery),
        Commands::Info => Ok(Plan::Info),
        Commands::Config => Ok(Plan::Config),
        Commands::Activity { delete } => Ok(Plan::Activity { delete: *delete }),
        Commands::ControlDevice { sub } => send_plan(Command::ControlDevice { sub: *sub }),
        Commands::Find { stop } => send_plan(Command::FindDevice { start: !stop }),
        Commands::Call { action } => match action {
            CallAction::Incoming { caller } => send_plan(Command::IncomingCall {
                caller: caller.clone(),
            }),
            CallAction::End => send_plan(Command::CallEnded),
        },
        Commands::Weather {
            location,
            temp,
            min,
            max,
            condition,
            forecasts,
        } => {
            if forecasts.len() != 3 {
                return Err(format!(
                    "--forecast must be given exactly 3 times (got {})",
                    forecasts.len()
                )
                .into());
            }
            let mut fs = [(0i8, 0i8, 0u8); 3];
            for (i, f) in forecasts.iter().enumerate() {
                fs[i] = parse_forecast(f)?;
            }
            send_plan(Command::SendWeather {
                location: location.clone(),
                current_c: *temp,
                min_c: *min,
                max_c: *max,
                condition: *condition,
                forecasts: fs,
            })
        }
        Commands::Calendar { events } => {
            let parsed: Vec<(NaiveDateTime, String)> = events
                .iter()
                .map(|e| parse_calendar_event(e))
                .collect::<Result<_>>()?;
            if parsed.len() > 17 {
                return Err(format!("max 17 calendar events (got {})", parsed.len()).into());
            }
            Ok(Plan::Calendar(parsed))
        }
        Commands::Alarm { action } => match action {
            AlarmAction::Add {
                time,
                days,
                disabled,
                signal,
            } => {
                let (hour, minute) = parse_hhmm(time)
                    .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?;
                // cycle is a weekday bitmask; 0 never rings (confirmed live).
                // Default: today's bit so the alarm fires once today.
                let days = match days {
                    Some(d) => parse_days(d)?,
                    None => 1 << Local::now().weekday().num_days_from_monday(),
                };
                send_plan(Command::AddAlarm {
                    hour,
                    minute,
                    days,
                    enabled: !disabled,
                    pattern: *signal,
                    alarm_type: AlarmKind::Alarm,
                    content: String::new(),
                })
            }
            AlarmAction::List => Ok(Plan::AlarmList),
            AlarmAction::Edit {
                slot,
                time,
                days,
                enabled,
                signal,
                kind,
                content,
            } => {
                let time =
                    match time {
                        Some(t) => Some(parse_hhmm(t).map_err(
                            |e| -> Box<dyn std::error::Error + Send + Sync> { e.into() },
                        )?),
                        None => None,
                    };
                let days = match days {
                    Some(d) => Some(parse_days(d)?),
                    None => None,
                };
                Ok(Plan::AlarmEdit {
                    slot: *slot,
                    time,
                    days,
                    enabled: *enabled,
                    pattern: *signal,
                    alarm_type: *kind,
                    content: content.clone(),
                })
            }
            AlarmAction::Delete { slot } => Ok(Plan::AlarmDelete(*slot)),
        },
        Commands::Goals => Ok(Plan::Goals),
        Commands::Profile => Ok(Plan::Profile),
        Commands::NightMode { action } => match action {
            NightModeAction::Get => Ok(Plan::NightModeGet),
            NightModeAction::Set { color, dial } => Ok(Plan::NightModeSet {
                color: *color,
                has_dial: *dial,
            }),
        },
        Commands::QrBind => Ok(Plan::QrBind),
        Commands::CalendarMonth { events } => {
            let parsed: Vec<(NaiveDateTime, String)> = events
                .iter()
                .map(|e| parse_calendar_event(e))
                .collect::<Result<_>>()?;
            Ok(Plan::CalendarMonth(month_view_mask(&parsed)))
        }
        Commands::Calibrate { action } => match action {
            CalibrateAction::Unlock => send_plan(Command::CalibrateHands {
                hand: 0,
                direction: 0,
                mode: 2,
            }),
            CalibrateAction::Lock => send_plan(Command::CalibrateHands {
                hand: 0,
                direction: 0,
                mode: 3,
            }),
            CalibrateAction::Stop => send_plan(Command::CalibrateHands {
                hand: 0,
                direction: 0,
                mode: 0,
            }),
            CalibrateAction::Rotate => send_plan(Command::CalibrateHands {
                hand: 0,
                direction: 0,
                mode: 1,
            }),
            CalibrateAction::Sync => Ok(Plan::CalibrateSync),
            CalibrateAction::Move {
                hand,
                direction,
                angle,
            } => send_plan(Command::MoveHandOnce {
                hand: *hand,
                direction: *direction,
                angle: *angle,
            }),
        },
        Commands::Replies { action } => match action {
            RepliesAction::List => Ok(Plan::RepliesList),
            // Encode-validate now so index/text errors surface pre-connect.
            RepliesAction::Insert { index, text } => {
                Command::InsertQuickReply {
                    index: *index,
                    text: text.clone(),
                }
                .encode(NaiveDateTime::default())?;
                Ok(Plan::RepliesInsert {
                    index: *index,
                    text: text.clone(),
                })
            }
            RepliesAction::Update { index, text } => {
                Command::UpdateQuickReply {
                    crc: 0,
                    text: text.clone(),
                }
                .encode(NaiveDateTime::default())?;
                Ok(Plan::RepliesUpdate {
                    index: *index,
                    text: text.clone(),
                })
            }
            RepliesAction::Delete { index } => Ok(Plan::RepliesDelete(*index)),
        },
        Commands::Watchface { action } => match action {
            WatchfaceAction::Upload {
                file,
                widgets,
                seconds_dot,
                ..
            }
            | WatchfaceAction::Switch {
                file,
                widgets,
                seconds_dot,
            } => {
                let pixels = watchface::load_image(file)?;
                let mut layout = watchface::WidgetLayout {
                    seconds_dot: *seconds_dot,
                    ..Default::default()
                };
                for w in widgets {
                    parse_widget(w, &mut layout)?;
                }
                if matches!(action, WatchfaceAction::Upload { .. }) {
                    let manual = matches!(action, WatchfaceAction::Upload { manual: true, .. });
                    Ok(Plan::WatchfaceUpload {
                        pixels,
                        layout,
                        manual,
                    })
                } else {
                    Ok(Plan::WatchfaceSwitch { pixels, layout })
                }
            }
            WatchfaceAction::Delete { files } => {
                if files.is_empty() {
                    return Err("give at least one image file".into());
                }
                let crcs = files
                    .iter()
                    .map(|f| watchface::load_image(f).map(|p| watchface::crc16(&p)))
                    .collect::<Result<_>>()?;
                Ok(Plan::WatchfaceDelete(crcs))
            }
            WatchfaceAction::DeleteAll => Ok(Plan::WatchfaceDeleteAll),
        },
        Commands::Monitor => Ok(Plan::Monitor),
        Commands::Raw { frames } => {
            let parsed = frames
                .iter()
                .map(|f| match f.strip_prefix("reply:") {
                    Some(hex) => parse_hex_frame(hex).map(RawStep::SendReply),
                    None if f.as_str() == "read:" => Ok(RawStep::ReadReply),
                    None if f.starts_with("sleep:") => f
                        .strip_prefix("sleep:")
                        .and_then(|s| s.parse::<u64>().ok())
                        .map(RawStep::Sleep)
                        .ok_or_else(|| format!("bad sleep duration: {f}").into()),
                    None => parse_hex_frame(f).map(RawStep::Send),
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(Plan::Raw(parsed))
        }
        Commands::Ota { file, update_type } => {
            let bytes = std::fs::read(file)?;
            Ok(Plan::Ota {
                file_name: file
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_else(|| file.display().to_string()),
                bytes,
                update_type: *update_type,
            })
        }
        Commands::DfuPush {
            file,
            addr,
            update_type,
        } => Ok(Plan::DfuPush {
            content: std::fs::read(file)?,
            ota_address: *addr,
            update_type: *update_type,
        }),
        Commands::Set { setting } => send_plan(match setting {
            SetCommand::Wrist { wrist } => Command::SetWrist(*wrist),
            SetCommand::ScreenTime { seconds } => Command::SetScreenTime(*seconds),
            SetCommand::User {
                gender,
                age,
                height,
                weight,
            } => Command::SetUserInfo {
                gender: *gender,
                age: *age,
                height_cm: *height,
                weight_kg: *weight,
            },
            SetCommand::Goal { kind, value } => Command::SetGoal {
                kind: *kind,
                value: goal_watch_units(*kind, *value)?,
            },
            SetCommand::HrLimits { max, min, alarm } => Command::SetHeartRateLimits {
                max: *max,
                min: *min,
                alarm: *alarm,
            },
            SetCommand::HrInterval { minutes } => {
                Command::SetHeartRateInterval { minutes: *minutes }
            }
            SetCommand::AnalogMode { mode } => Command::SetAnalogMode(*mode),
            SetCommand::ActivityTracking { on } => Command::SetActivityTracking(*on),
            SetCommand::DisplayOnMove { on } => Command::SetDisplayOnMovement(*on),
            SetCommand::Dnd { window } => match window {
                DndWindow::Off => Command::SetDoNotDisturb {
                    enabled: false,
                    start: (0, 0),
                    end: (0, 0),
                },
                DndWindow::Window(start, end) => Command::SetDoNotDisturb {
                    enabled: true,
                    start: *start,
                    end: *end,
                },
            },
            SetCommand::CaloriesType { kind } => Command::SetCaloriesType(*kind),
            SetCommand::TimeFormat { format } => Command::SetTimeFormat(*format),
            SetCommand::DateFormat { format } => Command::SetDateFormat(*format),
            SetCommand::Inactivity {
                off,
                threshold,
                from,
                to,
                days,
            } => {
                if *off {
                    Command::SetInactivityAlert {
                        enabled: false,
                        threshold_min: 0,
                        start: (0, 0),
                        end: (0, 0),
                        days: 0,
                    }
                } else {
                    let threshold = threshold.ok_or("--threshold is required (or use --off)")?;
                    let from = from.as_deref().ok_or("--from is required (or use --off)")?;
                    let to = to.as_deref().ok_or("--to is required (or use --off)")?;
                    let days = days.as_deref().ok_or("--days is required (or use --off)")?;
                    Command::SetInactivityAlert {
                        enabled: true,
                        threshold_min: threshold,
                        start: parse_hhmm(from).map_err(
                            |e| -> Box<dyn std::error::Error + Send + Sync> { e.into() },
                        )?,
                        end: parse_hhmm(to).map_err(
                            |e| -> Box<dyn std::error::Error + Send + Sync> { e.into() },
                        )?,
                        days: parse_days(days)?,
                    }
                }
            }
            SetCommand::ShockStrength { value } => Command::SetShockStrength(*value),
            SetCommand::Signal { event, pattern } => Command::SetSignaling {
                event: *event,
                pattern: *pattern,
            },
            SetCommand::Language { language } => Command::SetLanguage(*language),
            SetCommand::Units { system } => Command::SetUnits {
                imperial: matches!(system, UnitsSystem::Imperial),
            },
            SetCommand::Volume { level } => Command::SetWatchVolume { level: *level },
            SetCommand::Brightness { level } => Command::SetBrightness { level: *level },
            SetCommand::Snooze { value } => Command::SetSnooze { value: *value },
            SetCommand::TextSize { level } => Command::SetTextSize { level: *level },
            SetCommand::Timezone { offset, city } => Command::SetTimezone {
                offset_minutes: parse_utc_offset(offset)
                    .map_err(|e| -> Box<dyn std::error::Error + Send + Sync> { e.into() })?,
                city: city.clone(),
            },
            SetCommand::Notifications { category, on } => Command::SetSwitchSetting {
                index: category.index(),
                enabled: *on,
            },
            SetCommand::Switch { index, on } => Command::SetSwitchSetting {
                index: *index,
                enabled: *on,
            },
        }),
    }
}

// ---------------------------------------------------------------------------
// main / dispatch
// ---------------------------------------------------------------------------

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    // Parse/validate all user input before touching Bluetooth.
    let plan = plan(&cli)?;
    // DFU-mode push: the watch advertises its DFU identity, no normal
    // connection is opened — handled entirely by dfu::upload.
    if let Plan::DfuPush {
        content,
        ota_address,
        update_type,
    } = &plan
    {
        return dfu::upload(
            None,
            content,
            *ota_address,
            watchface::crc16(content),
            *update_type,
            cli.verbose,
        )
        .await;
    }
    if cli.mock {
        execute(&mut MockTransport::new(80), &plan, cli.stay, cli.ack_events).await
    } else {
        let mut t = BtleplugTransport::connect(SCAN_TIMEOUT, cli.verbose).await?;
        execute(&mut t, &plan, cli.stay, cli.ack_events).await
    }
}

/// Always disconnect; surface the command's error first.
async fn execute<T: BleTransport>(
    t: &mut T,
    plan: &Plan,
    stay: Option<u64>,
    ack_events: bool,
) -> Result<()> {
    let result = run(t, plan, ack_events).await;
    if result.is_ok()
        && let Some(secs) = stay
        && secs > 0
    {
        println!("Staying connected {secs}s (incoming frames below; Ctrl+C to disconnect now)");
        if let Err(e) = app::stay(t, Duration::from_secs(secs), ack_events).await {
            eprintln!("warning: stay failed: {e}");
        }
    }
    let disconnected = t.disconnect().await;
    result.and(disconnected)
}

/// Print the outcome of an acked command; Rejected is an error.
fn report_delivery(delivery: &Delivery, success: &str, cmd: u8) -> Result<()> {
    match delivery {
        Delivery::Accepted => println!("{success} (acknowledged by the watch)"),
        Delivery::Rejected(status) => {
            return Err(format!(
                "watch rejected the {} (status {status:#04X})",
                protocol::command_name(cmd)
            )
            .into());
        }
        Delivery::NoReply => {
            println!("{success}");
            eprintln!("warning: no acknowledgement from the watch within 2s");
        }
    }
    Ok(())
}

async fn run<T: BleTransport>(t: &mut T, plan: &Plan, ack_events: bool) -> Result<()> {
    match plan {
        Plan::Send(command, label) => {
            let delivery = app::apply(t, command).await?;
            report_delivery(&delivery, label, command.code())?;
        }
        Plan::Notify { kind, title, body } => {
            let delivery = app::notify(t, *kind, title, body, Local::now().naive_local()).await?;
            report_delivery(&delivery, "Notification sent", protocol::CMD_PUSH_EX_MSG)?;
        }
        Plan::SyncTime(now) => {
            let delivery = app::sync_time(t, *now).await?;
            report_delivery(
                &delivery,
                &format!("Time synchronized: {}", now.naive_local()),
                protocol::CMD_DATE_TIME,
            )?;
        }
        Plan::Calendar(events) => {
            let deliveries = app::send_calendar(t, events).await?;
            if let Some(status) = deliveries.iter().find_map(|d| match d {
                Delivery::Rejected(s) => Some(*s),
                _ => None,
            }) {
                return Err(format!("watch rejected the calendar (status {status:#04X})").into());
            }
            let no_reply = deliveries
                .iter()
                .filter(|d| matches!(d, Delivery::NoReply))
                .count();
            println!(
                "Calendar synchronized: {} events{}",
                events.len(),
                if no_reply == 0 {
                    " (acknowledged by the watch)"
                } else {
                    ""
                }
            );
            if no_reply > 0 {
                eprintln!("warning: {no_reply} event(s) not acknowledged within 2s");
            }
        }
        Plan::Battery => {
            let level = app::battery(t).await?;
            println!("Battery: {level}%");
        }
        Plan::Info => {
            let info = app::info(t).await?;
            println!("Serial: {}", info.serial);
            println!("Firmware: {}", info.firmware);
            println!("Hardware: {}", info.hardware);
            println!("Battery: {}%", info.battery);
        }
        Plan::Config => {
            for (id, line) in app::read_config(t).await? {
                match line {
                    Ok(setting) => println!("{}: {}", id.name(), setting),
                    Err(e) => println!("{}: error: {e}", id.name()),
                }
            }
            match app::read_button_assignments(t).await {
                Ok(lines) => println!("buttons: {}", lines.join(", ")),
                Err(e) => println!("buttons: error: {e}"),
            }
        }
        Plan::Activity { delete } => {
            let activity = app::fetch_activity(t, *delete).await?;
            for r in &activity.steps {
                println!(
                    "steps   {}  {} steps, {} cal (raw), {} m, {} min active",
                    r.timestamp, r.steps, r.calories, r.distance_m, r.active_min
                );
            }
            for r in &activity.sleep {
                println!("sleep   {}  {:?}", r.timestamp, r.kind);
            }
            for r in &activity.heart_rate {
                println!("hr      {}  {} bpm", r.timestamp, r.bpm);
            }
            if activity.steps.is_empty()
                && activity.sleep.is_empty()
                && activity.heart_rate.is_empty()
            {
                println!("No activity data on the watch");
            }
            for e in &activity.errors {
                eprintln!("warning: {e}");
            }
            if *delete && activity.errors.is_empty() {
                println!("Activity data deleted on the watch");
            }
        }
        Plan::Monitor => {
            app::monitor(t, ack_events).await?;
        }
        Plan::AlarmList => {
            let alarms = app::list_alarms(t).await?;
            if alarms.is_empty() {
                println!("No alarms on the watch");
            }
            for a in &alarms {
                println!(
                    "slot {} | type {} | {:02}:{:02} | days {:#09b} | {} | signal {}",
                    a.slot,
                    a.alarm_type,
                    a.hour,
                    a.minute,
                    a.cycle,
                    if a.enabled { "on" } else { "off" },
                    a.shock
                );
            }
        }
        Plan::AlarmDelete(slot) => {
            let delivery = app::delete_alarm(t, *slot).await?;
            report_delivery(&delivery, "Alarm deleted", protocol::CMD_REMINDERS)?;
        }
        Plan::AlarmEdit {
            slot,
            time,
            days,
            enabled,
            pattern,
            alarm_type,
            content,
        } => {
            let delivery = app::edit_alarm(
                t,
                *slot,
                *time,
                *days,
                *enabled,
                *pattern,
                *alarm_type,
                content.as_deref(),
            )
            .await?;
            report_delivery(&delivery, "Alarm edited", protocol::CMD_REMINDERS)?;
        }
        Plan::Goals => {
            let g = app::read_goals(t).await?;
            println!(
                "steps {} | calories {} kcal | distance {} km | sleep {} h | active {} min",
                g.steps, g.calories, g.distance_km, g.sleep_hours, g.active_minutes
            );
        }
        Plan::Profile => {
            let u = app::read_user_info(t).await?;
            println!(
                "sex {} | age {} | height {} cm | weight {:.1} kg",
                u.sex, u.age, u.height_cm, u.weight_kg
            );
        }
        Plan::NightModeGet => {
            let n = app::read_night_mode(t).await?;
            println!("color {} | dial {}", n.color, n.has_dial);
        }
        Plan::NightModeSet { color, has_dial } => {
            let delivery = app::apply(
                t,
                &Command::SetNightMode {
                    color: *color,
                    has_dial: *has_dial,
                },
            )
            .await?;
            report_delivery(&delivery, "Night mode set", protocol::CMD_NIGHT_MODE)?;
        }
        Plan::QrBind => {
            app::qr_bind(t).await?;
            println!("QR bind sequence sent (0x93 → time sync → 0x94)");
        }
        Plan::CalendarMonth(mask) => {
            let delivery = app::apply(t, &Command::CalendarMonthView { mask: *mask }).await?;
            report_delivery(
                &delivery,
                "Calendar month view sent",
                protocol::CMD_CALENDAR_MONTH_VIEW,
            )?;
        }
        Plan::CalibrateSync => {
            for (cmd, label) in [
                (
                    Command::CalibrateHands {
                        hand: 0,
                        direction: 0,
                        mode: 2,
                    },
                    "unlock",
                ),
                (Command::SetTime(Local::now().fixed_offset()), "time sync"),
                (
                    Command::CalibrateHands {
                        hand: 0,
                        direction: 0,
                        mode: 3,
                    },
                    "lock",
                ),
            ] {
                let delivery = app::apply(t, &cmd).await?;
                report_delivery(&delivery, label, cmd.code())?;
            }
        }
        Plan::RepliesList => {
            let replies = app::list_quick_replies(t).await?;
            if replies.is_empty() {
                println!("No quick replies on the watch");
            }
            for r in &replies {
                println!("{:2}. [{:04X}] {}", r.index, r.crc, r.text);
            }
        }
        Plan::RepliesInsert { index, text } => {
            let delivery = app::insert_quick_reply(t, *index, text).await?;
            report_delivery(&delivery, "Quick reply inserted", protocol::CMD_QUICK_REPLY)?;
        }
        Plan::RepliesUpdate { index, text } => {
            let delivery = app::update_quick_reply(t, *index, text).await?;
            report_delivery(&delivery, "Quick reply updated", protocol::CMD_QUICK_REPLY)?;
        }
        Plan::RepliesDelete(index) => {
            let delivery = app::delete_quick_reply(t, *index).await?;
            report_delivery(&delivery, "Quick reply deleted", protocol::CMD_QUICK_REPLY)?;
        }
        Plan::WatchfaceUpload {
            pixels,
            layout,
            manual,
        } => {
            if *manual {
                match app::watchface_prepare(t, pixels, layout).await? {
                    app::WatchfacePrep::AlreadyInstalled => {
                        println!("Image already installed — switched to it")
                    }
                    app::WatchfacePrep::Ready {
                        content,
                        ota_address,
                        dfu_name,
                        ..
                    } => {
                        let path = "/tmp/zetime-watchface.bin";
                        std::fs::write(path, &content)?;
                        println!(
                            "Prepared {} bytes for DFU{}",
                            content.len(),
                            dfu_name
                                .as_deref()
                                .map(|n| format!(" ({n})"))
                                .unwrap_or_default()
                        );
                        println!("Now run, in order:");
                        println!("  openaguja raw \"6F 0E 71 01 00 01 8F\"");
                        println!("  openaguja dfu-push {path} --addr {ota_address:#010X} --type 4");
                    }
                }
            } else {
                match app::watchface_upload(t, pixels, layout).await? {
                    app::WatchfaceOutcome::Uploaded => {
                        println!("Watchface uploaded and activated")
                    }
                    app::WatchfaceOutcome::AlreadyInstalled => {
                        println!("Image already installed — switched to it")
                    }
                }
            }
        }
        Plan::DfuPush { .. } => unreachable!("handled before connect"),
        Plan::WatchfaceSwitch { pixels, layout } => {
            if app::watchface_switch(t, pixels, layout).await? {
                println!("Switched to the installed watchface");
            } else {
                return Err("that image isn't installed on the watch — upload it first".into());
            }
        }
        Plan::WatchfaceDelete(crcs) => {
            for crc in crcs {
                let delivery = app::watchface_delete(t, Some(*crc)).await?;
                report_delivery(
                    &delivery,
                    &format!("Watchface {crc:#06X} deleted"),
                    protocol::CMD_WATCHFACE_DELETE,
                )?;
            }
        }
        Plan::WatchfaceDeleteAll => {
            let delivery = app::watchface_delete(t, None).await?;
            report_delivery(
                &delivery,
                "All custom watchfaces deleted",
                protocol::CMD_WATCHFACE_DELETE,
            )?;
        }
        Plan::Raw(steps) => {
            for (i, step) in steps.iter().enumerate() {
                match step {
                    RawStep::Sleep(secs) => {
                        println!("Sleeping {secs}s…");
                        tokio::time::sleep(Duration::from_secs(*secs)).await;
                    }
                    RawStep::ReadReply => app::raw_read_reply(t).await?,
                    RawStep::Send(frame) => {
                        app::raw_send(t, frame, false).await?;
                        println!("Raw frame {} sent", i + 1);
                    }
                    RawStep::SendReply(frame) => {
                        app::raw_send(t, frame, true).await?;
                        println!("Raw frame {} sent", i + 1);
                    }
                }
            }
        }
        Plan::Ota {
            file_name,
            bytes,
            update_type,
        } => app::ota(t, file_name, bytes, *update_type).await?,
    }
    Ok(())
}

/// Decode a hex string into bytes (whitespace ignored).
fn parse_hex_frame(s: &str) -> Result<Vec<u8>> {
    let digits: String = s.chars().filter(|c| !c.is_whitespace()).collect();
    if digits.is_empty() || !digits.len().is_multiple_of(2) {
        return Err("hex string must contain an even, nonzero number of digits".into());
    }
    (0..digits.len())
        .step_by(2)
        .map(|i| {
            u8::from_str_radix(&digits[i..i + 2], 16)
                .map_err(|e| format!("invalid hex in frame: {e}").into())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use clap::CommandFactory;

    #[test]
    fn cli_definition_is_valid() {
        Cli::command().debug_assert();
    }

    #[test]
    fn cli_parses_on_off_settings() {
        for args in [
            ["openaguja", "set", "activity-tracking", "off"],
            ["openaguja", "set", "display-on-move", "on"],
        ] {
            assert!(Cli::try_parse_from(args).is_ok(), "{args:?}");
        }
    }

    #[test]
    fn parse_at_minutes() {
        // naive asserted only; offset depends on the machine's timezone
        assert_eq!(
            parse_at("2026-10-27 08:15").unwrap().naive_local(),
            NaiveDate::from_ymd_opt(2026, 10, 27)
                .unwrap()
                .and_hms_opt(8, 15, 0)
                .unwrap()
        );
    }

    #[test]
    fn parse_at_seconds() {
        assert_eq!(
            parse_at("2026-10-27 08:15:30").unwrap().naive_local(),
            NaiveDate::from_ymd_opt(2026, 10, 27)
                .unwrap()
                .and_hms_opt(8, 15, 30)
                .unwrap()
        );
    }

    #[test]
    fn parse_at_garbage() {
        assert!(parse_at("garbage").is_err());
    }

    #[test]
    fn parse_dnd_window() {
        match parse_dnd("22:00-07:00").unwrap() {
            DndWindow::Window(start, end) => {
                assert_eq!(start, (22, 0));
                assert_eq!(end, (7, 0));
            }
            _ => panic!("expected a window"),
        }
        assert!(matches!(parse_dnd("off").unwrap(), DndWindow::Off));
        assert!(parse_dnd("22:00").is_err());
        assert!(parse_dnd("25:00-07:00").is_err());
    }

    #[test]
    fn parse_days_mask() {
        assert_eq!(parse_days("mon,wed,sun").unwrap(), 0b100_0101);
        assert_eq!(parse_days("tue").unwrap(), 0b000_0010);
        assert!(parse_days("mon,xxx").is_err());
    }

    #[test]
    fn parse_utc_offset_ranges() {
        assert_eq!(parse_utc_offset("+1").unwrap(), 60);
        assert_eq!(parse_utc_offset("-5:30").unwrap(), -330);
        assert_eq!(parse_utc_offset("+14").unwrap(), 840);
        assert_eq!(parse_utc_offset("0").unwrap(), 0);
        assert!(parse_utc_offset("+15").is_err());
        assert!(parse_utc_offset("+14:01").is_err());
        assert!(parse_utc_offset("x").is_err());
    }

    #[test]
    fn parse_forecast_negative() {
        assert_eq!(parse_forecast("-3,5,2").unwrap(), (-3, 5, 2));
        assert!(parse_forecast("1,2").is_err());
        assert!(parse_forecast("a,b,c").is_err());
    }

    #[test]
    fn month_view_mask_slots() {
        // Build dates relative to today: this month, last month, +1 and +6.
        let today = Local::now().date_naive();
        let month_start = NaiveDate::from_ymd_opt(today.year(), today.month(), 1).unwrap();
        let ev = |d: NaiveDate| (d.and_hms_opt(12, 0, 0).unwrap(), "t".to_string());
        let events = vec![
            ev(month_start),                          // this month, day 1
            ev(month_start.pred_opt().unwrap()),      // last month, day 1 (or last day of prev)
            ev(month_start + chrono::Months::new(1)), // +1 month
            ev(month_start + chrono::Months::new(6)), // +6 months → slot 7
            ev(month_start + chrono::Months::new(7)), // +7 → dropped
        ];
        let mask = month_view_mask(&events);
        assert_eq!(mask[0], 1, "this month day1 → slot0 bit0");
        // last month: day depends on prev month's length; just check nonzero
        assert_ne!(mask[1], 0, "last month → slot1");
        assert_eq!(mask[2], 1, "+1 month day1 → slot2 bit0");
        assert_eq!(mask[7], 1, "+6 months day1 → slot7 bit0");
        assert_eq!(mask[3], 0);
        assert_eq!(mask[4], 0);
        assert_eq!(mask[5], 0);
        assert_eq!(mask[6], 0);
    }

    #[test]
    fn goal_conversion() {
        assert_eq!(goal_watch_units(GoalKind::Steps, 10000).unwrap(), 100);
        assert_eq!(goal_watch_units(GoalKind::Distance, 12).unwrap(), 12);
        assert!(goal_watch_units(GoalKind::Distance, 70000).is_err());
        assert!(goal_watch_units(GoalKind::Steps, 7_000_000).is_err());
    }
}
