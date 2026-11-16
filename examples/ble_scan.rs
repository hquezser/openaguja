//! Passive diagnostic: list every advertising peripheral (name, RSSI,
//! advertised services) for N seconds (default 40). Never connects or writes —
//! safe to use while hunting for the watch under another name (e.g. DFU mode).
use btleplug::api::{Central, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;
use std::collections::BTreeMap;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let secs: u64 = std::env::args()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(40);
    let manager = Manager::new().await?;
    let adapter = manager
        .adapters()
        .await?
        .into_iter()
        .next()
        .ok_or("no adapter")?;
    adapter.start_scan(ScanFilter::default()).await?;
    tokio::time::sleep(Duration::from_secs(secs)).await;
    let mut seen = BTreeMap::new();
    for p in adapter.peripherals().await? {
        if let Some(pr) = p.properties().await? {
            let services: Vec<String> = pr
                .services
                .iter()
                .map(|u| u.to_string()[..8].to_owned())
                .collect();
            let data: Vec<String> = pr
                .manufacturer_data
                .iter()
                .map(|(id, d)| {
                    format!(
                        "{id:04X}:{}",
                        d.iter().map(|b| format!("{b:02X}")).collect::<String>()
                    )
                })
                .collect();
            seen.insert(
                p.id().to_string(),
                format!(
                    "{:<24} rssi={:<5} svc=[{}] mfr=[{}]",
                    pr.local_name.unwrap_or_else(|| "-".into()),
                    pr.rssi.map(|r| r.to_string()).unwrap_or_else(|| "?".into()),
                    services.join(","),
                    data.join(",")
                ),
            );
        }
    }
    adapter.stop_scan().await?;
    for (id, line) in seen {
        println!("{id} {line}");
    }
    Ok(())
}
