//! Business logic, generic over `BleTransport`.

use crate::Result;
use crate::protocol::parse::{
    self, AvailableData, HeartRateRecord, Setting, SleepRecord, StepRecord,
};
use crate::protocol::{
    self, AlarmKind, Command, NotificationKind, Response, SettingId, SignalPattern, to_hex,
};
use crate::transport::BleTransport;
use crate::watchface::{self, WidgetLayout};
use chrono::{DateTime, FixedOffset, Local, NaiveDateTime};
use std::time::{Duration, Instant};

const BATTERY_TIMEOUT: Duration = Duration::from_secs(5);
const REPLY_TIMEOUT: Duration = Duration::from_secs(2);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const ACTIVITY_FRAME_TIMEOUT: Duration = Duration::from_secs(5);

/// Outcome of sending a command and waiting for its return-code ack.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Delivery {
    /// The watch acked the command with status 0x00.
    Accepted,
    /// The watch acked the command with a non-zero status.
    Rejected(u8),
    /// No ack frame arrived before the deadline.
    NoReply,
}

/// Read frames until `pred` matches one, or the deadline expires
/// (`Ok(None)`). The 1ms sleep on `None` keeps a fast-returning `recv`
/// (mock) from busy-spinning.
async fn recv_matching<T: BleTransport>(
    t: &mut T,
    timeout: Duration,
    pred: impl Fn(&[u8]) -> bool,
) -> Result<Option<Vec<u8>>> {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(None);
        }
        match t.recv(remaining).await? {
            Some(frame) => {
                if pred(&frame) {
                    return Ok(Some(frame));
                }
            }
            None => {
                tokio::time::sleep(Duration::from_millis(1).min(remaining)).await;
            }
        }
    }
}

pub async fn battery<T: BleTransport>(t: &mut T) -> Result<u8> {
    battery_with_timeout(t, BATTERY_TIMEOUT).await
}

async fn battery_with_timeout<T: BleTransport>(t: &mut T, timeout: Duration) -> Result<u8> {
    let frame = Command::GetBattery.encode(NaiveDateTime::default())?;
    t.send(&frame).await?;

    // Ignore other/invalid frames while waiting.
    if let Some(frame) = recv_matching(t, timeout, |f| {
        matches!(protocol::decode(f), Ok(Response::Battery { .. }))
    })
    .await?
        && let Ok(Response::Battery { level }) = protocol::decode(&frame)
    {
        return Ok(level);
    }
    Err(format!(
        "no battery response from the watch within {}s",
        timeout.as_secs()
    )
    .into())
}

/// Send a command, then wait for its return-code frame on 0x8002
/// (payload [acked cmd, status]; only acks matching `command.code()` count).
async fn send_and_await_ack<T: BleTransport>(
    t: &mut T,
    command: &Command,
    now: NaiveDateTime,
    timeout: Duration,
) -> Result<Delivery> {
    let frame = command.encode(now)?;
    t.send(&frame).await?;
    let code = command.code();
    match recv_matching(
        t,
        timeout,
        |f| matches!(protocol::decode(f), Ok(Response::Ack { cmd, .. }) if cmd == code),
    )
    .await?
    {
        Some(frame) => match protocol::decode(&frame) {
            Ok(Response::Ack { status: 0, .. }) => Ok(Delivery::Accepted),
            Ok(Response::Ack { status, .. }) => Ok(Delivery::Rejected(status)),
            _ => unreachable!("pred only matches Ack frames"),
        },
        None => Ok(Delivery::NoReply),
    }
}

/// Send the SetTime frame, then wait up to `REPLY_TIMEOUT` for the watch's
/// return-code ack.
pub async fn sync_time<T: BleTransport>(t: &mut T, dt: DateTime<FixedOffset>) -> Result<Delivery> {
    sync_time_with_timeout(t, dt, REPLY_TIMEOUT).await
}

async fn sync_time_with_timeout<T: BleTransport>(
    t: &mut T,
    dt: DateTime<FixedOffset>,
    timeout: Duration,
) -> Result<Delivery> {
    send_and_await_ack(t, &Command::SetTime(dt), dt.naive_local(), timeout).await
}

pub async fn notify<T: BleTransport>(
    t: &mut T,
    kind: NotificationKind,
    title: &str,
    body: &str,
    now: NaiveDateTime,
) -> Result<Delivery> {
    notify_with_timeout(t, kind, title, body, now, REPLY_TIMEOUT).await
}

async fn notify_with_timeout<T: BleTransport>(
    t: &mut T,
    kind: NotificationKind,
    title: &str,
    body: &str,
    now: NaiveDateTime,
    timeout: Duration,
) -> Result<Delivery> {
    send_and_await_ack(
        t,
        &Command::SendNotification {
            kind,
            title: title.to_string(),
            body: body.to_string(),
        },
        now,
        timeout,
    )
    .await
}

/// Send any SEND command and wait for its return-code ack.
pub async fn apply<T: BleTransport>(t: &mut T, command: &Command) -> Result<Delivery> {
    send_and_await_ack(t, command, Local::now().naive_local(), REPLY_TIMEOUT).await
}

/// Send a REQUEST command and wait for its `0x80` reply; returns the reply
/// payload. `pred` can additionally filter on the payload bytes.
pub async fn request<T: BleTransport>(
    t: &mut T,
    command: &Command,
    timeout: Duration,
    pred: impl Fn(&[u8]) -> bool,
) -> Result<Vec<u8>> {
    let frame = command.encode(Local::now().naive_local())?;
    t.send(&frame).await?;
    let code = command.code();
    // GB dispatches replies on the cmd byte only (L813), not on the type.
    match recv_matching(t, timeout, |f| {
        f.len() >= 6 && f[1] == code && pred(&f[5..f.len() - 1])
    })
    .await?
    {
        Some(frame) => Ok(frame[5..frame.len() - 1].to_vec()),
        None => Err(format!(
            "no response to {} within {}s",
            protocol::command_name(code),
            timeout.as_secs()
        )
        .into()),
    }
}

