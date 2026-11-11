//! Marriage support for the built-in Tama App: character parts, pictures,
//! character data and the app packets, as the official app (and the MyMeets
//! community tool, whose behaviour this follows) produced them.
//!
//! Character parts come from the MyMeets character pack the user downloads
//! (files `NNcIIII_Type_P[_en].txt`), never from this source.

use std::collections::HashMap;

// ---- packets --------------------------------------------------------------------

pub const OP_VISIT: u8 = 0x14;
pub const OP_BACK: u8 = 0x15;
pub const OP_MARRIAGE: u8 = 0x16;
pub const OP_ITEM: u8 = 0x17;
pub const CMD_START: u8 = 0;
pub const CMD_VISIT: u8 = 0x34;
pub const CMD_BACK: u8 = 0x36;
pub const CMD_MARRIAGE: u8 = 0x38;

const CODE_TAMAGO: &[u8; 6] = b"TAMAGO";
const CODE_SECURITY: [u8; 8] = [0x7c, 0x68, 0x48, 0x97, 0x75, 0xa6, 0x4e, 0x99];
const CODE_FORMAT: [u8; 8] = [0, 0, 0, 0, 0x10, 0, 0x01, 0x04];
pub const MARRIAGE_PACKET_SIZE: usize = 39334;

struct W<'a> {
    b: &'a mut Vec<u8>,
    p: usize,
}
impl<'a> W<'a> {
    fn bytes(&mut self, d: &[u8]) {
        let end = (self.p + d.len()).min(self.b.len());
        let n = end - self.p.min(end);
        self.b[self.p..self.p + n].copy_from_slice(&d[..n]);
        self.p += d.len();
    }
    fn zeros(&mut self, n: usize) {
        self.p += n;
    }
    fn u8(&mut self, v: u8) {
        self.bytes(&[v])
    }
    fn u16(&mut self, v: u16) {
        self.bytes(&v.to_le_bytes())
    }
    fn u32(&mut self, v: u32) {
        self.bytes(&v.to_le_bytes())
    }
}

/// The partner as the marriage packet describes it.
pub struct Partner {
    pub sex: u8,
    pub id: u16,
    pub name: Vec<u8>,
    pub generation: u16,
    pub growth: u8,
    pub twins: u8,
    pub birthday: u16,
    pub dna: u8,
    pub dna_pattern: [u8; 8],
    pub palette: [u8; 3],
    pub character_info: Vec<u8>,
    pub parent_images: Vec<u8>,
}

pub struct Marriage {
    pub partner: Partner,
    pub character_data: Vec<u8>,
    pub colors: [u8; 3],
    pub dna_pattern: [u8; 8],
    pub dna_value: u8,
    pub sex: u8,
}

/// Build a packet (BLETmgcPacket.Compile in MyMeets).
pub fn packet(op: u8, cmd: u8, size: usize, gotchi_points: u32, item: Option<&[u8]>, marriage: Option<&Marriage>) -> Vec<u8> {
    let size = size.max(258);
    let mut raw = vec![0u8; size];
    {
        let mut w = W { b: &mut raw, p: 0 };
        w.bytes(CODE_TAMAGO);
        match marriage {
            Some(m) => {
                w.zeros(60);
                w.bytes(&m.colors);
                w.zeros(3);
            }
            None => w.zeros(66),
        }
        w.u32(size as u32);
        w.u8(op);
        w.u8(0);
        w.u32(0);
        w.bytes(&CODE_SECURITY);
        w.u32(0);
        w.u8(cmd);
        match marriage {
            Some(m) => {
                let v = &m.partner;
                w.u8(v.sex);
                let mut name = [0u8; 16];
                let n = v.name.len().min(16);
                name[..n].copy_from_slice(&v.name[..n]);
                w.bytes(&name);
                w.u16(0);
                w.u16(0); // RandomID1
                w.u16(v.id);
                w.zeros(3);
                w.u8(0);
                w.u16(v.generation);
                w.u8(v.growth);
                w.zeros(6);
                w.u8(v.twins);
                w.u16(0); // Unknown1
                w.u16(0); // Unknown2
                w.u8(0); // BKind
                w.u8(0); // PKind
                w.u16(v.birthday);
                w.u16(0);
                w.u16(0); // RandomID2
                w.zeros(8);
                w.bytes(&v.dna_pattern);
                w.u8(m.dna_value);
                w.u8(m.sex);
                w.bytes(&v.palette);
                w.bytes(&m.dna_pattern);
                w.u8(m.dna_value);
                w.zeros(13);
            }
            None => w.zeros(92),
        }
        if gotchi_points > 0 {
            w.u8(3);
            w.u32(gotchi_points);
        } else {
            w.zeros(5);
        }
        if marriage.is_some() {
            w.zeros(12);
            w.u32(256);
            w.u32(33036);
        } else {
            w.zeros(20);
        }
        if item.is_some() {
            w.u32(256);
            w.zeros(20);
        } else {
            w.zeros(24);
        }
        if marriage.is_some() {
            w.u32(33176);
            w.zeros(8);
        } else {
            w.zeros(12);
        }
        w.bytes(&CODE_FORMAT);
        if let Some(it) = item {
            w.u32(2);
            w.u32(1);
            w.u32(it.len() as u32);
            w.bytes(it);
            w.u32(0);
        } else if let Some(m) = marriage {
            w.u32(0);
            w.u32(1);
            w.u32(32768);
            let mut cd = m.character_data.clone();
            cd.resize(32768, 0);
            w.bytes(&cd);
            w.bytes(&m.partner.character_info);
            w.bytes(&m.partner.parent_images);
        }
    }
    let n = raw.len();
    let sum = raw[..n - 2].iter().fold(0u16, |a, &b| a.wrapping_add(b as u16));
    // MyMeets sums the whole buffer before the checksum is written (it is still 0)
    raw[n - 2..].copy_from_slice(&sum.to_le_bytes());
    raw
}

// ---- strings --------------------------------------------------------------------

const MOJIS: [&str; 16] = [
    "\u{3000}あいうえおかきくけこさしすせそ", "たちつてとなにぬねのはひふへほま", "みむめもやゆよらりるれろわをんぁ",
    "ぃぅぇぉっゃゅょがぎぐげござじず", "ぜぞだぢづでどばびぶべぼぱぴぷぺ", "ぽー～…、。()「」.・!?&○",
    "×┣◎★┳♪┫↑↓→←￥\u{3000}012", "3456789アイウエオカキクケ", "コサシスセソタチツテトナニヌネノ",
    "ハヒフヘホマミムメモヤユヨラリル", "レロワヲンァィゥェォッャュョガギ", "グゲゴザジズゼゾダヂヅデドバビブ",
    "ベボパピプペポヴ        ", "│┌┐┘└├┬┤┴┼━┃┏┓┛┗", "ABCDEFGHIJKLMNOP", "QRSTUVWXYZ%-+  \n",
];

