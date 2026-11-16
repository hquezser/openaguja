//! One-off diagnostic: enumerate the watch's GATT services while it runs the
//! normal app, then try the Nordic "buttonless DFU" trigger on 0x1531 if the
//! DFU service 0x1530 is exposed.
use btleplug::api::{Central, Manager as _, Peripheral as _, ScanFilter, WriteType};
use btleplug::platform::Manager;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let manager = Manager::new().await?;
    let adapter = manager
        .adapters()
        .await?
        .into_iter()
        .next()
        .ok_or("no adapter")?;
    adapter.start_scan(ScanFilter::default()).await?;
    let mut found = None;
    for _ in 0..30 {
        tokio::time::sleep(Duration::from_secs(1)).await;
        for p in adapter.peripherals().await? {
            let name = p
                .properties()
                .await?
                .and_then(|pr| pr.local_name)
                .unwrap_or_default();
            if name.contains("ZeTime") || name.contains("07B3") {
                println!("found {name}");
                found = Some(p);
                break;
            }
        }
        if found.is_some() {
            break;
        }
    }
    adapter.stop_scan().await?;
    let p = found.ok_or("watch not found")?;
    p.connect().await?;
    p.discover_services().await?;
    println!("services:");
    for s in p.services() {
        println!("  {}", s.uuid);
        for c in &s.characteristics {
            println!("    {} {:?}", c.uuid, c.properties);
        }
    }
    // Nordic legacy DFU: service 0x1530, control 0x1531, data 0x1532.
    let ctl = p.characteristics().into_iter().find(|c| {
        c.uuid.as_u128() == 0x1531_u128 << 96 | 0x00001000800000805f9b34fb
            || c.uuid.to_string().starts_with("00001531")
    });
    match ctl {
        Some(c) => {
            println!("DFU control found — writing 0x06 (system reset)");
            p.write(&c, &[0x06], WriteType::WithResponse).await?;
            println!("written");
        }
        None => println!("no DFU control characteristic in app mode"),
    }
    p.disconnect().await.ok();
    Ok(())
}
