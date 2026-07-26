use std::io::{self, Cursor, Write as _};

use crate::protocol::MAX_CLIPBOARD_IMAGE_PAYLOAD;

pub(super) const MAX_DIB_CLIPBOARD_BYTES: usize = 64 * 1024 * 1024;

const PNG_SIGNATURE: &[u8; 8] = b"\x89PNG\r\n\x1a\n";
const MAX_IMAGE_DIMENSION: u32 = 16_384;
const MAX_IMAGE_PIXELS: usize = 16 * 1024 * 1024;
const BITMAPINFOHEADER_SIZE: usize = 40;
const BI_RGB: u32 = 0;
const BI_BITFIELDS: u32 = 3;
const BI_ALPHABITFIELDS: u32 = 6;

pub(super) fn validated_png(bytes: &[u8]) -> Option<Vec<u8>> {
    let logical_len = png_logical_len(bytes)?;
    if logical_len > MAX_CLIPBOARD_IMAGE_PAYLOAD {
        return None;
    }
    let bytes = &bytes[..logical_len];

    let mut decoder = png::Decoder::new_with_limits(
        Cursor::new(bytes),
        png::Limits {
            bytes: MAX_CLIPBOARD_IMAGE_PAYLOAD,
        },
    );
    decoder.set_ignore_text_chunk(true);
    decoder.set_ignore_iccp_chunk(true);
    let mut reader = decoder.read_info().ok()?;
    let info = reader.info();
    validate_dimensions(info.width, info.height)?;
    if info.animation_control.is_some() {
        return None;
    }

    while reader.next_interlaced_row().ok()?.is_some() {}
    reader.finish().ok()?;
    Some(bytes.to_vec())
}

fn png_logical_len(bytes: &[u8]) -> Option<usize> {
    if !bytes.starts_with(PNG_SIGNATURE) {
        return None;
    }

    let mut offset = PNG_SIGNATURE.len();
    while offset < bytes.len() {
        let length = usize::try_from(read_u32_be(bytes, offset)?).ok()?;
        let chunk_type_start = offset.checked_add(4)?;
        let data_start = chunk_type_start.checked_add(4)?;
        let data_end = data_start.checked_add(length)?;
        let chunk_end = data_end.checked_add(4)?;
        if chunk_end > bytes.len() {
            return None;
        }
        let chunk_type = bytes.get(chunk_type_start..data_start)?;
        if chunk_type == b"IEND" {
            return (length == 0).then_some(chunk_end);
        }
        offset = chunk_end;
    }
    None
}

pub(super) fn dib_to_png(bytes: &[u8]) -> Option<Vec<u8>> {
    let dib = DibView::parse(bytes)?;
    dib.encode_png()
}

struct DibView<'a> {
    width: u32,
    height: u32,
    top_down: bool,
    stride: usize,
    pixels: &'a [u8],
    pixel_format: DibPixelFormat,
}

#[derive(Clone, Copy)]
enum DibPixelFormat {
    Bgr24,
    Masked {
        bytes_per_pixel: usize,
        red: ChannelMask,
        green: ChannelMask,
        blue: ChannelMask,
        alpha: Option<ChannelMask>,
    },
}

#[derive(Clone, Copy)]
struct ChannelMask {
    mask: u32,
    shift: u32,
    maximum: u32,
}

impl ChannelMask {
    fn parse(mask: u32, bit_count: u16) -> Option<Self> {
        if mask == 0 || bit_count == 0 || bit_count > 32 {
            return None;
        }
        if bit_count < 32 && mask >= (1_u32 << bit_count) {
            return None;
        }
        let shift = mask.trailing_zeros();
        let shifted = mask >> shift;
        if shifted & shifted.wrapping_add(1) != 0 {
            return None;
        }
        Some(Self {
            mask,
            shift,
            maximum: shifted,
        })
    }

    fn extract(self, pixel: u32) -> u8 {
        let value = (pixel & self.mask) >> self.shift;
        ((u64::from(value) * 255 + u64::from(self.maximum) / 2) / u64::from(self.maximum)) as u8
    }
}