/// Encode a name the way the toy stores text (language byte + table index).
pub fn encode_name(s: &str, lang: u8) -> Vec<u8> {
    let mut out = Vec::new();
    for c in s.to_uppercase().chars() {
        for (row, chars) in MOJIS.iter().enumerate() {
            if let Some(col) = chars.chars().position(|x| x == c) {
                out.push(lang);
                out.push(((row as u8) << 4) | (col as u8 & 15));
                break;
            }
        }
    }
    out
}

pub fn decode_name(b: &[u8]) -> String {
    let mut s = String::new();
    for p in b.chunks(2) {
        if p.len() < 2 || (p[0] != 4 && p[0] != 8) {
            break;
        }
        if let Some(c) = MOJIS[(p[1] >> 4) as usize].chars().nth((p[1] & 15) as usize) {
            s.push(c);
        }
    }
    s.trim().to_string()
}

// ---- DNA ----------------------------------------------------------------------

const DNA_PATTERNS: [[[u8; 8]; 4]; 4] = [
    [[0, 1, 10, 11, 8, 9, 2, 3], [8, 9, 2, 3, 0, 1, 10, 11], [0, 9, 10, 3, 8, 1, 2, 11], [8, 1, 2, 11, 0, 9, 10, 3]],
    [[0, 1, 10, 11, 12, 9, 6, 3], [8, 9, 2, 3, 4, 1, 14, 11], [0, 9, 10, 3, 12, 1, 6, 11], [8, 1, 2, 11, 4, 9, 14, 3]],
    [[0, 1, 10, 11, 12, 1, 2, 11], [8, 1, 2, 11, 4, 9, 10, 3], [0, 1, 10, 11, 8, 9, 6, 3], [8, 9, 2, 3, 4, 1, 14, 11]],
    [[0, 9, 10, 3, 8, 1, 6, 11], [8, 1, 2, 11, 0, 9, 14, 3], [0, 1, 10, 11, 8, 9, 6, 3], [8, 9, 2, 3, 0, 1, 14, 11]],
];
const DNA_PATTERN_E: [[u8; 8]; 13] = [
    [0, 9, 10, 11, 12, 13, 14, 15], [8, 1, 10, 11, 12, 13, 14, 15], [0, 1, 10, 11, 12, 13, 14, 15],
    [8, 9, 10, 3, 12, 13, 14, 15], [0, 1, 10, 11, 12, 13, 14, 15], [0, 9, 2, 11, 12, 13, 14, 15],
    [0, 9, 10, 3, 12, 13, 14, 15], [8, 9, 2, 11, 12, 13, 14, 15], [8, 9, 2, 3, 12, 13, 14, 15],
    [0, 1, 2, 11, 12, 13, 14, 15], [0, 1, 10, 3, 12, 13, 14, 15], [0, 9, 2, 3, 12, 13, 14, 15], [8, 1, 2, 3, 12, 13, 14, 15],
];

pub struct Rng(u64);
impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed ^ 0x9E37_79B9_7F4A_7C15 | 1)
    }
    pub fn next(&mut self, lo: i32, hi: i32) -> i32 {
        // xorshift64*; [lo, hi) like .NET Random.Next
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        let v = self.0.wrapping_mul(0x2545_F491_4F6C_DD1D);
        if hi <= lo {
            return lo;
        }
        lo + (v % (hi - lo) as u64) as i32
    }
}

/// DNA pattern for the chosen marriage type: 0 = like the device/app,
/// 1 = "get character" (the baby becomes the partner), 2 = random genes.
pub fn dna_from_type(kind: u8, generation_hint: u8, rng: &mut Rng) -> (u8, [u8; 8]) {
    let mut p = [0u8; 8];
    match kind {
        0 => {
            p = [8; 8];
            (255, p)
        }
        1 => {
            let v = if generation_hint > 1 && generation_hint - 1 <= 3 { generation_hint - 1 } else { 255 };
            if v != 255 {
                return (v, DNA_PATTERN_E[v as usize]);
            }
            let r = rng.next(0, 100);
            let g = if r < 25 { 0 } else if r < 50 { 1 } else if r < 75 { 2 } else { 3 };
            let k = if r % 10 > 3 { (r % 10 % 3 + 1) as usize } else { 0 };
            p.copy_from_slice(&DNA_PATTERNS[g][k]);
            (g as u8, p)
        }
        _ => {
            for b in p.iter_mut() {
                *b = rng.next(0, 12) as u8;
            }
            (255, p)
        }
    }
}

// ---- pictures -----------------------------------------------------------------------

#[derive(Clone)]
pub struct Image {
    pub w: usize,
    pub h: usize,
    /// 0xAARRGGBB
    pub px: Vec<u32>,
}

impl Image {
    pub fn new(w: usize, h: usize) -> Image {
        Image { w, h, px: vec![0; w * h] }
    }
    pub fn get(&self, x: usize, y: usize) -> u32 {
        self.px[y * self.w + x]
    }
    pub fn set(&mut self, x: usize, y: usize, c: u32) {
        if x < self.w && y < self.h {
            self.px[y * self.w + x] = c;
        }
    }
}

fn rgb565_to_argb(v: u16) -> u32 {
    // stored with blue in the high bits (as the toy's images are)
    let b = ((v & 0xF800) >> 11) as u32 * 255 / 31;
    let g = ((v & 0x07E0) >> 5) as u32 * 255 / 63;
    let r = (v & 0x1F) as u32 * 255 / 31;
    0xFF00_0000 | r << 16 | g << 8 | b
}

fn argb_to_565(c: u32) -> u16 {
    let r = ((c >> 16) & 0xFF) as u16;
    let g = ((c >> 8) & 0xFF) as u16;
    let b = (c & 0xFF) as u16;
    ((b >> 3) & 31) << 11 | ((g >> 2) & 63) << 5 | ((r >> 3) & 31)
}

/// Size of one picture from its header (0 if it isn't one).
pub fn image_size(h: &[u8]) -> usize {
    if h.len() < 6 {
        return 0;
    }
    let v = u16::from_le_bytes([h[3], h[4]]);
    if v != 1 && v != 256 {
        return 0;
    }
    let (w, ht, n) = (h[0] as usize, h[1] as usize, h[2] as usize);
    let mut px = w * ht;
    if n <= 16 {
        px /= 2;
    }
    6 + px + n * 2
}

