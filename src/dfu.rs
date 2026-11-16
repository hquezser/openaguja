//! Nordic "legacy DFU"-style transfer used for watchface images (§8.4).
//!
//! After the `0x20` SET negotiation the watch reboots and re-advertises
//! under a different name, exposing only service 0x1530 (control point
//! 0x1531, data 0x1532). The transfer is a 6-stage handshake; the data
//! stage is paced per-chunk acks over 20-byte BLE writes.

use crate::Result;
use crate::protocol::to_hex;
use crate::transport::get_central;
use btleplug::api::{
    Central, CentralEvent, CharPropFlags, Characteristic, Peripheral as _, ScanFilter,
    ValueNotification, WriteType, bleuuid::uuid_from_u16,
};
use btleplug::platform::{Adapter, Manager, Peripheral};
use futures::{Stream, StreamExt};
use std::time::Duration;

const SERVICE: u16 = 0x1530;
const CONTROL: u16 = 0x1531;
const DATA: u16 = 0x1532;
/// Pages are split 2000 + remainder; each chunk is acked before the next.
const PAGE_LEN: usize = 2048;
const CHUNK_LEN: usize = 2000;
const FRAG_LEN: usize = 20;
/// Host-paced delay between 20-byte writes (§8.4 "mandatory
/// inter-fragment delay"; value not pinned down — 15 ms is conservative).
const FRAG_DELAY: Duration = Duration::from_millis(15);
const ACK_TIMEOUT: Duration = Duration::from_secs(10);
const SCAN_TIMEOUT: Duration = Duration::from_secs(90);
/// Grace period for the watch to reboot into DFU mode.
const REBOOT_DELAY: Duration = Duration::from_secs(3);

/// Connect to the DFU-mode identity and transfer `content` to `ota_address`.
/// `update_type` selects the target partition (1=Apollo, 2=TouchPanel,
/// 3=Heartrate, 4=Picture/watchface, 6=GPS). `content_crc` covers the full
/// content.
pub async fn upload(
    dfu_name: Option<&str>,
    content: &[u8],
    ota_address: u32,
    content_crc: u16,
    update_type: u8,
    verbose: bool,
) -> Result<()> {
    tokio::time::sleep(REBOOT_DELAY).await;
    let manager = Manager::new().await?;
    let central = get_central(&manager).await?;
    let peripheral = find_dfu(&central, dfu_name, verbose).await?;
    peripheral.connect().await?;
    peripheral.discover_services().await?;

    let control = find_char(&peripheral, CONTROL)?;
    let data = find_char(&peripheral, DATA)?;
    let mut notifications = peripheral.notifications().await?;
    peripheral.subscribe(&control).await?;

    let run = async {
        // 1. Note / 2. Init / 3. Set — control-point handshake (§8.4).
        write_char(&peripheral, &control, &[0x01, 0x01], verbose).await?;
        await_ack(&mut notifications, &[0x01, 0x00], "note", verbose).await?;

        let mut init = vec![0x01];
        init.extend_from_slice(&(content.len() as u32).to_le_bytes());
        write_char(&peripheral, &control, &init, verbose).await?;
        await_ack(&mut notifications, &[0x01, 0x01], "init", verbose).await?;

        let mut set = vec![0x02, update_type];
        set.extend_from_slice(&ota_address.to_le_bytes());
        set.extend_from_slice(&(content.len() as u32).to_le_bytes());
        set.extend_from_slice(&content_crc.to_le_bytes());
        set.extend_from_slice(&[0x00, 0x00, 0x64]);
        write_char(&peripheral, &control, &set, verbose).await?;
        await_ack(&mut notifications, &[0x02, 0x01], "set", verbose).await?;

        // 4. Data: per 2048-byte page, one ~2000-byte chunk then the
        // remainder; each chunk acked with the cumulative byte count.
        let total = content.len();
        let mut sent = 0usize;
        for page in content.chunks(PAGE_LEN) {
            for chunk in page.chunks(CHUNK_LEN) {
                for frag in chunk.chunks(FRAG_LEN) {
                    write_char(&peripheral, &data, frag, false).await?;
                    tokio::time::sleep(FRAG_DELAY).await;
                }
                sent += chunk.len();
                await_data_ack(&mut notifications, sent as u32).await?;
                if verbose || sent.is_multiple_of(16 * PAGE_LEN) || sent == total {
                    println!("DFU: {sent}/{total} bytes ({}%)", sent * 100 / total);
                }
            }
        }

        // 5. CRC check / 6. Activate.
        write_char(&peripheral, &control, &[0x04], verbose).await?;
        await_ack(&mut notifications, &[0x04, 0x01], "crc check", verbose).await?;
        write_char(&peripheral, &control, &[0x05], verbose).await?;
        await_ack(&mut notifications, &[0x05, 0x01], "activate", verbose).await?;
        Ok(())
    };

    let result: Result<()> = run.await;
    let _ = peripheral.disconnect().await;
    result
}