// ---------------------------------------------------------------------------
// Composite commands
// ---------------------------------------------------------------------------

pub struct DeviceInfo {
    pub serial: String,
    pub firmware: String,
    pub hardware: String,
    pub battery: u8,
}

/// Serial + firmware + hardware + battery, 3s per request.
pub async fn info<T: BleTransport>(t: &mut T) -> Result<DeviceInfo> {
    let serial =
        parse::parse_watch_id(&request(t, &Command::GetWatchId, REQUEST_TIMEOUT, |_| true).await?)?;
    let firmware = parse::parse_version(
        &request(t, &Command::GetFirmwareVersion, REQUEST_TIMEOUT, |_| true).await?,
    )?;
    let hardware = parse::parse_version(
        &request(t, &Command::GetHardwareVersion, REQUEST_TIMEOUT, |_| true).await?,
    )?;
    let battery = battery_with_timeout(t, REQUEST_TIMEOUT).await?;
    Ok(DeviceInfo {
        serial,
        firmware,
        hardware,
        battery,
    })
}

/// Read every known setting; a timeout/parse failure becomes the `Err`
/// string for that line — never aborts the whole command.
pub async fn read_config<T: BleTransport>(
    t: &mut T,
) -> Result<Vec<(SettingId, std::result::Result<Setting, String>)>> {
    let mut out = Vec::new();
    for id in SettingId::ALL {
        let line = match request(t, &Command::ReadSetting(id), REQUEST_TIMEOUT, |_| true).await {
            Ok(payload) => parse::parse_setting(id, &payload).map_err(|e| e.to_string()),
            Err(e) => Err(e.to_string()),
        };
        out.push((id, line));
    }
    Ok(out)
}

/// Physical-button ids (0x2E) — see Command::SetButtonFunction.
fn button_name(id: u8) -> &'static str {
    match id {
        1 => "up",
        2 => "bottom",
        3 => "crown-short",
        4 => "crown-long",
        _ => "?",
    }
}

/// Function ids assignable to a button (decompiled-app table).
fn button_function_name(id: u8) -> &'static str {
    match id {
        0 => "none",
        1 => "dim screen",
        2 => "heart rate",
        3 => "calendar",
        4 => "music control",
        5 => "timer",
        6 => "camera",
        7 => "alarm",
        8 => "weather",
        9 => "home timezone",
        10 => "notification list",
        11 => "sms list",
        12 => "stopwatch",
        13 => "missed calls",
        14 => "activity data",
        15 => "sleep data",
        16 => "find my phone",
        17 => "do not disturb",
        18 => "silent mode",
        19 => "flight mode",
        _ => "?",
    }
}

/// Read the 0x2E button→function assignments as "button=function" lines.
/// Reported as one `Result` line like read_config entries — a timeout
/// becomes `Err`, never aborts the whole command.
pub async fn read_button_assignments<T: BleTransport>(
    t: &mut T,
) -> std::result::Result<Vec<String>, String> {
    let payload = request(t, &Command::GetButtonFunctions, REQUEST_TIMEOUT, |_| true)
        .await
        .map_err(|e| e.to_string())?;
    let records = parse::parse_button_assignments(&payload).map_err(|e| e.to_string())?;
    Ok(records
        .into_iter()
        .map(|(button, function)| {
            let f = button_function_name(function);
            match button_name(button) {
                "?" => format!("button{button}={f} ({function})"),
                name => format!("{name}={f}"),
            }
        })
        .collect())
}

/// Read the daily goals stored on the watch (0x50 GET → 15-byte reply).
pub async fn read_goals<T: BleTransport>(t: &mut T) -> Result<parse::Goals> {
    let p = request(t, &Command::GetGoals, REQUEST_TIMEOUT, |_| true).await?;
    Ok(parse::parse_goals(&p)?)
}

/// Read the user profile stored on the watch (0x30 GET → 5-byte reply).
pub async fn read_user_info<T: BleTransport>(t: &mut T) -> Result<parse::UserInfo> {
    let p = request(t, &Command::GetUserInfo, REQUEST_TIMEOUT, |_| true).await?;
    Ok(parse::parse_user_info(&p)?)
}

/// Read the night-mode config (0x21 GET → `[color][has_dial]`).
pub async fn read_night_mode<T: BleTransport>(t: &mut T) -> Result<parse::NightMode> {
    let p = request(t, &Command::GetNightMode, REQUEST_TIMEOUT, |_| true).await?;
    Ok(parse::parse_night_mode(&p)?)
}

/// Android QR pairing tail: bind start (0x93) → time sync → bind end
/// (0x94 SET [0x01]). Closes the watch's pairing-QR screen.
pub async fn qr_bind<T: BleTransport>(t: &mut T) -> Result<()> {
    apply(t, &Command::QrBindStart).await?;
    apply(t, &Command::SetTime(Local::now().fixed_offset())).await?;
    apply(t, &Command::BindEnd).await?;
    Ok(())
}

/// 0x97 edit frame (Android `encodeAlarmEdit`, live-confirmed): resolves
/// `slot` to its verbatim field block, then sends `[0x01] + existing +
/// new + content`. The watch has no stable alarm id — the field block IS
/// the identity. `None` fields keep the stored values.
#[allow(clippy::too_many_arguments)]
pub async fn edit_alarm<T: BleTransport>(
    t: &mut T,
    slot: u8,
    time: Option<(u8, u8)>,
    days: Option<u8>,
    enabled: Option<bool>,
    pattern: Option<SignalPattern>,
    alarm_type: Option<AlarmKind>,
    content: Option<&str>,
) -> Result<Delivery> {
    let alarms = list_alarms(t).await?;
    let entry = alarms
        .iter()
        .find(|a| a.slot == slot)
        .ok_or_else(|| format!("no alarm at slot {slot}"))?;
    let (hour, minute) = time.unwrap_or((entry.hour, entry.minute));
    apply(
        t,
        &Command::EditAlarm {
            existing: entry.fields(),
            hour,
            minute,
            days: days.unwrap_or(entry.cycle),
            enabled: enabled.unwrap_or(entry.enabled),
            pattern: pattern.unwrap_or_else(|| {
                signal_pattern_from_code(entry.shock).unwrap_or(SignalPattern::Beep)
            }),
            alarm_type: alarm_type.unwrap_or_else(|| {
                alarm_kind_from_code(entry.alarm_type).unwrap_or(AlarmKind::Alarm)
            }),
            content: content.unwrap_or("").to_string(),
        },
    )
    .await
}