/// Decode a toy picture; pixel (0,0)'s colour becomes transparent.
pub fn decode_image(b: &[u8], key_transparent: bool) -> Option<Image> {
    let size = image_size(b);
    if size == 0 || size > b.len() {
        return None;
    }
    let (w, h, n) = (b[0] as usize, b[1] as usize, b[2] as usize);
    let pal: Vec<u32> = (0..n).map(|i| rgb565_to_argb(u16::from_be_bytes([b[6 + i * 2], b[7 + i * 2]]))).collect();
    let mut img = Image::new(w, h);
    let start = 6 + n * 2;
    if n <= 16 {
        for i in 0..w * h / 2 {
            let v = b[start + i];
            let (lo, hi) = ((v & 15) as usize, (v >> 4) as usize);
            let (p0, p1) = (i * 2, i * 2 + 1);
            img.px[p0] = *pal.get(lo).unwrap_or(&0);
            if p1 < w * h {
                img.px[p1] = *pal.get(hi).unwrap_or(&0);
            }
        }
    } else {
        for i in 0..w * h {
            img.px[i] = *pal.get(b[start + i] as usize).unwrap_or(&0);
        }
    }
    if key_transparent && !img.px.is_empty() {
        let k = img.px[0];
        for p in img.px.iter_mut() {
            if *p == k {
                *p = 0;
            }
        }
    }
    Some(img)
}

/// Encode a picture in the toy's format (TamagoImage.FromBitmap).
pub fn encode_image(img: &Image) -> Vec<u8> {
    let mut pal: Vec<u32> = Vec::new();
    for x in 0..img.w {
        for y in 0..img.h {
            let c = img.get(x, y);
            if !pal.contains(&c) {
                pal.push(c);
            }
        }
    }
    let n = pal.len().min(255);
    let mut size = img.w * img.h;
    if n <= 16 {
        size /= 2;
    }
    let mut total = 6 + size + n * 2;
    total += total % 4;
    let mut out = vec![0u8; total];
    out[0] = img.w as u8;
    out[1] = img.h as u8;
    out[2] = n as u8;
    let v: u16 = if n <= 16 { 1 } else { 256 };
    out[3..5].copy_from_slice(&v.to_le_bytes());
    out[5] = 0xFF;
    for (i, c) in pal.iter().take(n).enumerate() {
        let v = argb_to_565(*c);
        out[6 + i * 2..8 + i * 2].copy_from_slice(&v.to_be_bytes());
    }
    let start = 6 + n * 2;
    let idx = |c: u32| pal.iter().position(|&p| p == c).unwrap_or(0).min(255) as u8;
    if n <= 16 {
        let mut i = 0;
        while i + 1 < img.w * img.h + 1 && i < img.w * img.h {
            let a = idx(img.px[i]) & 15;
            let b = if i + 1 < img.px.len() { idx(img.px[i + 1]) & 15 } else { 0 };
            out[start + i / 2] = a | b << 4;
            i += 2;
        }
    } else {
        for (i, &c) in img.px.iter().enumerate() {
            out[start + i] = idx(c);
        }
    }
    out
}

// ---- colour palettes (13 x 8, palette 0 = the parts' own colours) ---------------------

const PALETTES: [[[u8; 3]; 8]; 13] = [
    [[255, 255, 209], [255, 255, 109], [255, 224, 0], [255, 255, 99], [255, 219, 0], [255, 191, 0], [244, 234, 76], [214, 204, 0]],
    [[255, 142, 153], [255, 119, 130], [242, 58, 73], [255, 89, 102], [229, 0, 17], [183, 0, 15], [135, 0, 0], [104, 0, 0]],
    [[155, 204, 255], [107, 165, 232], [73, 130, 193], [73, 96, 255], [63, 84, 224], [25, 45, 186], [0, 20, 160], [0, 17, 132]],
    [[198, 198, 198], [160, 160, 160], [132, 132, 132], [119, 119, 119], [102, 102, 102], [79, 79, 79], [73, 56, 56], [33, 33, 33]],
    [[255, 255, 255], [255, 255, 255], [244, 242, 242], [255, 255, 255], [242, 239, 239], [219, 216, 216], [211, 209, 209], [219, 214, 191]],
    [[255, 255, 255], [255, 219, 239], [244, 186, 209], [249, 193, 219], [255, 170, 204], [239, 124, 175], [255, 130, 165], [224, 84, 119]],
    [[255, 234, 127], [255, 186, 0], [255, 135, 0], [255, 193, 0], [255, 145, 0], [229, 112, 0], [158, 91, 0], [127, 73, 0]],
    [[255, 255, 237], [255, 249, 198], [242, 234, 135], [255, 255, 229], [255, 249, 186], [221, 211, 89], [252, 247, 201], [249, 242, 114]],
    [[175, 244, 68], [140, 209, 35], [99, 170, 0], [122, 170, 79], [102, 142, 68], [40, 112, 25], [84, 142, 0], [66, 114, 0]],
    [[242, 249, 255], [206, 234, 249], [153, 198, 226], [214, 244, 255], [130, 209, 255], [94, 175, 214], [107, 158, 211], [61, 114, 173]],
    [[255, 234, 255], [229, 191, 214], [198, 145, 186], [229, 165, 214], [191, 104, 165], [147, 68, 124], [209, 68, 170], [191, 51, 140]],
    [[255, 255, 249], [224, 224, 224], [175, 170, 173], [255, 255, 255], [211, 211, 211], [188, 188, 188], [237, 237, 237], [214, 214, 214]],
    [[239, 239, 219], [216, 216, 196], [170, 170, 150], [142, 142, 124], [117, 117, 96], [73, 73, 53], [53, 53, 33], [30, 30, 10]],
];
pub const PALETTE_COUNT: usize = 13;

fn argb(c: [u8; 3]) -> u32 {
    0xFF00_0000 | (c[0] as u32) << 16 | (c[1] as u32) << 8 | c[2] as u32
}

