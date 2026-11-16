//! Custom watchfaces: image → BGR565 payload, CRC16, the `0x20`
//! negotiation payload and the DFU-mode advertised name.
//!
//! Protocol: zetime.artificialred.nl §8 (reverse-engineered from the
//! official app, live-confirmed end-to-end — Gadgetbridge has none of it).

use crate::Result;
use std::path::Path;

/// Big face 240×240 + small home-screen thumbnail 180×180, both BGR565
/// little-endian: 115_200 + 64_800 bytes (§8.1).
pub const PIXEL_LEN: usize = 240 * 240 * 2 + 180 * 180 * 2;
const BIG: u32 = 240;
const SMALL: u32 = 180;

/// CRC-CCITT "CCITT-FALSE" (poly 0x1021, init 0xFFFF, no reflection, no
/// final xor) — the same CRC Nordic's DFU bootloader uses (§8.5).
pub fn crc16(data: &[u8]) -> u16 {
    let mut crc = 0xFFFFu16;
    for &b in data {
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

/// RGB pixel → 16-bit BGR565 `(B<<11)|(G<<5)|R` at 5/6/5 bits, alpha
/// composited onto black (§8.1).
fn bgr565(px: image::Rgba<u8>) -> u16 {
    let a = px[3] as u16;
    let r = px[0] as u16 * a / 255;
    let g = px[1] as u16 * a / 255;
    let b = px[2] as u16 * a / 255;
    ((b & 0xF8) << 8) | ((g & 0xFC) << 3) | (r >> 3)
}

fn to_bgr565(img: &image::RgbaImage) -> Vec<u8> {
    let mut out = Vec::with_capacity((img.width() * img.height() * 2) as usize);
    for px in img.pixels() {
        out.extend_from_slice(&bgr565(*px).to_le_bytes());
    }
    out
}

/// Decode `path` (PNG/JPEG), resize to 240×240 (+ the 180×180 thumbnail,
/// 0.75×), return the 180_000-byte BGR565 pixel payload.
pub fn load_image(path: &Path) -> Result<Vec<u8>> {
    let img = image::open(path)
        .map_err(|e| format!("cannot decode {}: {e}", path.display()))?
        .to_rgba8();
    let resize =
        |w: u32| image::imageops::resize(&img, w, w, image::imageops::FilterType::Lanczos3);
    let mut out = Vec::with_capacity(PIXEL_LEN);
    out.extend_from_slice(&to_bgr565(&resize(BIG)));
    out.extend_from_slice(&to_bgr565(&resize(SMALL)));
    Ok(out)
}

/// 8-byte trailer appended after the pixel payload before transfer (§8.3):
/// `[crc_lo, crc_hi, watch_face_number, "UFACE"]`. `watch_face_number`
/// comes from the 0x20 negotiation reply.
pub fn trailer(crc: u16, watch_face_number: u8) -> [u8; 8] {
    let [lo, hi] = crc.to_le_bytes();
    [lo, hi, watch_face_number, b'U', b'F', b'A', b'C', b'E']
}

/// DFU-mode advertised name: prefix from serial chars 5-6 (0-indexed) +
/// the serial's last 5 chars (§8.4). `None` when the unit's serial
/// doesn't match a known prefix.
pub fn dfu_name(serial: &str) -> Option<String> {
    let prefix = match serial.get(5..7) {
        Some("35") => "07B",
        Some("31") => "07A",
        Some("33") => "28Q",
        Some("34") => "38Q",
        _ => return None,
    };
    let tail = serial.get(serial.len().saturating_sub(5)..)?;
    Some(format!("{prefix}{tail}"))
}

/// Widget positions on the 240×240 face → the 23-byte `0x20` SET payload
/// (§8.2). Every widget defaults to "not placed".
#[derive(Debug, Clone, Default)]
pub struct WidgetLayout {
    pub heart_rate: Option<(u8, u8)>,
    pub steps: Option<(u8, u8)>,
    pub calories: Option<(u8, u8)>,
    pub distance: Option<(u8, u8)>,
    pub date: Option<(u8, u8)>,
    pub weather: Option<(u8, u8)>,
    pub battery: Option<(u8, u8)>,
    /// The app's "sport time" = the ACTIVE_MINUTE widget.
    pub active_minutes: Option<(u8, u8)>,
    /// Second timezone line: `(position 0|1, color 0-7)` — the only
    /// non-[x,y] field.
    pub home_time: Option<(u8, u8)>,
    /// Running-seconds indicator (SECOND_POINT).
    pub seconds_dot: bool,
}

impl WidgetLayout {
    /// Place a widget by its `--widget` name at `x,y` (pixel coords on the
    /// 240×240 face; for `home-time`, `x`=position 0|1, `y`=color 0-7).
    pub fn place(&mut self, name: &str, x: u8, y: u8) -> std::result::Result<(), String> {
        let slot = match name {
            "heart-rate" => &mut self.heart_rate,
            "steps" => &mut self.steps,
            "calories" => &mut self.calories,
            "distance" => &mut self.distance,
            "date" => &mut self.date,
            "weather" => &mut self.weather,
            "battery" => &mut self.battery,
            "active-minutes" => &mut self.active_minutes,
            "home-time" => {
                if x > 1 {
                    return Err("home-time position must be 0 or 1".into());
                }
                if y > 7 {
                    return Err("home-time color must be 0-7".into());
                }
                &mut self.home_time
            }
            other => {
                return Err(format!(
                    "unknown widget '{other}' (expected heart-rate|steps|calories|distance|date|weather|battery|active-minutes|home-time)"
                ));
            }
        };
        *slot = Some((x, y));
        Ok(())
    }

    /// The 23-byte `0x20` SET payload (§8.2). `is_ota`: 1 when a DFU
    /// transfer follows, 0 to reposition widgets/switch face only.
    pub fn set_payload(&self, is_ota: bool, crc: u16) -> [u8; 23] {
        let pos = |p: Option<(u8, u8)>| p.map(|(x, y)| [x, y]).unwrap_or([0xFF, 0xFF]);
        let mut p = [0u8; 23];
        p[0] = is_ota as u8;
        p[1..3].copy_from_slice(&crc.to_le_bytes());
        p[3..5].copy_from_slice(&pos(self.heart_rate));
        p[5..7].copy_from_slice(&pos(self.steps));
        p[7..9].copy_from_slice(&pos(self.calories));
        p[9..11].copy_from_slice(&pos(self.distance));
        p[11..13].copy_from_slice(&pos(self.date));
        p[13] = 0xFF; // watchFaceType: the only observed value is -1
        p[14..16].copy_from_slice(&pos(self.weather));
        p[16] = if self.seconds_dot { 0x01 } else { 0xFF };
        p[17..19].copy_from_slice(&pos(self.battery));
        p[19..21].copy_from_slice(&pos(self.active_minutes));
        // [position, color] — not a coordinate pair.
        p[21..23].copy_from_slice(&self.home_time.map(|(a, b)| [a, b]).unwrap_or([0, 0]));
        p
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crc16_ccitt_false() {
        // Standard check value for "123456789" (§8.5).
        assert_eq!(crc16(b"123456789"), 0x29B1);
        assert_eq!(crc16(&[]), 0xFFFF);
    }

    #[test]
    fn bgr565_primary_colors() {
        // BGR565: (B<<11)|(G<<5)|R, little-endian.
        assert_eq!(
            bgr565(image::Rgba([255, 0, 0, 255])).to_le_bytes(),
            [0x1F, 0x00]
        );
        assert_eq!(
            bgr565(image::Rgba([0, 255, 0, 255])).to_le_bytes(),
            [0xE0, 0x07]
        );
        assert_eq!(
            bgr565(image::Rgba([0, 0, 255, 255])).to_le_bytes(),
            [0x00, 0xF8]
        );
        assert_eq!(
            bgr565(image::Rgba([0, 0, 0, 255])).to_le_bytes(),
            [0x00, 0x00]
        );
        // Transparent composites to black.
        assert_eq!(
            bgr565(image::Rgba([255, 255, 255, 0])).to_le_bytes(),
            [0x00, 0x00]
        );
    }

    #[test]
    fn trailer_layout() {
        assert_eq!(
            trailer(0x1234, 0xA2),
            [0x34, 0x12, 0xA2, b'U', b'F', b'A', b'C', b'E']
        );
    }

    #[test]
    fn dfu_name_prefixes() {
        assert_eq!(dfu_name("171213533053").as_deref(), Some("07B33053"));
        assert_eq!(dfu_name("xxxxx3112345").as_deref(), Some("07A12345"));
        assert_eq!(dfu_name("xx00xx12345"), None);
        assert_eq!(dfu_name("35"), None);
    }

    #[test]
    fn set_payload_empty_layout() {
        let p = WidgetLayout::default().set_payload(true, 0xBEEF);
        assert_eq!(p.len(), 23);
        assert_eq!(p[0], 0x01);
        assert_eq!(&p[1..3], &[0xEF, 0xBE]);
        assert_eq!(&p[3..13], &[0xFF; 10]);
        assert_eq!(p[13], 0xFF);
        assert_eq!(&p[14..16], &[0xFF; 2]);
        assert_eq!(p[16], 0xFF);
        assert_eq!(&p[17..21], &[0xFF; 4]);
        assert_eq!(&p[21..23], &[0, 0]);
    }

    #[test]
    fn set_payload_widgets() {
        let mut l = WidgetLayout {
            seconds_dot: true,
            ..Default::default()
        };
        l.place("steps", 120, 200).unwrap();
        l.place("date", 10, 20).unwrap();
        l.place("home-time", 1, 5).unwrap();
        let p = l.set_payload(false, 0x0000);
        assert_eq!(p[0], 0x00);
        assert_eq!(&p[5..7], &[120, 200]);
        assert_eq!(&p[11..13], &[10, 20]);
        assert_eq!(p[16], 0x01);
        assert_eq!(&p[21..23], &[1, 5]);
    }

    #[test]
    fn place_rejects_bad_input() {
        let mut l = WidgetLayout::default();
        assert!(l.place("nope", 0, 0).is_err());
        assert!(l.place("home-time", 2, 0).is_err());
        assert!(l.place("home-time", 0, 8).is_err());
    }
}