/// Map a stored shock byte back to a `SignalPattern` (inverse of
/// `SignalPattern::code`); unknown codes fall back to `Beep` at the call
/// site via `unwrap_or`.
fn signal_pattern_from_code(code: u8) -> Option<SignalPattern> {
    [
        SignalPattern::VibrateOnce,
        SignalPattern::VibrateTwice,
        SignalPattern::Vibrate,
        SignalPattern::BeepOnce,
        SignalPattern::BeepTwice,
        SignalPattern::Beep,
        SignalPattern::VibrateBeepOnce,
        SignalPattern::VibrateBeep,
        SignalPattern::None,
    ]
    .into_iter()
    .find(|p| p.code() == code)
}

/// Map a stored alarm-type byte back to an `AlarmKind`.
fn alarm_kind_from_code(code: u8) -> Option<AlarmKind> {
    [
        AlarmKind::Medicine,
        AlarmKind::Water,
        AlarmKind::Alarm,
        AlarmKind::Custom,
    ]
    .into_iter()
    .find(|k| k.code() == code)
}

// ---------------------------------------------------------------------------
// Activity fetch
// ---------------------------------------------------------------------------

#[derive(Default)]
pub struct Activity {
    pub steps: Vec<StepRecord>,
    pub sleep: Vec<SleepRecord>,
    pub heart_rate: Vec<HeartRateRecord>,
    /// Non-fatal notes, e.g. a fetch that timed out mid-stream.
    pub errors: Vec<String>,
}

/// Fetch all activity records the watch has buffered. If `delete`, sends the
/// matching Delete… command — only after a *complete* fetch of that kind.
pub async fn fetch_activity<T: BleTransport>(t: &mut T, delete: bool) -> Result<Activity> {
    let payload = request(t, &Command::GetAvailableData, REQUEST_TIMEOUT, |_| true).await?;
    let avail: AvailableData = parse::parse_available_data(&payload)?;
    let mut activity = Activity::default();

    if avail.steps > 0 {
        t.send(&Command::GetStepData.encode(Local::now().naive_local())?)
            .await?;
        let (records, note) = collect_records(t, protocol::CMD_STEP_DATA, avail.steps, |p| {
            parse::parse_step_record(p).map(|r| {
                let index = r.index;
                (vec![r], index)
            })
        })
        .await?;
        activity.steps = records;
        if let Some(note) = note {
            activity.errors.push(note);
        } else if delete {
            delete_data(t, &Command::DeleteStepData, &mut activity.errors).await?;
        }
    }

    if avail.sleep > 0 {
        t.send(&Command::GetSleepData.encode(Local::now().naive_local())?)
            .await?;
        let (records, note) = collect_records(t, protocol::CMD_SLEEP_DATA, avail.sleep, |p| {
            parse::parse_sleep_record(p).map(|r| {
                let index = r.index;
                (vec![r], index)
            })
        })
        .await?;
        activity.sleep = records;
        if let Some(note) = note {
            activity.errors.push(note);
        } else if delete {
            delete_data(t, &Command::DeleteSleepData, &mut activity.errors).await?;
        }
    }

    if avail.heart_rate > 0 {
        t.send(&Command::GetHeartRateData.encode(Local::now().naive_local())?)
            .await?;
        // One frame may carry two records; completion is on the LAST index.
        let (records, note) =
            collect_records(t, protocol::CMD_HEART_RATE_DATA, avail.heart_rate, |p| {
                let rs = parse::parse_heart_rate_records(p)?;
                let last = rs.last().map(|r| r.index).unwrap_or(0);
                Ok((rs, last))
            })
            .await?;
        activity.heart_rate = records;
        if let Some(note) = note {
            activity.errors.push(note);
        } else if delete {
            delete_data(t, &Command::DeleteHeartRateData, &mut activity.errors).await?;
        }
    }

    Ok(activity)
}

/// Send a Delete… command; a missing or negative ack becomes an error note.
async fn delete_data<T: BleTransport>(
    t: &mut T,
    command: &Command,
    errors: &mut Vec<String>,
) -> Result<()> {
    let name = protocol::command_name(command.code());
    match apply(t, command).await? {
        Delivery::Accepted => {}
        Delivery::Rejected(s) => {
            errors.push(format!("{name} rejected by the watch (status {s:#04X})"))
        }
        Delivery::NoReply => errors.push(format!("{name} not acknowledged by the watch")),
    }
    Ok(())
}

/// Collect reply frames for `cmd` until a record's index reaches
/// `count` (per-frame timeout `ACTIVITY_FRAME_TIMEOUT`). On timeout, returns
/// what was collected plus an error note.
async fn collect_records<T: BleTransport, R>(
    t: &mut T,
    cmd: u8,
    count: u16,
    parse_frame: impl Fn(&[u8]) -> std::result::Result<(Vec<R>, u16), protocol::ProtocolError>,
) -> Result<(Vec<R>, Option<String>)> {
    let mut records = Vec::new();
    loop {
        // GB dispatches replies on the cmd byte only (L813), not on the type.
        match recv_matching(t, ACTIVITY_FRAME_TIMEOUT, |f| f.len() >= 6 && f[1] == cmd).await? {
            Some(frame) => {
                let (rs, last_index) = match parse_frame(&frame[5..frame.len() - 1]) {
                    Ok(v) => v,
                    Err(e) => {
                        return Ok((
                            records,
                            Some(format!(
                                "undecodable {} record: {e}",
                                protocol::command_name(cmd)
                            )),
                        ));
                    }
                };
                records.extend(rs);
                if last_index >= count {
                    return Ok((records, None));
                }
            }
            None => {
                let n = records.len();
                return Ok((
                    records,
                    Some(format!(
                        "timed out fetching {} ({n}/{count} records)",
                        protocol::command_name(cmd)
                    )),
                ));
            }
        }
    }
}