fn recolor(c: u32, pal: usize) -> u32 {
    if c >> 24 == 0 || pal == 0 || pal >= PALETTE_COUNT { return c; }
    let rgb = [((c >> 16) & 255) as f64, ((c >> 8) & 255) as f64, (c & 255) as f64];
    if rgb.iter().copied().fold(0.0_f64, f64::max) < 48.0 { return c; }
    let mut best = (f64::MAX, 0usize);
    for source in PALETTES.iter() {
        for (i, base) in source.iter().enumerate() {
            let q = rgb565_to_argb(argb_to_565(argb(*base)));
            let d = [((q >> 16) & 255) as f64, ((q >> 8) & 255) as f64, (q & 255) as f64];
            let error = 0.3 * (rgb[0] - d[0]).powi(2)
                + 0.59 * (rgb[1] - d[1]).powi(2) + 0.11 * (rgb[2] - d[2]).powi(2);
            if error < best.0 { best = (error, i); }
        }
    }
    if best.0 <= 225.0 { argb(PALETTES[pal][best.1]) } else { c }
}

/// A palette's colours (for the app's colour buttons).
pub fn palette_swatch(pal: usize) -> [u32; 8] {
    let mut out = [0u32; 8];
    for (i, c) in PALETTES[pal.min(PALETTE_COUNT - 1)].iter().enumerate() {
        out[i] = argb(*c);
    }
    out
}

// ---- character parts ----------------------------------------------------------------

pub const PARTS: [char; 4] = ['B', 'M', 'A', 'K'];

fn part_index(p: char) -> usize {
    PARTS.iter().position(|&c| c == p).unwrap_or(0)
}

#[derive(Default)]
pub struct Part {
    pub offset: Vec<u8>,
    pub tbl_jp: Vec<u8>,
    pub tbl_en: Vec<u8>,
    pub chr: Vec<u8>,
    pub images: Vec<Option<Image>>,
    pub accessory_front: bool,
}

#[derive(Default)]
pub struct Library {
    /// File name (lower case, no folder) -> data.
    files: HashMap<String, Vec<u8>>,
    pub ids: Vec<u16>,
    /// Shop items from the pack (assets/items/<lang>/...).
    pub items: Vec<ShopItem>,
    parts: HashMap<(u16, char), Part>,
}

const IMAGE_COUNT: [usize; 4] = [14, 19, 11, 7]; // B M A K
const NORMAL_INDEX: usize = 0;
const SMALL_INDEX: [usize; 4] = [9, 15, 7, 6]; // B M A K

impl Library {
    pub fn add_file(&mut self, name: &str, data: Vec<u8>) {
        let base = name.rsplit(['/', '\\']).next().unwrap_or(name).to_ascii_lowercase();
        if !base.ends_with(".txt") || base.len() < 9 || &base[2..3] != "c" {
            return;
        }
        if let Ok(id) = base[3..7].parse::<u16>() {
            if !self.ids.contains(&id) {
                self.ids.push(id);
            }
            self.files.insert(base, data);
        }
    }

    pub fn finish(&mut self) {
        self.ids.sort_unstable();
        let ids = self.ids.clone();
        for id in ids {
            for p in PARTS {
                let part = self.load_part(id, p);
                self.parts.insert((id, p), part);
            }
        }
        // only characters with all four parts and a body picture are usable
        let parts = &self.parts;
        self.ids.retain(|&id| PARTS.iter().all(|&p| parts.get(&(id, p)).map_or(false, |x| !x.offset.is_empty() && !x.chr.is_empty())));
    }

    fn file(&self, num: usize, id: u16, kind: &str, p: char, suffix: &str) -> Option<Vec<u8>> {
        let n = format!("{:02}c{:04}_{}_{}{}.txt", num, id, kind, p, suffix).to_ascii_lowercase();
        self.files.get(&n).cloned()
    }

    fn load_part(&self, id: u16, p: char) -> Part {
        let i = part_index(p);
        let mut part = Part::default();
        part.offset = self.file(1 + i, id, "offset", p, "").unwrap_or_default();
        part.tbl_jp = self.file(5 + i, id, "tbl", p, "").unwrap_or_default();
        part.tbl_en = if p == 'B' { self.file(5 + i, id, "tbl", p, "_en").unwrap_or_default() } else { Vec::new() };
        part.chr = self.file(9 + i, id, "char", p, "").unwrap_or_default();
        if p == 'K' && part.tbl_jp.len() > 6 && part.tbl_jp[6] != 0 {
            part.accessory_front = true;
        }
        // the Offset file lists each picture's place in the 32 KB character
        // data; the part's Char data starts at CHAR_BASE there
        const CHAR_BASE: [usize; 4] = [0x400, 0x3850, 0x5300, 0x7200];
        for e in part.offset.chunks_exact(4) {
            let abs = u32::from_le_bytes([e[0], e[1], e[2], e[3]]) as usize;
            let img = abs.checked_sub(CHAR_BASE[i]).and_then(|rel| {
                let s = image_size(part.chr.get(rel..)?);
                if s == 0 || rel + s > part.chr.len() {
                    return None;
                }
                decode_image(&part.chr[rel..rel + s], true)
            });
            part.images.push(img);
        }
        part
    }

    pub fn part(&self, id: u16, p: char) -> Option<&Part> {
        self.parts.get(&(id, p))
    }

    fn part_image(&self, id: u16, p: char, index: usize) -> Option<&Image> {
        let part = self.part(id, p)?;
        if part.images.len() != IMAGE_COUNT[part_index(p)] {
            return None;
        }
        part.images.get(index)?.as_ref()
    }

    /// Picture of a character from parts: picks[B M A K] = (character id, palette).
    pub fn compose(&self, picks: &[(u16, usize); 4], small: bool) -> Option<Image> {
        let (w, h, ox, oy) = if small { (48, 40, 8, 4) } else { (64, 64, 8, 6) };
        let idx = |p: usize| if small { SMALL_INDEX[p] } else { NORMAL_INDEX };
        let mut layers: [Option<Image>; 4] = Default::default();
        for p in 0..4 {
            let img = self.part_image(picks[p].0, PARTS[p], idx(p)).cloned();
            if img.is_none() && PARTS[p] != 'K' {
                return None;
            }
            layers[p] = img;
        }
        // anchors: the body picture marks where the head (red), face
        // (yellow) and back (blue) go; its first 4 pixels give the colours
        // that replace the marks.
        let mut anchors: HashMap<char, (i32, i32)> = HashMap::new();
        if let Some(body) = layers[0].as_mut() {
            if body.w >= 4 {
                let row: Vec<u32> = (0..4).map(|x| body.get(x, 0)).collect();
                for x in 0..4 {
                    body.set(x, 0, row[0]);
                }
                for y in 0..body.h {
                    for x in 0..body.w {
                        let c = body.get(x, y) | 0xFF00_0000;
                        let (key, repl) = match c {
                            0xFFFF_0000 => ('A', row[1]),
                            0xFFFF_FF00 => ('M', row[2]),
                            0xFF00_00FF => ('K', row[3]),
                            _ => continue,
                        };
                        if body.get(x, y) >> 24 == 0 {
                            continue;
                        }
                        anchors.insert(key, (x as i32, y as i32));
                        body.set(x, y, repl);
                    }
                }
            }
        }
        let front = self.part(picks[3].0, 'K').map_or(false, |k| k.accessory_front);
        let order: [char; 4] = if front { ['B', 'A', 'M', 'K'] } else { ['K', 'B', 'A', 'M'] };
        let mut out = Image::new(w, h);
        for p in order {
            let i = part_index(p);
            let Some(img) = layers[i].as_ref() else { continue };
            let (mut x0, mut y0) = (ox as i32, oy as i32);
            if p != 'B' {
                let (ax, ay) = anchors.get(&p).copied().unwrap_or((img.w as i32 / 2, img.h as i32 / 2));
                x0 += ax - img.w as i32 / 2;
                y0 += ay - img.h as i32 / 2;
            }
            for y in 0..img.h {
                for x in 0..img.w {
                    let c = img.get(x, y);
                    if c >> 24 == 0 {
                        continue;
                    }
                    let (tx, ty) = (x0 + x as i32, y0 + y as i32);
                    if tx >= 0 && ty >= 0 {
                        out.set(tx as usize, ty as usize, recolor(c, picks[i].1));
                    }
                }
            }
        }
        Some(out)
    }