impl<'a> DibView<'a> {
    fn parse(bytes: &'a [u8]) -> Option<Self> {
        let header_size = usize::try_from(read_u32_le(bytes, 0)?).ok()?;
        if !matches!(header_size, 40 | 52 | 56 | 108 | 124) || bytes.len() < header_size {
            return None;
        }

        let width = read_i32_le(bytes, 4)?;
        let signed_height = read_i32_le(bytes, 8)?;
        if width <= 0 || signed_height == 0 || signed_height == i32::MIN {
            return None;
        }
        let width = u32::try_from(width).ok()?;
        let height = signed_height.unsigned_abs();
        validate_dimensions(width, height)?;
        if read_u16_le(bytes, 12)? != 1 {
            return None;
        }

        let bit_count = read_u16_le(bytes, 14)?;
        let compression = read_u32_le(bytes, 16)?;
        let declared_image_size = usize::try_from(read_u32_le(bytes, 20)?).ok()?;
        let color_entries = usize::try_from(read_u32_le(bytes, 32)?).ok()?;
        let (pixel_format, external_mask_bytes) =
            parse_pixel_format(bytes, header_size, bit_count, compression)?;

        let palette_bytes = color_entries.checked_mul(4)?;
        let pixel_offset = header_size
            .checked_add(external_mask_bytes)?
            .checked_add(palette_bytes)?;
        let row_bits = usize::try_from(width)
            .ok()?
            .checked_mul(usize::from(bit_count))?;
        let stride = row_bits.checked_add(31)?.checked_div(32)?.checked_mul(4)?;
        let image_size = stride.checked_mul(usize::try_from(height).ok()?)?;
        if declared_image_size != 0 && declared_image_size < image_size {
            return None;
        }
        let pixel_end = pixel_offset.checked_add(image_size)?;
        let pixels = bytes.get(pixel_offset..pixel_end)?;

        Some(Self {
            width,
            height,
            top_down: signed_height < 0,
            stride,
            pixels,
            pixel_format,
        })
    }

    fn encode_png(&self) -> Option<Vec<u8>> {
        let mut output = LimitedWriter::new(MAX_CLIPBOARD_IMAGE_PAYLOAD);
        {
            let mut encoder = png::Encoder::new(&mut output, self.width, self.height);
            encoder.set_color(png::ColorType::Rgba);
            encoder.set_depth(png::BitDepth::Eight);
            let mut writer = encoder.write_header().ok()?;
            {
                let mut stream = writer.stream_writer().ok()?;
                let row_len = usize::try_from(self.width).ok()?.checked_mul(4)?;
                let mut rgba = vec![0_u8; row_len];
                for output_row in 0..usize::try_from(self.height).ok()? {
                    let source_row = if self.top_down {
                        output_row
                    } else {
                        usize::try_from(self.height)
                            .ok()?
                            .checked_sub(output_row + 1)?
                    };
                    let source_start = source_row.checked_mul(self.stride)?;
                    let source = self
                        .pixels
                        .get(source_start..source_start.checked_add(self.stride)?)?;
                    self.decode_row(source, &mut rgba)?;
                    stream.write_all(&rgba).ok()?;
                }
                stream.finish().ok()?;
            }
            writer.finish().ok()?;
        }
        Some(output.into_inner())
    }

    fn decode_row(&self, source: &[u8], rgba: &mut [u8]) -> Option<()> {
        match self.pixel_format {
            DibPixelFormat::Bgr24 => {
                for (pixel, output) in source
                    .chunks_exact(3)
                    .take(usize::try_from(self.width).ok()?)
                    .zip(rgba.chunks_exact_mut(4))
                {
                    output.copy_from_slice(&[pixel[2], pixel[1], pixel[0], 255]);
                }
            }
            DibPixelFormat::Masked {
                bytes_per_pixel,
                red,
                green,
                blue,
                alpha,
            } => {
                for (pixel, output) in source
                    .chunks_exact(bytes_per_pixel)
                    .take(usize::try_from(self.width).ok()?)
                    .zip(rgba.chunks_exact_mut(4))
                {
                    let value = match bytes_per_pixel {
                        2 => u32::from(u16::from_le_bytes([pixel[0], pixel[1]])),
                        4 => u32::from_le_bytes([pixel[0], pixel[1], pixel[2], pixel[3]]),
                        _ => return None,
                    };
                    output.copy_from_slice(&[
                        red.extract(value),
                        green.extract(value),
                        blue.extract(value),
                        alpha.map_or(255, |mask| mask.extract(value)),
                    ]);
                }
            }
        }
        Some(())
    }
}