/// Push calendar events: opcode 1 for the first, 2 for the rest, max 17 events, 300 ms
/// between events (all per ZeTimeDeviceSupport.sendUpcomingCalendarEvents).
/// Every send is ack-checked; the per-event `Delivery`s are returned.
pub async fn send_calendar<T: BleTransport>(
    t: &mut T,
    events: &[(NaiveDateTime, String)],
) -> Result<Vec<Delivery>> {
    if events.len() > 17 {
        return Err(format!("too many calendar events: {} (max 17)", events.len()).into());
    }
    let mut deliveries = Vec::with_capacity(events.len());
    for (i, (at, title)) in events.iter().enumerate() {
        if i > 0 {
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        deliveries.push(
            send_and_await_ack(
                t,
                &Command::CalendarEvent {
                    opcode: if i == 0 { 1 } else { 2 },
                    at: *at,
                    title: title.clone(),
                },
                Local::now().naive_local(),
                REPLY_TIMEOUT,
            )
            .await?,
        );
    }
    Ok(deliveries)
}

/// List stored alarms/reminders: count via 0x91, then 0x97 streams one
/// 11-byte frame per slot. Later slots can be slow — generous idle window.
pub async fn list_alarms<T: BleTransport>(t: &mut T) -> Result<Vec<parse::AlarmEntry>> {
    let count_payload = request(t, &Command::GetAlarmCount, REQUEST_TIMEOUT, |_| true).await?;
    let count = count_payload.first().copied().unwrap_or(0) as usize;
    if count == 0 {
        return Ok(Vec::new());
    }
    let frame = Command::GetAlarms.encode(Local::now().naive_local())?;
    t.send(&frame).await?;
    let mut alarms = Vec::with_capacity(count);
    let deadline = Instant::now() + Duration::from_secs(15);
    while alarms.len() < count {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match t.recv(remaining).await? {
            Some(f)
                if f.len() >= 6
                    && f[1] == protocol::CMD_REMINDERS
                    && f[2] == protocol::CMD_REQUEST_RESPOND =>
            {
                if let Ok(a) = parse::parse_alarm(&f[5..f.len() - 1]) {
                    alarms.push(a);
                }
            }
            Some(_) => {}
            None => break,
        }
    }
    alarms.sort_by_key(|a| a.slot);
    Ok(alarms)
}

/// Delete the alarm/reminder at `slot`: reads it back to get its field
/// bytes, then sends the edit-with-collision delete frame.
pub async fn delete_alarm<T: BleTransport>(t: &mut T, slot: u8) -> Result<Delivery> {
    let alarms = list_alarms(t).await?;
    let entry = alarms
        .iter()
        .find(|a| a.slot == slot)
        .ok_or_else(|| format!("no alarm at slot {slot}"))?;
    let mut fields = [0u8; 10];
    fields[0] = entry.alarm_type;
    fields[1..3].copy_from_slice(&entry.year.to_le_bytes());
    fields[3] = entry.month;
    fields[4] = entry.day;
    fields[5] = entry.hour;
    fields[6] = entry.minute;
    fields[7] = entry.cycle;
    fields[8] = entry.enabled as u8;
    fields[9] = entry.shock;
    send_and_await_ack(
        t,
        &Command::DeleteAlarm { fields },
        Local::now().naive_local(),
        REPLY_TIMEOUT,
    )
    .await
}

// ---------------------------------------------------------------------------
// Quick replies (0xDA/0xDB — region 0xA2000, firmware A2.0.55)
// ---------------------------------------------------------------------------

/// Read the 0xDA metadata reply: one CRC per stored quick reply, in slot
/// order (the CRC is the stable identifier — indices shift on edits).
async fn quick_reply_meta<T: BleTransport>(t: &mut T) -> Result<parse::QuickReplyMeta> {
    let payload = request(t, &Command::GetQuickReplies, REQUEST_TIMEOUT, |_| true).await?;
    Ok(parse::parse_quick_reply_meta(&payload)?)
}

/// List the quick replies stored on the watch: count from 0xDA, then the
/// 0xDB GET[0] stream returns one `[index][crc:2le][text]` frame per
/// entry (same collection pattern as list_alarms).
pub async fn list_quick_replies<T: BleTransport>(t: &mut T) -> Result<Vec<parse::QuickReply>> {
    let count = quick_reply_meta(t).await?.crcs.len();
    if count == 0 {
        return Ok(Vec::new());
    }
    let frame = Command::GetQuickReply { crc: None }.encode(Local::now().naive_local())?;
    t.send(&frame).await?;
    let mut replies = Vec::with_capacity(count);
    let deadline = Instant::now() + Duration::from_secs(15);
    while replies.len() < count {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match t.recv(remaining).await? {
            Some(f)
                if f.len() >= 6
                    && f[1] == protocol::CMD_QUICK_REPLY
                    && f[2] == protocol::CMD_REQUEST_RESPOND =>
            {
                if let Ok(r) = parse::parse_quick_reply(&f[5..f.len() - 1]) {
                    replies.push(r);
                }
            }
            Some(_) => {}
            None => break,
        }
    }
    replies.sort_by_key(|r| r.index);
    Ok(replies)
}

/// Resolve a 1-based reply index to its stable CRC via 0xDA metadata.
async fn quick_reply_crc_at<T: BleTransport>(t: &mut T, index: u8) -> Result<u16> {
    let meta = quick_reply_meta(t).await?;
    index
        .checked_sub(1)
        .and_then(|i| meta.crcs.get(i as usize))
        .copied()
        .ok_or_else(|| {
            format!(
                "no quick reply at index {index} ({} stored)",
                meta.crcs.len()
            )
            .into()
        })
}

/// Insert `text` at 1-based `index` (later replies shift down; max 10).
/// Rewrites the whole region on the watch — a dropped link mid-write
/// leaves it inconsistent until the next successful write.
pub async fn insert_quick_reply<T: BleTransport>(
    t: &mut T,
    index: u8,
    text: &str,
) -> Result<Delivery> {
    send_and_await_ack(
        t,
        &Command::InsertQuickReply {
            index,
            text: text.to_string(),
        },
        Local::now().naive_local(),
        REPLY_TIMEOUT,
    )
    .await
}

/// Replace the text of the reply at 1-based `index` (resolved to its CRC
/// first — the wire op is addressed by content CRC, not position).
pub async fn update_quick_reply<T: BleTransport>(
    t: &mut T,
    index: u8,
    text: &str,
) -> Result<Delivery> {
    let crc = quick_reply_crc_at(t, index).await?;
    send_and_await_ack(
        t,
        &Command::UpdateQuickReply {
            crc,
            text: text.to_string(),
        },
        Local::now().naive_local(),
        REPLY_TIMEOUT,
    )
    .await
}

/// Delete the reply at 1-based `index` (resolved to its CRC first).
pub async fn delete_quick_reply<T: BleTransport>(t: &mut T, index: u8) -> Result<Delivery> {
    let crc = quick_reply_crc_at(t, index).await?;
    send_and_await_ack(
        t,
        &Command::DeleteQuickReply { crc },
        Local::now().naive_local(),
        REPLY_TIMEOUT,
    )
    .await
}

// ---------------------------------------------------------------------------
// Custom watchfaces (§8)
// ---------------------------------------------------------------------------

/// The 0x20 reply: `[watch_face_number][ota_address:4le]`.
/// `number == 0` means this exact image is already installed.
pub struct WatchfaceSlot {
    pub number: u8,
    pub ota_address: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WatchfaceOutcome {
    /// The image was transferred over DFU and activated.
    Uploaded,
    /// The CRC was already on the watch — we only switched to it.
    AlreadyInstalled,
}

/// Send a `0x20` CHECK/SET and return the slot reply, `None` on timeout.
async fn watchface_exchange<T: BleTransport>(
    t: &mut T,
    command: &Command,
    timeout: Duration,
) -> Result<Option<WatchfaceSlot>> {
    let frame = command.encode(Local::now().naive_local())?;
    t.send(&frame).await?;
    match recv_matching(t, timeout, |f| {
        f.len() >= 11 && f[1] == protocol::CMD_WATCHFACE_SET
    })
    .await?
    {
        Some(frame) => {
            let p = &frame[5..frame.len() - 1];
            Ok(Some(WatchfaceSlot {
                number: p[0],
                ota_address: u32::from_le_bytes(p[1..5].try_into().unwrap()),
            }))
        }
        None => Ok(None),
    }
}

/// Serial → predicted DFU advertised name (§8.4); best effort.
async fn dfu_name_hint<T: BleTransport>(t: &mut T) -> Option<String> {
    let payload = request(t, &Command::GetWatchId, REQUEST_TIMEOUT, |_| true)
        .await
        .ok()?;
    let serial = parse::parse_watch_id(&payload).ok()?;
    watchface::dfu_name(&serial)
}

/// Result of the pre-DFU watchface handshake (`0x20` CHECK/SET).
pub enum WatchfacePrep {
    /// Image already installed; re-activated with the new layout.
    AlreadyInstalled,
    /// Ready to push `content` to the DFU identity.
    Ready {
        content: Vec<u8>,
        ota_address: u32,
        content_crc: u16,
        dfu_name: Option<String>,
    },
}

/// `0x20` CHECK + SET is_ota=1: negotiates the slot and marks a watchface
/// OTA as pending. Stops before the reboot trigger — on firmware A2.0.55
/// the SET is ack'd but never reboots; the caller fires `Command::EnterDfu`.
pub async fn watchface_prepare<T: BleTransport>(
    t: &mut T,
    pixels: &[u8],
    layout: &WidgetLayout,
) -> Result<WatchfacePrep> {
    let crc = watchface::crc16(pixels);

    let dfu_name = dfu_name_hint(t).await;

    let check = Command::WatchfaceCheck { crc };
    let slot = watchface_exchange(t, &check, REQUEST_TIMEOUT)
        .await?
        .ok_or("no reply to the watchface CRC check")?;
    if slot.number == 0 {
        // Already installed: re-issue the SET with is_ota=0 to activate it.
        let set = Command::WatchfaceSet {
            payload: layout.set_payload(false, crc),
        };
        if watchface_exchange(t, &set, REPLY_TIMEOUT).await?.is_none() {
            eprintln!("warning: no reply to the watchface switch request");
        }
        return Ok(WatchfacePrep::AlreadyInstalled);
    }

    // is_ota=1 reboots the watch into DFU — on this firmware it may drop
    // the link without replying first, so the CHECK slot is the fallback.
    let set = Command::WatchfaceSet {
        payload: layout.set_payload(true, crc),
    };
    let slot = watchface_exchange(t, &set, REQUEST_TIMEOUT)
        .await?
        .unwrap_or(slot);
    if !(0xA1..=0xA4).contains(&slot.number) {
        eprintln!(
            "warning: unexpected watchface slot {:#04X} (expected 0xA1-0xA4)",
            slot.number
        );
    }

    let mut content = Vec::with_capacity(pixels.len() + 8);
    content.extend_from_slice(pixels);
    content.extend_from_slice(&watchface::trailer(crc, slot.number));
    let content_crc = watchface::crc16(&content);
    Ok(WatchfacePrep::Ready {
        content,
        ota_address: slot.ota_address,
        content_crc,
        dfu_name,
    })
}

/// Upload a custom watchface (§8): CRC check → 0x20 SET with is_ota=1 →
/// the watch reboots into DFU mode under a renamed identity → stream
/// `pixels + trailer` over service 0x1530 → activate.
///
/// If the image is already installed (CRC dedup), switches to it instead
/// of uploading (`WatchfaceOutcome::AlreadyInstalled`, no transfer).
pub async fn watchface_upload<T: BleTransport>(
    t: &mut T,
    pixels: &[u8],
    layout: &WidgetLayout,
) -> Result<WatchfaceOutcome> {
    let prep = watchface_prepare(t, pixels, layout).await?;
    let WatchfacePrep::Ready {
        content,
        ota_address,
        content_crc,
        dfu_name,
    } = prep
    else {
        return Ok(WatchfaceOutcome::AlreadyInstalled);
    };

    // A2.0.55: the 0x20 SET is ack'd but never reboots — fire the bare
    // 0x0E trigger that does. Fire-and-forget: the watch drops the link
    // instantly, no ack comes back.
    let _ = t
        .send(&Command::EnterDfu.encode(Local::now().naive_local())?)
        .await;

    println!(
        "Watch rebooting into update mode{}…",
        dfu_name
            .as_ref()
            .map(|n| format!(" as '{n}'"))
            .unwrap_or_default()
    );
    // The link drops as the watch reboots — a failed disconnect is fine.
    let _ = t.disconnect().await;
    t.dfu_transfer(
        dfu_name.as_deref(),
        &content,
        ota_address,
        content_crc,
        UPDATE_TYPE_WATCHFACE,
    )
    .await?;
    Ok(WatchfaceOutcome::Uploaded)
}

/// DFU update type for watchface/resource content (§8.4). Firmware files
/// carry their own type — see `ota_update_type`.
pub const UPDATE_TYPE_WATCHFACE: u8 = 4;

/// Guess the DFU update type from a package filename, using the decompiled
/// official app's table (apollo/telink → 1, touchpanel → 2, heartrate → 3,
/// gps → 6, everything else → 4 = picture/resources).
pub fn ota_update_type(file_name: &str) -> u8 {
    let n = file_name.to_ascii_lowercase();
    if n.contains("apollo") || n.contains("telink") {
        1
    } else if n.contains("touch") {
        2
    } else if n.contains("heart") {
        3
    } else if n.contains("gps") {
        6
    } else {
        4
    }
}

/// §8.4 firmware OTA. Package layout is `[target:4][content…]` — verified
/// on Apollo_2.0.55.bin (link addr 0x00012000, Cortex-M vectors at file
/// 0x40) and the Picture_3.0 set (each .bin carries its own 0x0002XX00
/// resource address). The first 4 bytes go verbatim to the 0x0E trigger;
/// bytes [4..] are streamed to the DFU identity with `update_type`.
///
/// RISK: an interrupted transfer is recoverable (separate bootloader), but
/// a wrongly-typed image flashed to the wrong partition may not be.
pub async fn ota<T: BleTransport>(
    t: &mut T,
    file_name: &str,
    bytes: &[u8],
    update_type: Option<u8>,
) -> Result<()> {
    if bytes.len() < 5 {
        return Err(format!("{file_name}: OTA file too small ({} bytes)", bytes.len()).into());
    }
    let address: [u8; 4] = bytes[0..4].try_into().unwrap();
    let content = &bytes[4..];
    let update_type = update_type.unwrap_or_else(|| ota_update_type(file_name));
    let content_crc = watchface::crc16(content);
    let dfu_name = dfu_name_hint(t).await;

    println!(
        "{file_name}: {} bytes → address {:02X} {:02X} {:02X} {:02X} (type {update_type}, crc {content_crc:#06X})",
        content.len(),
        address[0],
        address[1],
        address[2],
        address[3]
    );
    match send_and_await_ack(
        t,
        &Command::EnterUpgradeMode { address },
        Local::now().naive_local(),
        REQUEST_TIMEOUT,
    )
    .await?
    {
        Delivery::Rejected(status) => {
            return Err(format!("upgrade mode rejected by the watch (status {status})").into());
        }
        Delivery::NoReply => eprintln!("warning: no ack for upgrade mode; continuing anyway"),
        Delivery::Accepted => {}
    }

    // A2.0.55: the addressed 0x0E is ack'd but never reboots — the bare
    // [0x01] form does. Fire-and-forget: the watch drops the link
    // instantly, no ack comes back.
    let _ = t
        .send(&Command::EnterDfu.encode(Local::now().naive_local())?)
        .await;

    println!(
        "Watch rebooting into update mode{}…",
        dfu_name
            .as_ref()
            .map(|n| format!(" as '{n}'"))
            .unwrap_or_default()
    );
    // The link drops as the watch reboots — a failed disconnect is fine.
    let _ = t.disconnect().await;
    t.dfu_transfer(
        dfu_name.as_deref(),
        content,
        u32::from_le_bytes(address),
        content_crc,
        update_type,
    )
    .await
}

/// Switch the active face to an already-installed image (matched by the
/// pixel CRC). `Ok(false)` = the image isn't installed.
pub async fn watchface_switch<T: BleTransport>(
    t: &mut T,
    pixels: &[u8],
    layout: &WidgetLayout,
) -> Result<bool> {
    let crc = watchface::crc16(pixels);
    let check = Command::WatchfaceCheck { crc };
    let slot = watchface_exchange(t, &check, REQUEST_TIMEOUT)
        .await?
        .ok_or("no reply to the watchface CRC check")?;
    if slot.number != 0 {
        return Ok(false);
    }
    let set = Command::WatchfaceSet {
        payload: layout.set_payload(false, crc),
    };
    if watchface_exchange(t, &set, REPLY_TIMEOUT).await?.is_none() {
        eprintln!("warning: no reply to the watchface switch request");
    }
    Ok(true)
}

/// Delete custom faces by image CRC, or all of them with `None` (§8.2b).
pub async fn watchface_delete<T: BleTransport>(t: &mut T, crc: Option<u16>) -> Result<Delivery> {
    send_and_await_ack(
        t,
        &Command::WatchfaceDelete { crc },
        Local::now().naive_local(),
        REPLY_TIMEOUT,
    )
    .await
}

/// Decode and print one incoming frame, prefixed with the local time —
/// essential for measuring watch event cadence (find-phone 0xD2 bursts).
fn print_incoming(frame: &[u8]) {
    let ts = Local::now().format("%H:%M:%S%.3f");
    match parse::parse_watch_event(frame) {
        Some(event) => println!("{ts} {} → {:?}", to_hex(frame), event),
        None => println!("{ts} {} → {:?}", to_hex(frame), protocol::decode(frame)),
    }
}

/// Opcode à acquitter pour un événement watch, comme le fait l'app iOS
/// (ack générique = return-code echo sur 0x8003). `None` pour les
/// événements qui attendent une vraie réponse (music state, cardio…).
fn ack_cmd_for(event: &parse::WatchEvent) -> Option<u8> {
    match event {
        parse::WatchEvent::Music(_) => Some(0xD0),
        parse::WatchEvent::Camera => Some(0xD1),
        parse::WatchEvent::FindPhone => Some(0xD2),
        parse::WatchEvent::Sos => Some(0xD9),
        parse::WatchEvent::QuickReply(ev) => Some(ev.opcode),
        _ => None,
    }
}

/// `--ack-events` : reproduit le comportement de l'app iOS — chaque
/// événement watch éligible reçoit immédiatement son ack générique.
async fn maybe_ack_event<T: BleTransport>(t: &mut T, frame: &[u8]) -> Result<()> {
    let Some(event) = parse::parse_watch_event(frame) else {
        return Ok(());
    };
    let Some(cmd) = ack_cmd_for(&event) else {
        return Ok(());
    };
    let ack = Command::GenericAck {
        echoed_cmd: cmd,
        status: 0,
    }
    .encode(Local::now().naive_local())?;
    t.send_reply(&ack).await?;
    println!("  ↳ ack 0x{cmd:02X}");
    Ok(())
}

/// Second Ctrl+C while waiting forces a process exit (disconnect may hang).
fn spawn_force_quit() {
    tokio::spawn(async {
        if tokio::signal::ctrl_c().await.is_ok() {
            eprintln!("Forced exit");
            std::process::exit(130);
        }
    });
}

/// Print incoming frames until Ctrl+C. Watch→phone events (music control,
/// call rejection) arrive on 0x8004 and are decoded; with `ack_events`
/// they get the same generic ack the iOS app sends on 0x8003.
pub async fn monitor<T: BleTransport>(t: &mut T, ack_events: bool) -> Result<()> {
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                println!("Stopping… (press Ctrl+C again to force quit)");
                spawn_force_quit();
                return Ok(());
            }
            frame = t.recv(Duration::from_secs(1)) => {
                // None = poll timeout, keep waiting
                if let Some(frame) = frame? {
                    if ack_events {
                        maybe_ack_event(t, &frame).await?;
                    }
                    print_incoming(&frame);
                }
            }
        }
    }
}