    /// One part on its own, centred on a 64x64 picture (for showing the separate genes).
    /// part: 0 = Body, 1 = Face, 2 = Head, 3 = Back.
    pub fn layer(&self, part: usize, id: u16, pal: usize) -> Option<Image> {
        let p = *PARTS.get(part)?;
        let mut img = self.part_image(id, p, NORMAL_INDEX).cloned()?;
        if p == 'B' && img.w >= 4 {
            let row: Vec<u32> = (0..4).map(|x| img.get(x, 0)).collect();
            for x in 0..4 {
                img.set(x, 0, row[0]);
            }
            for y in 0..img.h {
                for x in 0..img.w {
                    let c = img.get(x, y);
                    if c >> 24 == 0 {
                        continue;
                    }
                    let repl = match c | 0xFF00_0000 {
                        0xFFFF_0000 => row[1],
                        0xFFFF_FF00 => row[2],
                        0xFF00_00FF => row[3],
                        _ => continue,
                    };
                    img.set(x, y, repl);
                }
            }
        }
        let mut out = Image::new(64, 64);
        let (x0, y0) = ((64 - img.w.min(64)) / 2, (64 - img.h.min(64)) / 2);
        for y in 0..img.h.min(64) {
            for x in 0..img.w.min(64) {
                let c = img.get(x, y);
                if c >> 24 != 0 {
                    out.set(x0 + x, y0 + y, recolor(c, pal));
                }
            }
        }
        Some(out)
    }

    /// How usable a character's body is: (opaque pixels, which anchors it has: 1 = head, 2 = face, 4 = back).
    /// Some characters are really accessories (a bow, a hat): they have almost no body and no anchors.
    pub fn body_info(&self, id: u16) -> Option<(usize, u32)> {
        let img = self.part_image(id, 'B', NORMAL_INDEX)?;
        let mut n = 0;
        let mut mask = 0;
        for y in 0..img.h {
            for x in 0..img.w {
                let c = img.get(x, y);
                if c >> 24 == 0 {
                    continue;
                }
                n += 1;
                match c | 0xFF00_0000 {
                    0xFFFF_0000 => mask |= 1,
                    0xFFFF_FF00 => mask |= 2,
                    0xFF00_00FF => mask |= 4,
                    _ => {}
                }
            }
        }
        Some((n, mask))
    }

    /// The shop's wallpapers (English list): number of them.
    pub fn wallpaper_count(&self) -> usize {
        self.items.iter().filter(|it| it.lang == "en" && it.kind == "wallpaper").count()
    }

    /// The nth wallpaper's picture, as the toy draws it.
    pub fn wallpaper(&self, n: usize) -> Option<Image> {
        let it = self.items.iter().filter(|it| it.lang == "en" && it.kind == "wallpaper").nth(n)?;
        if it.data.len() <= 0x210 {
            return None;
        }
        decode_image(&it.data[0x204..], false)
    }

    /// The 32 KB character data the toy draws the partner with.
    pub fn character_data(&self, sex: u8, ids: [u16; 4], lang: u8) -> Option<Vec<u8>> {
        const TABLE: [u8; 16] = [0x00, 0x01, 0x00, 0x00, 0xe4, 0x01, 0x00, 0x00, 0xe8, 0x01, 0x00, 0x00, 0xf4, 0x01, 0x00, 0x00];
        const OFFS: [[usize; 3]; 4] = [[0x10, 0x100, 0x400], [0x48, 0x1e4, 0x3850], [0x94, 0x1e8, 0x5300], [0xc0, 0x1f4, 0x7200]];
        let mut data = vec![0u8; 32768];
        data[..16].copy_from_slice(&TABLE);
        for (i, &p) in PARTS.iter().enumerate() {
            let part = self.part(ids[i], p)?;
            let tbl = if p == 'B' && lang == 8 && !part.tbl_en.is_empty() { &part.tbl_en } else { &part.tbl_jp };
            if part.offset.is_empty() || part.chr.is_empty() || tbl.is_empty() {
                return None;
            }
            for (j, src) in [&part.offset, tbl, &part.chr].iter().enumerate() {
                let o = OFFS[i][j];
                let n = src.len().min(32768 - o);
                data[o..o + n].copy_from_slice(&src[..n]);
                if i == 0 && j == 1 {
                    data[o + 6] = sex;
                }
            }
        }
        Some(data)
    }

    pub fn random_id(&self, p: char, rng: &mut Rng) -> u16 {
        if self.ids.is_empty() {
            return 16;
        }
        for _ in 0..20 {
            let id = self.ids[rng.next(0, self.ids.len() as i32) as usize];
            let ok = self.part(id, p).map_or(false, |x| !x.images.is_empty())
                && (p != 'B' || self.body_info(id).map_or(false, |(n, m)| n >= 200 && m == 7));
            if ok {
                return id;
            }
        }
        16
    }

    /// A grandparent-ish picture: some parts from the partner, some random.
    pub fn fake_parent(&self, picks: &[(u16, usize); 4], keep: [i32; 4], rng: &mut Rng) -> Option<Image> {
        let mut p = *picks;
        for i in 0..4 {
            let rid = self.random_id(PARTS[i], rng);
            let rpal = rng.next(0, PALETTE_COUNT as i32 - 1) as usize;
            p[i] = if rng.next(30, 100) > keep[i] { picks[i] } else { (rid, if PARTS[i] == 'M' { 0 } else { rpal }) };
        }
        self.compose(&p, true)
    }
}