/// Wait for an exact notify value on the control characteristic.
async fn await_ack<S>(notifications: &mut S, want: &[u8], what: &str, verbose: bool) -> Result<()>
where
    S: Stream<Item = ValueNotification> + Unpin,
{
    let got = next_control(notifications, |v| v == want).await?;
    if verbose {
        println!("[DFU RX] {} ({what})", to_hex(&got));
    }
    Ok(())
}

/// Wait for a data-chunk ack `[0x03, 0x01, _, cumulative:u32le]` and check
/// the cumulative count matches what we've written so far.
async fn await_data_ack<S>(notifications: &mut S, sent: u32) -> Result<()>
where
    S: Stream<Item = ValueNotification> + Unpin,
{
    let got = next_control(notifications, |v| {
        v.len() >= 7 && v[0] == 0x03 && v[1] == 0x01
    })
    .await?;
    let cumulative = u32::from_le_bytes(got[3..7].try_into().unwrap());
    if cumulative != sent {
        return Err(
            format!("DFU data ack out of sync: watch got {cumulative}, we sent {sent}").into(),
        );
    }
    Ok(())
}

/// Next notification matching `pred`, or a timeout error.
async fn next_control<S>(notifications: &mut S, pred: impl Fn(&[u8]) -> bool) -> Result<Vec<u8>>
where
    S: Stream<Item = ValueNotification> + Unpin,
{
    tokio::time::timeout(ACK_TIMEOUT, async {
        while let Some(n) = notifications.next().await {
            if pred(&n.value) {
                return n.value;
            }
        }
        Vec::new()
    })
    .await
    .ok()
    .filter(|v| !v.is_empty())
    .ok_or_else(|| "timed out waiting for the watch's DFU response".into())
}

/// A DFU-mode ZeTime advertises an 8-hex-digit name like `07B33053`
/// (serial-derived, see watchface::dfu_name), optionally followed by a
/// bracketed slot address. Used when no `dfu_name` hint is available.
fn looks_like_dfu_name(name: &str) -> bool {
    name.len() >= 8 && name.starts_with("07") && name[..8].bytes().all(|b| b.is_ascii_hexdigit())
}

/// Scan for the DFU-mode peripheral: name-prefix match when `dfu_name` is
/// known, any DFU-patterned name otherwise, or a device advertising
/// service 0x1530.
async fn find_dfu(central: &Adapter, dfu_name: Option<&str>, verbose: bool) -> Result<Peripheral> {
    let mut events = central.events().await?;
    central.start_scan(ScanFilter::default()).await?;
    let dfu_uuid = uuid_from_u16(SERVICE);

    let found = tokio::time::timeout(SCAN_TIMEOUT, async {
        while let Some(event) = events.next().await {
            let id = match event {
                CentralEvent::DeviceDiscovered(id) | CentralEvent::DeviceUpdated(id) => id,
                _ => continue,
            };
            let peripheral = central.peripheral(&id).await?;
            let Some(props) = peripheral.properties().await? else {
                continue;
            };
            // A2.0.55 advertises e.g. "07B33053 [07A00000]" — the slot
            // address is appended to the DFU name, so match by prefix.
            let name_match = props.local_name.as_deref().is_some_and(|ln| {
                dfu_name.is_some_and(|n| ln.starts_with(n)) || looks_like_dfu_name(ln)
            });
            let service_match = props.services.contains(&dfu_uuid);
            if name_match || service_match {
                println!(
                    "Found DFU device {} ({})",
                    props.local_name.as_deref().unwrap_or("?"),
                    id
                );
                return Ok(peripheral);
            } else if verbose {
                eprintln!(
                    "[DFU scan] skipping {} ({})",
                    props.local_name.as_deref().unwrap_or("?"),
                    id
                );
            }
        }
        Err("adapter event stream ended during DFU scan".into())
    })
    .await;

    central.stop_scan().await?;
    found.map_err(|_| -> Box<dyn std::error::Error + Send + Sync> {
        format!(
            "timed out after {}s waiting for the watch's DFU identity{}",
            SCAN_TIMEOUT.as_secs(),
            dfu_name.map(|n| format!(" '{n}'")).unwrap_or_default()
        )
        .into()
    })?
}

fn find_char(p: &Peripheral, uuid16: u16) -> Result<Characteristic> {
    let uuid = uuid_from_u16(uuid16);
    p.characteristics()
        .into_iter()
        .find(|ch| ch.uuid == uuid)
        .ok_or_else(|| format!("DFU characteristic {uuid} not found").into())
}

async fn write_char(p: &Peripheral, ch: &Characteristic, data: &[u8], verbose: bool) -> Result<()> {
    let write_type = if ch.properties.contains(CharPropFlags::WRITE) {
        WriteType::WithResponse
    } else {
        WriteType::WithoutResponse
    };
    if verbose {
        println!("[DFU TX {}] {}", ch.uuid, to_hex(data));
    }
    p.write(ch, data, write_type).await?;
    Ok(())
}