/// Send a raw frame (0x8003 if `reply`, else 0x8001+ack), then print
/// whatever the watch returns within 2s.
pub async fn raw_send<T: BleTransport>(t: &mut T, frame: &[u8], reply: bool) -> Result<()> {
    if reply {
        t.send_reply(frame).await?;
    } else {
        t.send(frame).await?;
    }
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(());
        }
        match t.recv(remaining).await? {
            Some(f) => print_incoming(&f),
            None => return Ok(()),
        }
    }
}

/// Read the reply characteristic 0x8003 and print its raw bytes.
pub async fn raw_read_reply<T: BleTransport>(t: &mut T) -> Result<()> {
    let data = t.read_reply().await?;
    println!(
        "[READ 00008003-0000-1000-8000-00805f9b34fb] {}",
        data.iter()
            .map(|b| format!("{b:02X}"))
            .collect::<Vec<_>>()
            .join(" ")
    );
    Ok(())
}

/// Keep the connection alive for `stay` after a command, printing incoming
/// frames (e.g. a call rejection pressed on the watch). Ctrl+C cuts short.
pub async fn stay<T: BleTransport>(t: &mut T, stay: Duration, ack_events: bool) -> Result<()> {
    let deadline = Instant::now() + stay;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Ok(());
        }
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                println!("Disconnecting early… (press Ctrl+C again to force quit)");
                spawn_force_quit();
                return Ok(());
            }
            frame = t.recv(remaining.min(Duration::from_secs(1))) => {
                match frame? {
                    Some(frame) => {
                        if ack_events {
                            maybe_ack_event(t, &frame).await?;
                        }
                        print_incoming(&frame);
                    }
                    None => tokio::time::sleep(Duration::from_millis(100)).await,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transport::MockTransport;
    use chrono::TimeZone;

    fn now_naive() -> NaiveDateTime {
        NaiveDateTime::parse_from_str("2026-10-26T17:30:45", "%Y-%m-%dT%H:%M:%S").unwrap()
    }

    #[tokio::test]
    async fn battery_reads_level() {
        let mut t = MockTransport::new(42);
        assert_eq!(battery(&mut t).await.unwrap(), 42);
    }

    #[tokio::test]
    async fn battery_times_out_on_silence() {
        let mut t = MockTransport::silent();
        let start = Instant::now();
        let result = battery_with_timeout(&mut t, Duration::from_millis(50)).await;
        assert!(result.is_err());
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test]
    async fn sync_time_sends_set_time_frame() {
        let dt = FixedOffset::east_opt(3600)
            .unwrap()
            .with_ymd_and_hms(2026, 10, 26, 17, 30, 45)
            .unwrap();
        let mut t = MockTransport::new(0);
        let delivery = sync_time_with_timeout(&mut t, dt, Duration::from_millis(50))
            .await
            .unwrap();
        let expected = Command::SetTime(dt).encode(now_naive()).unwrap();
        assert_eq!(t.sent, vec![expected]);
        assert_eq!(delivery, Delivery::Accepted);
    }

    #[tokio::test]
    async fn sync_time_rejected() {
        let dt = FixedOffset::east_opt(3600)
            .unwrap()
            .with_ymd_and_hms(2026, 10, 26, 17, 30, 45)
            .unwrap();
        let mut t = MockTransport::rejecting(1);
        let delivery = sync_time_with_timeout(&mut t, dt, Duration::from_millis(50))
            .await
            .unwrap();
        assert_eq!(delivery, Delivery::Rejected(1));
    }

    #[tokio::test]
    async fn sync_time_no_reply() {
        let dt = FixedOffset::east_opt(3600)
            .unwrap()
            .with_ymd_and_hms(2026, 10, 26, 17, 30, 45)
            .unwrap();
        let mut t = MockTransport::silent();
        let start = Instant::now();
        let delivery = sync_time_with_timeout(&mut t, dt, Duration::from_millis(50))
            .await
            .unwrap();
        assert_eq!(delivery, Delivery::NoReply);
        assert!(start.elapsed() < Duration::from_secs(1));
    }

    #[tokio::test]
    async fn notify_sends_notification_frame() {
        let mut t = MockTransport::new(0);
        let delivery = notify(
            &mut t,
            NotificationKind::Sms,
            "Rappel",
            "Réunion",
            now_naive(),
        )
        .await
        .unwrap();
        let expected = Command::SendNotification {
            kind: NotificationKind::Sms,
            title: "Rappel".into(),
            body: "Réunion".into(),
        }
        .encode(now_naive())
        .unwrap();
        assert_eq!(t.sent, vec![expected]);
        assert_eq!(delivery, Delivery::Accepted);
    }

    #[tokio::test]
    async fn info_reads_all_fields() {
        let mut t = MockTransport::new(80);
        let info = info(&mut t).await.unwrap();
        assert_eq!(info.serial, "MOCK00000001");
        assert_eq!(info.firmware, "MOCK-FW");
        assert_eq!(info.hardware, "MOCK-HW");
        assert_eq!(info.battery, 80);
    }

    #[tokio::test]
    async fn read_config_all_ok() {
        let mut t = MockTransport::new(0);
        let config = read_config(&mut t).await.unwrap();
        assert_eq!(config.len(), 20);
        for (id, line) in &config {
            assert!(line.is_ok(), "{:?} → {:?}", id, line);
        }
    }

    #[tokio::test]
    async fn fetch_activity_collects_records() {
        let mut t = MockTransport::new(0);
        let activity = fetch_activity(&mut t, false).await.unwrap();
        assert_eq!(activity.steps.len(), 2);
        assert_eq!(activity.sleep.len(), 1);
        assert_eq!(activity.heart_rate.len(), 3);
        assert!(activity.errors.is_empty());
        // no Delete… sent without --delete
        assert!(t.sent.iter().all(|f| f[1] != protocol::CMD_DELETE_STEP_DATA
            && f[1] != protocol::CMD_DELETE_SLEEP_DATA
            && f[1] != protocol::CMD_DELETE_HEART_RATE_DATA));
    }

    #[tokio::test]
    async fn fetch_activity_delete_after_complete_fetch() {
        let mut t = MockTransport::new(0);
        fetch_activity(&mut t, true).await.unwrap();
        let delete_cmds: Vec<u8> = t
            .sent
            .iter()
            .filter(|f| {
                matches!(
                    f[1],
                    protocol::CMD_DELETE_STEP_DATA
                        | protocol::CMD_DELETE_SLEEP_DATA
                        | protocol::CMD_DELETE_HEART_RATE_DATA
                )
            })
            .map(|f| f[1])
            .collect();
        assert_eq!(
            delete_cmds,
            [
                protocol::CMD_DELETE_STEP_DATA,
                protocol::CMD_DELETE_SLEEP_DATA,
                protocol::CMD_DELETE_HEART_RATE_DATA
            ]
        );
    }

    #[tokio::test]
    async fn send_calendar_opcodes() {
        let mut t = MockTransport::new(0);
        let events: Vec<(NaiveDateTime, String)> = (1..=3)
            .map(|i| (now_naive(), format!("event {i}")))
            .collect();
        let deliveries = send_calendar(&mut t, &events).await.unwrap();
        assert_eq!(deliveries, vec![Delivery::Accepted; 3]);
        // opcode = first payload byte of each sent frame: 1 then 2, 2
        let opcodes: Vec<u8> = t.sent.iter().map(|f| f[5]).collect();
        assert_eq!(opcodes, [1, 2, 2]);
    }

    #[test]
    fn ota_update_type_from_filename() {
        for (name, expected) in [
            ("Apollo_2.0.55.bin", 1u8),
            ("Telink.bin", 1),
            ("TouchPanel_3.3.bin", 2),
            ("heartrate_0.5.bin", 3),
            ("gps_chip.bin", 6),
            ("Picture_3.0.bin", 4),
            ("anything_else.bin", 4),
        ] {
            assert_eq!(ota_update_type(name), expected, "{name}");
        }
    }

    #[tokio::test]
    async fn ota_sends_upgrade_mode_then_dfu() {
        // 0x0E carries the .bin's first 4 bytes; content = bytes [4..].
        // (sent[0] is the GetWatchId probe for the DFU name.)
        let mut t = MockTransport::new(0);
        let mut pkg = vec![0x00, 0x00, 0x02, 0x05];
        pkg.extend_from_slice(&[0xAA; 100]);
        ota(&mut t, "Apollo_2.0.55.bin", &pkg, None).await.unwrap();
        let upgrade = [
            0x6F, 0x0E, 0x71, 0x05, 0x00, 0x01, 0x00, 0x00, 0x02, 0x05, 0x8F,
        ];
        assert!(t.sent.iter().any(|f| f == &upgrade), "{:?}", t.sent);
    }

    #[tokio::test]
    async fn ota_rejects_tiny_file() {
        let mut t = MockTransport::new(0);
        let err = ota(&mut t, "x.bin", &[0x00; 3], None).await.unwrap_err();
        assert!(err.to_string().contains("too small"));
    }
}
