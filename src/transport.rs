//! Transports: real BLE via btleplug, and an offline mock for `--mock`.

use crate::Result;
use crate::protocol::{self, Reassembler, to_hex};
use btleplug::api::{
    Central, CentralEvent, CharPropFlags, Characteristic, Manager as _, Peripheral as _,
    ScanFilter, WriteType, bleuuid::uuid_from_u16,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::StreamExt;
use std::collections::{HashMap, VecDeque};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

pub trait BleTransport {
    /// Send one frame: chunked writes to TX, then the 0x03 ack byte.
    fn send(&mut self, frame: &[u8]) -> impl Future<Output = Result<()>> + Send;
    /// Send one frame to the reply characteristic 0x8003 (chunked, no ack
    /// byte) — the channel GB's replyMsgToWatch uses for e.g. music volume.
    fn send_reply(&mut self, frame: &[u8]) -> impl Future<Output = Result<()>> + Send;
    /// Read the current value of the reply characteristic 0x8003.
    fn read_reply(&mut self) -> impl Future<Output = Result<Vec<u8>>> + Send;
    /// Next complete reassembled frame, or `None` on timeout.
    fn recv(&mut self, timeout: Duration) -> impl Future<Output = Result<Option<Vec<u8>>>> + Send;
    /// Transfer `content` to the watch's DFU-mode identity (§8.4) over
    /// service 0x1530. `dfu_name` is the predicted advertised name — `None`
    /// falls back to scanning for the DFU service. Hardware-only; the mock
    /// just logs and returns.
    fn dfu_transfer(
        &mut self,
        dfu_name: Option<&str>,
        content: &[u8],
        ota_address: u32,
        content_crc: u16,
        update_type: u8,
    ) -> impl Future<Output = Result<()>> + Send;
    fn disconnect(&mut self) -> impl Future<Output = Result<()>> + Send;
}

// ---------------------------------------------------------------------------
// Real BLE transport (btleplug / CoreBluetooth)
// ---------------------------------------------------------------------------

const NAME_PATTERN: &str = "zetime";
const DISCONNECT_TIMEOUT: Duration = Duration::from_secs(5);

// Known ZeTime UUIDs (16-bit, base 0000xxxx-0000-1000-8000-00805f9b34fb):
//   services: 0x6006 (base), 0x7006 (extend), 0x180D (heart rate)
//   characteristics: 0x8001 write, 0x8002 ack, 0x8003 reply, 0x8004 notify,
//                    0x8005, 0x2A37 heart rate measurement
const TX_CHAR_UUID_16: u16 = 0x8001;
const ACK_CHAR_UUID_16: u16 = 0x8002;
const REPLY_CHAR_UUID_16: u16 = 0x8003;

pub struct BtleplugTransport {
    peripheral: Peripheral,
    tx: Characteristic,
    ack: Characteristic,
    reply: Option<Characteristic>,
    rx: mpsc::Receiver<Vec<u8>>,
    rx_task: JoinHandle<()>,
    verbose: bool,
}

impl BtleplugTransport {
    pub async fn connect(scan_timeout: Duration, verbose: bool) -> Result<Self> {
        let manager = Manager::new().await?;
        let central = get_central(&manager).await?;
        let peripheral = find_zetime(&central, scan_timeout).await?;

        peripheral.connect().await?;
        peripheral.discover_services().await?;

        if verbose {
            print_gatt(&peripheral);
        }

        let tx = find_tx_characteristic(&peripheral)?;
        let ack = find_characteristic(&peripheral, ACK_CHAR_UUID_16)
            .ok_or("ACK characteristic 0x8002 not found")?;
        let reply = find_characteristic(&peripheral, REPLY_CHAR_UUID_16);

        // Grab the notification stream before subscribing so nothing is missed.
        let mut notifications = peripheral.notifications().await?;

        let mut subscribed = 0usize;
        for service in peripheral.services() {
            for ch in &service.characteristics {
                if ch
                    .properties
                    .intersects(CharPropFlags::NOTIFY | CharPropFlags::INDICATE)
                {
                    peripheral.subscribe(ch).await?;
                    if verbose {
                        println!("Subscribed to {}", ch.uuid);
                    }
                    subscribed += 1;
                }
            }
        }
        if subscribed == 0 {
            eprintln!("warning: no notifiable/indicatable characteristic found");
        }

        // Reassemble frames per characteristic: replies on e.g. 0x8002 and
        // 0x8004 must never be concatenated into one buffer.
        let (frame_tx, rx) = mpsc::channel(64);
        let rx_task = tokio::spawn(async move {
            let mut reassemblers: HashMap<_, Reassembler> = HashMap::new();
            while let Some(n) = notifications.next().await {
                if verbose {
                    println!("[RX {}] {}", n.uuid, to_hex(&n.value));
                }
                for frame in reassemblers
                    .entry(n.uuid)
                    .or_insert_with(Reassembler::new)
                    .push(&n.value)
                {
                    if frame_tx.send(frame).await.is_err() {
                        return;
                    }
                }
            }
        });

        Ok(Self {
            peripheral,
            tx,
            ack,
            reply,
            rx,
            rx_task,
            verbose,
        })
    }

    async fn write_characteristic(&self, ch: &Characteristic, data: &[u8]) -> Result<()> {
        let write_type = if ch.properties.contains(CharPropFlags::WRITE) {
            WriteType::WithResponse
        } else {
            WriteType::WithoutResponse
        };
        if self.verbose {
            println!("[TX {}] {}", ch.uuid, to_hex(data));
        }
        self.peripheral.write(ch, data, write_type).await?;
        Ok(())
    }
}

impl BleTransport for BtleplugTransport {
    async fn send(&mut self, frame: &[u8]) -> Result<()> {
        // Gadgetbridge sendMsgToWatch: ≤20-byte chunks to TX, then ack byte.
        for chunk in protocol::chunks(frame) {
            self.write_characteristic(&self.tx, chunk).await?;
        }
        self.write_characteristic(&self.ack, &[protocol::CMD_ACK_WRITE])
            .await
    }

    async fn send_reply(&mut self, frame: &[u8]) -> Result<()> {
        let reply = self
            .reply
            .clone()
            .ok_or("reply characteristic 0x8003 not found")?;
        for chunk in protocol::chunks(frame) {
            self.write_characteristic(&reply, chunk).await?;
        }
        Ok(())
    }

    async fn read_reply(&mut self) -> Result<Vec<u8>> {
        let reply = self
            .reply
            .clone()
            .ok_or("reply characteristic 0x8003 not found")?;
        Ok(self.peripheral.read(&reply).await?)
    }

    async fn recv(&mut self, timeout: Duration) -> Result<Option<Vec<u8>>> {
        match tokio::time::timeout(timeout, self.rx.recv()).await {
            Ok(Some(frame)) => Ok(Some(frame)),
            Ok(None) => Err("notification channel closed".into()),
            Err(_) => Ok(None),
        }
    }

    async fn dfu_transfer(
        &mut self,
        dfu_name: Option<&str>,
        content: &[u8],
        ota_address: u32,
        content_crc: u16,
        update_type: u8,
    ) -> Result<()> {
        crate::dfu::upload(
            dfu_name,
            content,
            ota_address,
            content_crc,
            update_type,
            self.verbose,
        )
        .await
    }

    async fn disconnect(&mut self) -> Result<()> {
        self.rx_task.abort();
        match tokio::time::timeout(DISCONNECT_TIMEOUT, self.peripheral.disconnect()).await {
            Ok(result) => result?,
            Err(_) => eprintln!(
                "warning: disconnect timed out after {}s",
                DISCONNECT_TIMEOUT.as_secs()
            ),
        }
        Ok(())
    }
}

pub(crate) async fn get_central(manager: &Manager) -> Result<Adapter> {
    manager
        .adapters()
        .await?
        .into_iter()
        .next()
        .ok_or_else(|| "no Bluetooth adapter found".into())
}

// A system-connected/paired watch stops advertising — check the known
// peripherals first (a previously discovered Peripheral may still be in
// the manager map). System-held links (bluetoothd) are NOT reachable this
// way: the device must be forgotten in System Settings to make it
// advertise again.
async fn find_zetime(central: &Adapter, scan_timeout: Duration) -> Result<Peripheral> {
    for p in central.peripherals().await? {
        if let Some(props) = p.properties().await?
            && props
                .local_name
                .as_deref()
                .is_some_and(|n| n.to_lowercase().contains(NAME_PATTERN))
        {
            println!(
                "Found {} ({}) [known]",
                props.local_name.unwrap_or_default(),
                p.id()
            );
            return Ok(p);
        }
    }
    let mut events = central.events().await?;
    central.start_scan(ScanFilter::default()).await?;

    let found = tokio::time::timeout(scan_timeout, async {
        while let Some(event) = events.next().await {
            let id = match event {
                CentralEvent::DeviceDiscovered(id) | CentralEvent::DeviceUpdated(id) => id,
                _ => continue,
            };
            let peripheral = central.peripheral(&id).await?;
            let Some(props) = peripheral.properties().await? else {
                continue;
            };
            let Some(name) = props.local_name else {
                continue;
            };
            if name.to_lowercase().contains(NAME_PATTERN) {
                println!("Found {} ({})", name, id);
                return Ok(peripheral);
            }
        }
        Err("adapter event stream ended without finding ZeTime".into())
    })
    .await;

    central.stop_scan().await?;

    match found {
        Ok(result) => result,
        Err(_) => Err(format!(
            "timed out after {}s scanning for a device named '{}'",
            scan_timeout.as_secs(),
            NAME_PATTERN
        )
        .into()),
    }
}

fn print_gatt(p: &Peripheral) {
    let tx_uuid = uuid_from_u16(TX_CHAR_UUID_16);
    for service in p.services() {
        println!("Service {} (primary: {})", service.uuid, service.primary);
        for ch in &service.characteristics {
            let mut mark = "";
            if ch.uuid == tx_uuid {
                mark = " <TX>";
            } else if ch
                .properties
                .intersects(CharPropFlags::NOTIFY | CharPropFlags::INDICATE)
            {
                mark = " <RX>";
            }
            println!(
                "  {} [{}]{}",
                ch.uuid,
                prop_flags_to_string(ch.properties),
                mark
            );
        }
    }
}

fn prop_flags_to_string(flags: CharPropFlags) -> String {
    let mut parts = Vec::new();
    if flags.contains(CharPropFlags::READ) {
        parts.push("Read");
    }
    if flags.contains(CharPropFlags::WRITE) {
        parts.push("Write");
    }
    if flags.contains(CharPropFlags::WRITE_WITHOUT_RESPONSE) {
        parts.push("WriteWithoutResponse");
    }
    if flags.contains(CharPropFlags::NOTIFY) {
        parts.push("Notify");
    }
    if flags.contains(CharPropFlags::INDICATE) {
        parts.push("Indicate");
    }
    if parts.is_empty() {
        format!("{flags:?}")
    } else {
        parts.join(", ")
    }
}

fn find_tx_characteristic(p: &Peripheral) -> Result<Characteristic> {
    let tx_uuid = uuid_from_u16(TX_CHAR_UUID_16);
    let mut fallback = None;
    for service in p.services() {
        for ch in &service.characteristics {
            if ch.uuid == tx_uuid {
                return Ok(ch.clone());
            }
            if fallback.is_none()
                && ch
                    .properties
                    .intersects(CharPropFlags::WRITE | CharPropFlags::WRITE_WITHOUT_RESPONSE)
            {
                fallback = Some(ch.clone());
            }
        }
    }
    match fallback {
        Some(ch) => {
            eprintln!(
                "warning: TX characteristic {tx_uuid} not found, falling back to {}",
                ch.uuid
            );
            Ok(ch)
        }
        None => Err("no writable characteristic found (TX)".into()),
    }
}

fn find_characteristic(p: &Peripheral, uuid16: u16) -> Option<Characteristic> {
    let uuid = uuid_from_u16(uuid16);
    p.characteristics().into_iter().find(|ch| ch.uuid == uuid)
}

// ---------------------------------------------------------------------------
// Mock transport (offline, --mock)
// ---------------------------------------------------------------------------

pub struct MockTransport {
    battery_level: u8,
    pub sent: Vec<Vec<u8>>,
    inbox: VecDeque<Vec<u8>>,
    replies: bool,
    ack_status: u8,
}

impl MockTransport {
    pub fn new(battery_level: u8) -> Self {
        Self {
            battery_level,
            sent: Vec::new(),
            inbox: VecDeque::new(),
            replies: true,
            ack_status: 0,
        }
    }

    /// A watch that rejects every SEND frame with the given status.
    #[allow(dead_code)] // used by tests
    pub fn rejecting(status: u8) -> Self {
        Self {
            ack_status: status,
            ..Self::new(0)
        }
    }

    /// A watch that never answers.
    #[allow(dead_code)] // used by tests and available for a future --mock variant
    pub fn silent() -> Self {
        Self {
            replies: false,
            ..Self::new(0)
        }
    }

    /// Queue a complete reply frame. Return-code frames get type 0x81,
    /// data replies type 0x80 (as GB expects them).
    fn push_frame(&mut self, cmd: u8, payload: &[u8]) {
        let kind = if cmd == protocol::CMD_RETURN_CODE {
            protocol::TYPE_RETURN_CODE
        } else {
            protocol::CMD_REQUEST_RESPOND
        };
        let len = payload.len() as u16;
        let mut frame = Vec::with_capacity(payload.len() + 6);
        frame.extend_from_slice(&[
            protocol::CMD_PREAMBLE,
            cmd,
            kind,
            (len & 0xFF) as u8,
            (len >> 8) as u8,
        ]);
        frame.extend_from_slice(payload);
        frame.push(protocol::CMD_END);
        self.inbox.push_back(frame);
    }

    fn push_version(&mut self, echo: u8, s: &[u8]) {
        let mut p = vec![echo];
        p.extend_from_slice(s);
        self.push_frame(protocol::CMD_DEVICE_VERSION, &p);
    }

    /// Raw watch timestamp for synthetic records: decodes to
    /// 2026-10-26 08:00:00 + `offset_secs` local wall time
    /// (watch_timestamp = raw + 28800 as UTC).
    fn mock_ts(offset_secs: u32) -> u32 {
        1_792_972_800 + offset_secs
    }

    fn is_setting(cmd: u8) -> bool {
        protocol::SettingId::ALL.iter().any(|id| id.cmd() == cmd)
    }

    /// Plausible fixed ReadSetting payloads (all parse cleanly).
    fn setting_payload(cmd: u8) -> Option<Vec<u8>> {
        use protocol::SettingId as S;
        Some(match S::ALL.iter().find(|id| id.cmd() == cmd).copied()? {
            S::TimeSurface => vec![0x01, 0x01], // yy-mm-dd, 24h
            S::Signaling => vec![13, 0, 13, 12, 2, 12, 12, 12, 12, 4],
            S::DoNotDisturb => vec![0x01, 22, 0, 7, 0],
            S::AnalogMode => vec![0x01],
            S::ActivityTracking => vec![0x00, 0x0A],
            S::ScreenTime => vec![60, 0],
            S::Wrist => vec![0x01],
            S::HeartRateInterval => vec![0x00],
            S::HeartRateLimits => vec![200, 60, 0x01],
            S::Inactivity => vec![0x80 | 0x7F, 60, 8, 0, 22, 0, 0x64, 0x00],
            S::CaloriesType => vec![0x01],
            S::DisplayOnMovement => vec![0x01, 0x40],
            S::NotificationSwitches => vec![0x01, 0x40],
            // 0x90 est partagé : `find` retourne DisplayOnMovement en
            // premier — ce bras n'est atteint que si l'ordre change.
            S::SleepSwitches => vec![0x01, 0x40],
            S::AutoSleepWindow => vec![23, 0, 9, 0, 0x7F],
            S::Units => vec![0x00],
            S::Volume => vec![0x03],
            S::Brightness => vec![0x05],
            S::Snooze => vec![0x0A],
            S::TextSize => vec![0x02],
            // BrightScreenTime is write-only and not in ALL — unreachable.
            S::BrightScreenTime => unreachable!(),
        })
    }
}

impl BleTransport for MockTransport {
    async fn send(&mut self, frame: &[u8]) -> Result<()> {
        for chunk in protocol::chunks(frame) {
            println!("[MOCK TX] {}", to_hex(chunk));
        }
        println!("[MOCK TX] {:02X}", protocol::CMD_ACK_WRITE);
        self.sent.push(frame.to_vec());
        if !self.replies || frame.len() < 3 || frame[0] != protocol::CMD_PREAMBLE {
            return Ok(());
        }
        match (frame[1], frame[2]) {
            // 0x20 CHECK/SET reply [watch_face_number][ota_address LE]:
            // pretend a fresh slot at a plausible flash address.
            (protocol::CMD_WATCHFACE_SET, protocol::CMD_REQUEST | protocol::CMD_SEND) => {
                self.push_frame(protocol::CMD_WATCHFACE_SET, &[0xA1, 0x00, 0x40, 0x02, 0x00]);
            }
            // SEND frame → return-code ack (verified on hardware:
            // 6F 01 81 02 00 <acked cmd> <status> 8F).
            (_, protocol::CMD_SEND) => {
                self.push_frame(protocol::CMD_RETURN_CODE, &[frame[1], self.ack_status]);
            }
            // REQUEST replies below are synthetic but GB-format.
            (protocol::CMD_WATCH_ID, protocol::CMD_REQUEST) => {
                self.push_frame(protocol::CMD_WATCH_ID, b"MOCK00000001");
            }
            (protocol::CMD_DEVICE_VERSION, protocol::CMD_REQUEST) => {
                // payload[0] echoes the requested kind: 5 = fw, 2 = hw
                match frame.get(5).copied().unwrap_or(0) {
                    5 => self.push_version(5, b"MOCK-FW"),
                    _ => self.push_version(2, b"MOCK-HW"),
                }
            }
            (protocol::CMD_BATTERY_POWER, protocol::CMD_REQUEST) => {
                self.push_frame(protocol::CMD_BATTERY_POWER, &[self.battery_level]);
            }
            // steps 2, sleep 1, heart rate 3 (u16 LE)
            (protocol::CMD_AVAILABLE_DATA, protocol::CMD_REQUEST) => {
                self.push_frame(protocol::CMD_AVAILABLE_DATA, &[2, 0, 1, 0, 3, 0]);
            }
            (protocol::CMD_STEP_DATA, protocol::CMD_REQUEST) => {
                for index in 1u16..=2 {
                    let mut p = index.to_le_bytes().to_vec();
                    p.extend_from_slice(&Self::mock_ts(index as u32 * 3600).to_le_bytes());
                    p.extend_from_slice(&(1000u32 * index as u32).to_le_bytes()); // steps
                    p.extend_from_slice(&(60u32 * index as u32).to_le_bytes()); // kcal
                    p.extend_from_slice(&(800u32 * index as u32).to_le_bytes()); // m
                    p.extend_from_slice(&(30u32 * index as u32).to_le_bytes()); // active min
                    self.push_frame(protocol::CMD_STEP_DATA, &p);
                }
            }
            (protocol::CMD_SLEEP_DATA, protocol::CMD_REQUEST) => {
                let mut p = 1u16.to_le_bytes().to_vec();
                p.extend_from_slice(&Self::mock_ts(0).to_le_bytes());
                p.push(0x00); // deep sleep
                self.push_frame(protocol::CMD_SLEEP_DATA, &p);
            }
            (protocol::CMD_HEART_RATE_DATA, protocol::CMD_REQUEST) => {
                // one 14-byte double-record frame (indexes 1, 2)…
                let mut p = 1u16.to_le_bytes().to_vec();
                p.extend_from_slice(&Self::mock_ts(0).to_le_bytes());
                p.push(68);
                p.extend_from_slice(&2u16.to_le_bytes());
                p.extend_from_slice(&Self::mock_ts(600).to_le_bytes());
                p.push(71);
                self.push_frame(protocol::CMD_HEART_RATE_DATA, &p);
                // …then a 7-byte single (index 3)
                let mut p = 3u16.to_le_bytes().to_vec();
                p.extend_from_slice(&Self::mock_ts(1200).to_le_bytes());
                p.push(75);
                self.push_frame(protocol::CMD_HEART_RATE_DATA, &p);
            }
            (protocol::CMD_REMIND_COUNT, protocol::CMD_REQUEST) => {
                self.push_frame(protocol::CMD_REMIND_COUNT, &[1]);
            }
            (protocol::CMD_REMINDERS, protocol::CMD_REQUEST) => {
                // one stored alarm: slot 1, type 4 (alarm), 08:30, every day
                self.push_frame(
                    protocol::CMD_REMINDERS,
                    &[1, 4, 0, 0, 0, 0, 8, 30, 0x7F, 1, 7],
                );
            }
            (cmd, protocol::CMD_REQUEST) if Self::is_setting(cmd) => {
                if let Some(p) = Self::setting_payload(cmd) {
                    self.push_frame(cmd, &p);
                }
            }
            _ => {}
        }
        Ok(())
    }

    async fn send_reply(&mut self, frame: &[u8]) -> Result<()> {
        for chunk in protocol::chunks(frame) {
            println!("[MOCK TX 8003] {}", to_hex(chunk));
        }
        self.sent.push(frame.to_vec());
        Ok(())
    }

    async fn read_reply(&mut self) -> Result<Vec<u8>> {
        Ok(Vec::new())
    }

    async fn recv(&mut self, _timeout: Duration) -> Result<Option<Vec<u8>>> {
        Ok(self.inbox.pop_front())
    }

    async fn dfu_transfer(
        &mut self,
        _dfu_name: Option<&str>,
        content: &[u8],
        ota_address: u32,
        content_crc: u16,
        update_type: u8,
    ) -> Result<()> {
        println!(
            "[MOCK] DFU transfer skipped: {} bytes → {ota_address:#010X} (type {update_type}, crc {content_crc:#06X})",
            content.len()
        );
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<()> {
        Ok(())
    }
}