// ---- the whole marriage ---------------------------------------------------------------

/// Visit data from the toy (what it sends on a visit): is it an adult?
pub fn visit_is_adult(v: &[u8]) -> bool {
    if v.len() < 1536 {
        return false;
    }
    let rd32 = |o: usize| u32::from_le_bytes([v[o], v[o + 1], v[o + 2], v[o + 3]]) as usize;
    let rd16 = |o: usize| if o + 2 <= v.len() { u16::from_le_bytes([v[o], v[o + 1]]) } else { 0 };
    let stage = rd16(rd32(208) + 14);
    stage >= 2
}

pub fn visit_sex(v: &[u8]) -> u8 {
    v.get(95).copied().unwrap_or(0)
}

/// The Tamagotchi's own name in visit data (the first text field after the
/// owner's profile name at 0x60; e.g. 0x18C on Wonder Garden).
pub fn visit_tama_name(v: &[u8]) -> String {
    let Some(raw) = v.get(208..212) else { return String::new() };
    let info = u32::from_le_bytes([raw[0], raw[1], raw[2], raw[3]]) as usize;
    if info < 256 { return String::new(); }
    for relative in [84usize, 104] {
        let Some(start) = info.checked_add(relative) else { continue };
        let Some(end) = start.checked_add(18) else { continue };
        let Some(field) = v.get(start..end) else { continue };
        let name = decode_name(field);
        if !name.is_empty() { return name; }
    }
    String::new()
}

pub fn visit_name(v: &[u8]) -> String {
    if v.len() < 0x70 {
        return String::new();
    }
    decode_name(&v[0x60..0x70])
}

pub struct Choice {
    pub picks: [(u16, usize); 4], // B M A K
    pub baby_sex: u8,             // 0 boy, 1 girl (as MyMeets offers)
    pub lang: u8,                 // 4 JP, 8 EN
    pub kind: u8,                 // 0 like the app, 1 get character, 2 random genes
    pub name: String,
}

pub fn marriage_packet(lib: &Library, visit: &[u8], c: &Choice, seed: u64) -> Option<Vec<u8>> {
    let mut rng = Rng::new(seed);
    let partner_sex = 1u8.wrapping_sub(visit_sex(visit));
    let (dna_value, mut dna_pattern) = dna_from_type(c.kind, 0, &mut rng);
    if partner_sex == 0 {
        dna_pattern = [0; 8];
    }
    let (pdna, ppattern) = dna_from_type(0, 0, &mut rng);
    let ids = [c.picks[0].0, c.picks[1].0, c.picks[2].0, c.picks[3].0];
    let character_data = lib.character_data(c.baby_sex, ids, c.lang)?;
    let colors = [c.picks[0].1 as u8, c.picks[2].1 as u8, c.picks[3].1 as u8];
    let r: Vec<i32> = (0..7).map(|_| rng.next(0, 100)).collect();
    let k1 = [r[0], r[2], r[1], r[3]];
    let k2 = [100 - r[0], 100 - r[2], 100 - r[1], 100 - r[3]];
    let _ = (r[4], r[5], r[6]);
    let p1 = lib.fake_parent(&c.picks, k1, &mut rng)?;
    let p2 = lib.fake_parent(&c.picks, k2, &mut rng)?;
    // character information (140 bytes)
    let name = encode_name(if c.name.is_empty() { "TAMA" } else { &c.name }, c.lang);
    let mut info = vec![0u8; 140];
    {
        let mut w = W { b: &mut info, p: 0 };
        w.u32(1);
        w.u32(1);
        w.u32(128);
        w.u16(partner_sex as u16);
        w.u16(3);
        w.zeros(64);
        w.u16(257);
        w.u16(2);
        let mut n = [0u8; 18];
        let k = name.len().min(18);
        n[..k].copy_from_slice(&name[..k]);
        w.bytes(&n);
        w.u16(0);
        w.bytes(&n);
        w.u16(0);
    }
    // parent pictures (6156 bytes)
    let mut parents = vec![0u8; 6156];
    {
        let mut w = W { b: &mut parents, p: 0 };
        w.u32(8);
        w.u32(1);
        w.u32(6144);
        let mut a = encode_image(&p1);
        a.resize(3072, 0);
        let mut b = encode_image(&p2);
        b.resize(3072, 0);
        w.bytes(&a);
        w.bytes(&b);
    }
    let partner = Partner {
        sex: partner_sex,
        id: c.picks[0].0,
        name,
        generation: 2,
        growth: 4,
        twins: 0,
        birthday: 257,
        dna: pdna,
        dna_pattern: ppattern,
        palette: colors,
        character_info: info,
        parent_images: parents,
    };
    let m = Marriage { partner, character_data, colors, dna_pattern, dna_value, sex: c.baby_sex };
    Some(packet(OP_MARRIAGE, CMD_MARRIAGE, MARRIAGE_PACKET_SIZE, 0, None, Some(&m)))
}


// ---- shop items (MyMeets assets/items) -------------------------------------------

pub struct ShopItem {
    pub lang: String,
    pub file: String,
    pub id: String,
    pub name: String,
    pub kind: &'static str,
    pub data: Vec<u8>,
}

/// What an item is, from its id ("tg18_oy00079_1" -> food).
pub fn item_kind(id: &str) -> &'static str {
    let l = id.to_ascii_lowercase();
    let k = l.split('_').nth(1).unwrap_or("");
    let k: String = k.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
    match k.as_str() {
        "oy" | "gh" => "food",
        "as" => "item",
        "ac" => "accessory",
        "bg" => "wallpaper",
        "ode" => "stations",
        "gm" => "games",
        _ => "item",
    }
}

/// Read the id and toy-text name out of an item file (it starts with "TAMAGO").
pub fn item_info(d: &[u8]) -> Option<(String, String)> {
    if d.len() < 0x80 || &d[..6] != CODE_TAMAGO {
        return None;
    }
    let id: String = d[0x34..0x48].iter().take_while(|&&b| b != 0).map(|&b| b as char).collect();
    let name = decode_name(&d[0x5e..0x80]).replace('\u{3000}', " ");
    Some((id, name.trim().to_string()))
}