fn parse_pixel_format(
    bytes: &[u8],
    header_size: usize,
    bit_count: u16,
    compression: u32,
) -> Option<(DibPixelFormat, usize)> {
    if compression == BI_RGB && bit_count == 24 {
        return Some((DibPixelFormat::Bgr24, 0));
    }

    let bytes_per_pixel = match bit_count {
        16 => 2,
        32 => 4,
        _ => return None,
    };
    let (red_mask, green_mask, blue_mask, alpha_mask, external_mask_bytes) = match compression {
        BI_RGB => {
            let (red, green, blue) = if bit_count == 16 {
                (0x0000_7c00, 0x0000_03e0, 0x0000_001f)
            } else {
                (0x00ff_0000, 0x0000_ff00, 0x0000_00ff)
            };
            let alpha = (header_size >= 56)
                .then(|| read_u32_le(bytes, 52))
                .flatten()
                .filter(|mask| *mask != 0);
            (red, green, blue, alpha, 0)
        }
        BI_BITFIELDS | BI_ALPHABITFIELDS => {
            let (mask_offset, external_mask_bytes) = if header_size == BITMAPINFOHEADER_SIZE {
                let mask_count = if compression == BI_ALPHABITFIELDS {
                    4
                } else {
                    3
                };
                (header_size, mask_count * 4)
            } else {
                if header_size < 52 || (compression == BI_ALPHABITFIELDS && header_size < 56) {
                    return None;
                }
                (40, 0)
            };
            let alpha = if compression == BI_ALPHABITFIELDS || header_size >= 56 {
                read_u32_le(bytes, mask_offset + 12).filter(|mask| *mask != 0)
            } else {
                None
            };
            (
                read_u32_le(bytes, mask_offset)?,
                read_u32_le(bytes, mask_offset + 4)?,
                read_u32_le(bytes, mask_offset + 8)?,
                alpha,
                external_mask_bytes,
            )
        }
        _ => return None,
    };

    let red = ChannelMask::parse(red_mask, bit_count)?;
    let green = ChannelMask::parse(green_mask, bit_count)?;
    let blue = ChannelMask::parse(blue_mask, bit_count)?;
    let alpha = match alpha_mask {
        Some(mask) => Some(ChannelMask::parse(mask, bit_count)?),
        None => None,
    };
    let mut occupied = red.mask | green.mask | blue.mask;
    if red.mask & green.mask != 0 || red.mask & blue.mask != 0 || green.mask & blue.mask != 0 {
        return None;
    }
    if let Some(alpha) = alpha {
        if occupied & alpha.mask != 0 {
            return None;
        }
        occupied |= alpha.mask;
    }
    let _ = occupied;

    Some((
        DibPixelFormat::Masked {
            bytes_per_pixel,
            red,
            green,
            blue,
            alpha,
        },
        external_mask_bytes,
    ))
}

fn validate_dimensions(width: u32, height: u32) -> Option<()> {
    if width == 0 || height == 0 || width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION {
        return None;
    }
    let pixels = usize::try_from(width)
        .ok()?
        .checked_mul(usize::try_from(height).ok()?)?;
    (pixels <= MAX_IMAGE_PIXELS).then_some(())
}

struct LimitedWriter {
    bytes: Vec<u8>,
    limit: usize,
}

impl LimitedWriter {
    fn new(limit: usize) -> Self {
        Self {
            bytes: Vec::new(),
            limit,
        }
    }

    fn into_inner(self) -> Vec<u8> {
        self.bytes
    }
}

impl io::Write for LimitedWriter {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let remaining = self.limit.saturating_sub(self.bytes.len());
        if buf.len() > remaining {
            return Err(io::Error::new(
                io::ErrorKind::FileTooLarge,
                "encoded clipboard image exceeds protocol limit",
            ));
        }
        self.bytes.extend_from_slice(buf);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn read_u16_le(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        bytes.get(offset..offset + 2)?.try_into().ok()?,
    ))
}

fn read_u32_le(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        bytes.get(offset..offset + 4)?.try_into().ok()?,
    ))
}

fn read_i32_le(bytes: &[u8], offset: usize) -> Option<i32> {
    Some(i32::from_le_bytes(
        bytes.get(offset..offset + 4)?.try_into().ok()?,
    ))
}