impl Library {
    pub fn add_item(&mut self, path: &str, data: Vec<u8>) {
        let parts: Vec<&str> = path.split(['/', '\\']).collect();
        let n = parts.len();
        if n < 2 {
            return;
        }
        let (lang, file) = (parts[n - 2].to_ascii_lowercase(), parts[n - 1].to_string());
        if let Some((id, name)) = item_info(&data) {
            let kind = item_kind(&id);
            self.items.push(ShopItem { lang, file, id, name, kind, data });
        }
    }
}

/// The packet that delivers an item file to the toy (op Item, cmd Item), as
/// MyMeets and WebMeets build it, optionally with Gotchi Points.
pub fn item_packet(item: &[u8], gotchi_points: u32) -> Vec<u8> {
    packet(0x17, 0x3A, 256 + 12 + item.len() + 4 + 2, gotchi_points, Some(item), None)
}

/// A file someone has: either an item file (TAMAGO + DL_ name) or an already
/// built delivery packet. Returns the packet to send.
pub fn wrap_user_item(d: &[u8], gotchi_points: u32) -> Option<Vec<u8>> {
    if d.len() < 0x110 || &d[..6] != CODE_TAMAGO {
        return None;
    }
    let size = u32::from_le_bytes([d[0x48], d[0x49], d[0x4a], d[0x4b]]) as usize;
    if size == d.len() && d[0x4c] == 0x17 {
        // already a delivery packet; unwrap so points can be added
        let inner_len = u32::from_le_bytes([d[0x108], d[0x109], d[0x10a], d[0x10b]]) as usize;
        if 0x10c + inner_len <= d.len() {
            return Some(item_packet(&d[0x10c..0x10c + inner_len], gotchi_points));
        }
        return Some(d.to_vec());
    }
    Some(item_packet(d, gotchi_points))
}

/// The "come home" packet (Back), optionally carrying one item and Gotchi
/// Points, so a Tama that shopped in town brings its souvenir home.
pub fn back_packet(item_or_packet: Option<&[u8]>, gotchi_points: u32) -> Vec<u8> {
    let raw = item_or_packet.and_then(|d| {
        if d.len() > 0x110 && &d[..6] == CODE_TAMAGO && d[0x4c] == 0x17 {
            let l = u32::from_le_bytes([d[0x108], d[0x109], d[0x10a], d[0x10b]]) as usize;
            d.get(0x10c..0x10c + l).map(|x| x.to_vec())
        } else if d.len() >= 0x80 && &d[..6] == CODE_TAMAGO {
            Some(d.to_vec())
        } else {
            None
        }
    });
    match raw {
        Some(it) => packet(0x15, 0x36, 256 + 12 + it.len() + 4 + 2, gotchi_points, Some(&it), None),
        None => packet(0x15, 0x36, 258, gotchi_points, None, None),
    }
}

// ---- custom items (draw your own wallpaper / food, like WebMeets) ---------------

/// Reduce RGBA pixels (0xAARRGGBB) to exactly `n` palette colours (nearest colour
/// for the rest). With `key` set, index 0 is the transparent key colour.
fn quantize(px: &[u32], n: usize, key: bool) -> (Vec<u32>, Vec<u8>) {
    use std::collections::HashMap;
    let opaque = |c: u32| (c >> 24) >= 128;
    let mut count: HashMap<u32, usize> = HashMap::new();
    for &c in px {
        if opaque(c) {
            *count.entry(c | 0xFF00_0000).or_insert(0) += 1;
        }
    }
    let mut colors: Vec<(u32, usize)> = count.into_iter().collect();
    colors.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    let room = if key { n - 1 } else { n };
    let mut pal: Vec<u32> = Vec::new();
    if key {
        pal.push(0xFFFF_00FF); // magenta key: the device treats pixel (0,0)'s colour as see-through
    }
    for (c, _) in colors.iter().take(room) {
        pal.push(*c);
    }
    if pal.is_empty() {
        pal.push(0xFFFF_FFFF);
    }
    while pal.len() < n {
        let last = *pal.last().unwrap();
        pal.push(last);
    }
    let dist = |a: u32, b: u32| {
        let d = |s: u32| (((a >> s) & 255) as i32 - ((b >> s) & 255) as i32).pow(2);
        d(16) + d(8) + d(0)
    };
    let first = if key { 1 } else { 0 };
    let idx: Vec<u8> = px
        .iter()
        .map(|&c| {
            if !opaque(c) {
                return 0;
            }
            let c = c | 0xFF00_0000;
            (first..pal.len()).min_by_key(|&i| dist(pal[i], c)).unwrap_or(0) as u8
        })
        .collect();
    (pal, idx)
}

/// One picture in the toy's format with exactly `n` (<= 16) colours.
fn encode_fixed(w: usize, h: usize, n: usize, pal: &[u32], idx: &[u8]) -> Vec<u8> {
    let mut out = vec![0u8; 6 + n * 2 + w * h / 2];
    out[0] = w as u8;
    out[1] = h as u8;
    out[2] = n as u8;
    out[3..5].copy_from_slice(&1u16.to_le_bytes());
    out[5] = 0xFF;
    for i in 0..n {
        out[6 + i * 2..8 + i * 2].copy_from_slice(&argb_to_565(pal[i]).to_be_bytes());
    }
    let start = 6 + n * 2;
    for i in 0..w * h / 2 {
        out[start + i] = (idx[i * 2] & 15) | (idx[i * 2 + 1] & 15) << 4;
    }
    out
}

/// Scale RGBA pixels (sw x sh) to w x h, nearest neighbour.
fn scale(px: &[u32], sw: usize, sh: usize, w: usize, h: usize) -> Vec<u32> {
    let mut out = vec![0u32; w * h];
    for y in 0..h {
        for x in 0..w {
            out[y * w + x] = px[(y * sh / h) * sw + (x * sw / w)];
        }
    }
    out
}

/// Crop the drawing to its visible part and scale it up (nearest neighbour, same aspect) so it fills a
/// w x h picture, centred on a transparent background. Small drawings on a big canvas otherwise show tiny.
fn fit(px: &[u32], sw: usize, sh: usize, w: usize, h: usize) -> Vec<u32> {
    let (mut x0, mut y0, mut x1, mut y1) = (sw, sh, 0usize, 0usize);
    for y in 0..sh {
        for x in 0..sw {
            if (px[y * sw + x] >> 24) >= 128 {
                x0 = x0.min(x);
                x1 = x1.max(x);
                y0 = y0.min(y);
                y1 = y1.max(y);
            }
        }
    }
    if x1 < x0 || y1 < y0 {
        return scale(px, sw, sh, w, h);
    }
    let (bw, bh) = (x1 - x0 + 1, y1 - y0 + 1);
    let (tw, th) = (w - 2, h - 2); // a pixel of breathing room all round
    // output size with the same aspect, as big as fits
    let (ow, oh) = if bw * th >= bh * tw { (tw, (bh * tw / bw).max(1)) } else { ((bw * th / bh).max(1), th) };
    let (ox, oy) = ((w - ow) / 2, (h - oh) / 2);
    let mut out = vec![0u32; w * h];
    for y in 0..oh {
        for x in 0..ow {
            out[(oy + y) * w + ox + x] = px[(y0 + y * bh / oh) * sw + x0 + x * bw / ow];
        }
    }
    out
}