fn read_u32_be(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_be_bytes(
        bytes.get(offset..offset + 4)?.try_into().ok()?,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode_test_png(width: u32, height: u32, rgba: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        let mut encoder = png::Encoder::new(&mut bytes, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        writer.write_image_data(rgba).unwrap();
        writer.finish().unwrap();
        bytes
    }

    fn decode_rgba(bytes: &[u8]) -> (u32, u32, Vec<u8>) {
        let mut decoder = png::Decoder::new(Cursor::new(bytes));
        decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
        let mut reader = decoder.read_info().unwrap();
        let mut output = vec![0_u8; reader.output_buffer_size()];
        let info = reader.next_frame(&mut output).unwrap();
        output.truncate(info.buffer_size());
        (info.width, info.height, output)
    }

    fn info_header(width: i32, height: i32, bit_count: u16, compression: u32) -> Vec<u8> {
        let mut header = vec![0_u8; BITMAPINFOHEADER_SIZE];
        header[0..4].copy_from_slice(&(BITMAPINFOHEADER_SIZE as u32).to_le_bytes());
        header[4..8].copy_from_slice(&width.to_le_bytes());
        header[8..12].copy_from_slice(&height.to_le_bytes());
        header[12..14].copy_from_slice(&1_u16.to_le_bytes());
        header[14..16].copy_from_slice(&bit_count.to_le_bytes());
        header[16..20].copy_from_slice(&compression.to_le_bytes());
        header
    }

    #[test]
    fn windows_registered_png_is_validated_and_allocator_tail_is_removed() {
        let png = encode_test_png(1, 1, &[1, 2, 3, 255]);
        let mut clipboard = png.clone();
        clipboard.extend_from_slice(&[0; 32]);

        assert_eq!(validated_png(&clipboard), Some(png));
    }

    #[test]
    fn windows_registered_png_rejects_corrupt_crc() {
        let mut png = encode_test_png(1, 1, &[1, 2, 3, 255]);
        let ihdr_crc = 8 + 4 + 4 + 13;
        png[ihdr_crc] ^= 0xff;

        assert_eq!(validated_png(&png), None);
    }

    #[test]
    fn windows_dib24_converts_bottom_up_rows_and_padding() {
        let mut dib = info_header(2, 2, 24, BI_RGB);
        dib[20..24].copy_from_slice(&16_u32.to_le_bytes());
        dib.extend_from_slice(&[
            255, 0, 0, 255, 255, 255, 0, 0, // blue, white, padding
            0, 0, 255, 0, 255, 0, 0, 0, // red, green, padding
        ]);

        let png = dib_to_png(&dib).unwrap();
        assert_eq!(
            decode_rgba(&png),
            (
                2,
                2,
                vec![255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255,],
            )
        );
    }

    #[test]
    fn windows_dib32_top_down_ignores_unused_high_byte() {
        let mut dib = info_header(2, -1, 32, BI_RGB);
        dib[20..24].copy_from_slice(&8_u32.to_le_bytes());
        dib.extend_from_slice(&[30, 20, 10, 0, 60, 50, 40, 7]);

        let png = dib_to_png(&dib).unwrap();
        assert_eq!(
            decode_rgba(&png),
            (2, 1, vec![10, 20, 30, 255, 40, 50, 60, 255])
        );
    }

    #[test]
    fn windows_dibv5_preserves_explicit_alpha_mask() {
        let mut dib = vec![0_u8; 124];
        dib[0..4].copy_from_slice(&124_u32.to_le_bytes());
        dib[4..8].copy_from_slice(&1_i32.to_le_bytes());
        dib[8..12].copy_from_slice(&(-1_i32).to_le_bytes());
        dib[12..14].copy_from_slice(&1_u16.to_le_bytes());
        dib[14..16].copy_from_slice(&32_u16.to_le_bytes());
        dib[16..20].copy_from_slice(&BI_BITFIELDS.to_le_bytes());
        dib[20..24].copy_from_slice(&4_u32.to_le_bytes());
        dib[40..44].copy_from_slice(&0x00ff_0000_u32.to_le_bytes());
        dib[44..48].copy_from_slice(&0x0000_ff00_u32.to_le_bytes());
        dib[48..52].copy_from_slice(&0x0000_00ff_u32.to_le_bytes());
        dib[52..56].copy_from_slice(&0xff00_0000_u32.to_le_bytes());
        dib.extend_from_slice(&[30, 20, 10, 128]);

        let png = dib_to_png(&dib).unwrap();
        assert_eq!(decode_rgba(&png), (1, 1, vec![10, 20, 30, 128]));
    }

    #[test]
    fn windows_dib_rejects_truncated_and_unbounded_images() {
        let truncated = info_header(2, 2, 24, BI_RGB);
        assert_eq!(dib_to_png(&truncated), None);

        let huge = info_header(20_000, 20_000, 32, BI_RGB);
        assert_eq!(dib_to_png(&huge), None);
    }

    #[test]
    fn windows_limited_png_writer_rejects_overflow() {
        let mut writer = LimitedWriter::new(4);
        writer.write_all(b"four").unwrap();

        assert_eq!(
            writer.write_all(b"!").unwrap_err().kind(),
            io::ErrorKind::FileTooLarge
        );
    }
}