/// Build a brand-new item file (like WebMeets' custom items) from a drawing:
/// a real item of the same kind from the pack is the template; its pictures,
/// name, price and id are replaced and the checksum is redone.
/// kind: "wallpaper" or "food". Pixels are 0xAARRGGBB, row by row.
pub fn custom_item(lib: &Library, kind: &str, name: &str, price: u16, px: &[u32], sw: usize, sh: usize, seed: u64) -> Option<Vec<u8>> {
    if px.len() < sw * sh || sw == 0 || sh == 0 {
        return None;
    }
    // "food"/"snack" -> oyatsu (_oy, a snack), "meal" -> gohan (_gh, a meal). The device decides
    // snack or meal from the template's food type, so each takes a real file of its own type.
    // kinds: "wallpaper", "food"/"snack" (_oy), "meal" (_gh), and "item:<animation>" (_as) where the animation code is
    // the byte at 0x78 of real item files: it picks how the item plays when you use it from the Item Box.
    let (base, anim) = match kind.split_once(':') {
        Some((b, a)) => (b, a.parse::<u8>().ok()),
        None => (kind, None),
    };
    let is_item = base == "item";
    let want_prefix = match base { "wallpaper" => "_bg", "meal" => "_gh", "item" => "_as", _ => "_oy" };
    let mut cands: Vec<&ShopItem> = lib.items.iter().filter(|it| {
        it.lang == "en" && it.id.contains(want_prefix) && !it.name.chars().any(|c| ('\u{3040}'..'\u{3100}').contains(&c))
            && it.data.len() > 0x210 && image_size(&it.data[0x204..]) > 0
            && (!is_item || anim.map_or(true, |a| it.data[0x78] == a))
    }).collect();
    if is_item { cands.sort_by_key(|it| !it.id.starts_with("tg18")); }
    let template = *cands.first()?;
    let mut d = template.data.clone();
    let end = d.len() - 2;
    // replace every picture in the file with the drawing (same size and colour count)
    let mut off = 0x204;
    let mut replaced = 0;
    while off + 6 <= end {
        let size = image_size(&d[off..]);
        if size == 0 || off + size > end {
            break;
        }
        let (w, h, n) = (d[off] as usize, d[off + 1] as usize, d[off + 2] as usize);
        if n > 16 || w * h % 2 != 0 {
            break;
        }
        let key = base != "wallpaper";
        let food = !is_item && key;
        let mut scaled = if key { fit(px, sw, sh, w, h) } else { scale(px, sw, sh, w, h) };
        // Food has three pictures: whole, bitten, nearly gone. Take bites out of
        // the drawing for the later ones so the eating animation looks right.
        if food && replaced > 0 {
            let keep = if replaced == 1 { w * 2 / 3 } else { w / 3 };
            for y in 0..h {
                for x in keep..w {
                    // a round bite edge rather than a straight cut
                    let dy = (y as i32 - h as i32 / 2).abs() as usize;
                    if x >= keep + (h / 2).saturating_sub(dy) / 3 {
                        scaled[y * w + x] = 0;
                    }
                }
            }
        }
        let (pal, mut idx) = quantize(&scaled, n, key);
        if key {
            idx[0] = 0; // pixel (0,0) is the see-through key
        }
        let pic = encode_fixed(w, h, n, &pal, &idx);
        d[off..off + pic.len()].copy_from_slice(&pic);
        off += size;
        replaced += 1;
        // Food files hold three pictures (whole, bitten, nearly gone), each after a 2-byte tag.
        if image_size(&d[off.min(end)..end]) == 0 && off + 2 <= end && image_size(&d[off + 2..end]) > 0 {
            off += 2;
        }
    }
    if replaced == 0 {
        return None;
    }
    // The device files an item by its kind byte (0x4F: 01 food, 07 wallpaper) AND
    // its number range (wallpapers live at 50000+), so keep both right for the kind,
    // with a number no real item uses so it never replaces one you own.
    if !is_item {
        d[0x4F] = if base == "wallpaper" { 0x07 } else { 0x01 };
    }
    let num: u16 = if base == "wallpaper" { 50900 + (seed % 90) as u16 } else if is_item { 17000 + (seed % 900) as u16 } else { 9000 + (seed % 900) as u16 };
    let id_old: String = d[0x34..0x48].iter().take_while(|&&b| b != 0).map(|&b| b as char).collect();
    let prefix_end = id_old.find(want_prefix).map(|i| i + want_prefix.len()).unwrap_or(0);
    let suffix = if id_old.ends_with("_1") { "_1" } else { "" };
    let id_new = format!("{}{:05}{}", &id_old[..prefix_end], num, suffix);
    for b in &mut d[0x34..0x48] {
        *b = 0;
    }
    for (i, b) in id_new.bytes().take(19).enumerate() {
        d[0x34 + i] = b;
    }
    d[0x5A..0x5C].copy_from_slice(&num.to_be_bytes());
    // file name (UTF-16BE) "DL_T18d_<num>.jpg"
    for b in &mut d[6..0x32] {
        *b = 0;
    }
    for (i, u) in format!("DL_T18d_{}.jpg", num).encode_utf16().take(22).enumerate() {
        d[6 + i * 2..8 + i * 2].copy_from_slice(&u.to_be_bytes());
    }
    // name (toy text, 12 slots, padded with spaces — zeros show as stray symbols) and price
    for i in 0..12 {
        d[0x5E + i * 2] = 4;
        d[0x5F + i * 2] = 0;
    }
    let enc = encode_name(name, 4);
    for (i, b) in enc.iter().take(24).enumerate() {
        d[0x5E + i] = *b;
    }
    d[0x76..0x78].copy_from_slice(&price.to_be_bytes());
    // checksum: big-endian sum of every byte before it
    let sum = d[..end].iter().fold(0u16, |a, &b| a.wrapping_add(b as u16));
    d[end..].copy_from_slice(&sum.to_be_bytes());
    Some(d)
}
