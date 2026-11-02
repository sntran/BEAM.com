//! The SVG loader of libvips for the part svg of vix: resvg draws an SVG
//! for c_src/vips/resvgload.c. The one global name is `vips_resvg`
//! (scripts/rust_link.sh).
//!
//! Caution: an SVG can link images by a path or a URL. The loader reads
//! only the images of `data:` URLs, and never a file or the network.

use std::ffi::{c_char, CStr};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::Path;
use std::sync::{Arc, OnceLock};

use resvg::tiny_skia;
use resvg::usvg::{self, fontdb};

/// The largest width and height of an image, in pixels.
const MAX_SIDE: f64 = 32767.0;

/// The request of resvgload.c. `op` 0 gives `width` and `height`. `op` 1
/// also draws the image into `pixels`: `width` times `height` RGBA pixels
/// with no premultiplied alpha, from the `width` and `height` of `op` 0.
#[repr(C)]
pub struct VipsResvg {
    pub op: i32,
    pub svg: *const u8,
    pub len: usize,
    pub dpi: f64,
    pub scale: f64,
    /// NULL, or a CSS text for the SVG.
    pub stylesheet: *const c_char,
    pub width: u32,
    pub height: u32,
    pub pixels: *mut u8,
    /// The text of an error, with a NUL at the end.
    pub error: [c_char; 256],
}

/// Gives 0, or -1 with the text of the error in `error`.
///
/// # Safety
///
/// `request` points to a `VipsResvg` with `len` bytes at `svg`, and for
/// `op` 1, `width * height * 4` bytes at `pixels`.
#[no_mangle]
pub unsafe extern "C" fn vips_resvg(request: *mut VipsResvg) -> i32 {
    let request = &mut *request;
    let result = catch_unwind(AssertUnwindSafe(|| run(request)))
        .unwrap_or_else(|_| Err("resvg stopped with a panic".to_string()));
    match result {
        Ok(()) => 0,
        Err(text) => {
            let bytes = text.as_bytes();
            let n = bytes.len().min(request.error.len() - 1);
            for (to, from) in request.error.iter_mut().zip(&bytes[..n]) {
                *to = *from as c_char;
            }
            request.error[n] = 0;
            -1
        }
    }
}

unsafe fn run(request: &mut VipsResvg) -> Result<(), String> {
    if request.svg.is_null() {
        return Err("no SVG data".to_string());
    }
    let data = std::slice::from_raw_parts(request.svg, request.len);
    let scale = request.scale;
    if !(scale.is_finite() && scale > 0.0) {
        return Err("bad scale".to_string());
    }
    let mut options = usvg::Options {
        fontdb: fonts(),
        image_href_resolver: usvg::ImageHrefResolver {
            resolve_data: usvg::ImageHrefResolver::default_data_resolver(),
            resolve_string: Box::new(|_, _| None),
        },
        ..usvg::Options::default()
    };
    if request.dpi.is_finite() && request.dpi > 0.0 {
        options.dpi = request.dpi as f32;
    }
    if !request.stylesheet.is_null() {
        let css = CStr::from_ptr(request.stylesheet)
            .to_str()
            .map_err(|_| "the stylesheet is not UTF-8".to_string())?;
        options.style_sheet = Some(css.to_string());
    }
    let tree = usvg::Tree::from_data(data, &options).map_err(|e| e.to_string())?;
    let size = tree.size();
    let width = (f64::from(size.width()) * scale).round();
    let height = (f64::from(size.height()) * scale).round();
    if !(width >= 1.0 && height >= 1.0) {
        return Err("zero-sized image".to_string());
    }
    if width > MAX_SIDE || height > MAX_SIDE {
        return Err("bad dimensions".to_string());
    }
    let (width, height) = (width as u32, height as u32);
    if request.op == 0 {
        request.width = width;
        request.height = height;
        return Ok(());
    }
    if request.op != 1 || request.pixels.is_null() {
        return Err("bad request".to_string());
    }
    if width != request.width || height != request.height {
        return Err("the size of the image changed".to_string());
    }
    let len = width as usize * height as usize * 4;
    let pixels = std::slice::from_raw_parts_mut(request.pixels, len);
    pixels.fill(0);
    let mut pixmap = tiny_skia::PixmapMut::from_bytes(pixels, width, height)
        .ok_or_else(|| "bad dimensions".to_string())?;
    // The scale of each side, so the drawing fills the whole image.
    let sx = width as f32 / size.width();
    let sy = height as f32 / size.height();
    resvg::render(&tree, tiny_skia::Transform::from_scale(sx, sy), &mut pixmap);
    // tiny-skia gives premultiplied alpha, and libvips needs straight alpha.
    for px in pixmap.data_mut().chunks_exact_mut(4) {
        let a = u32::from(px[3]);
        if a != 0 && a != 255 {
            for c in &mut px[..3] {
                *c = ((u32::from(*c) * 255 + a / 2) / a).min(255) as u8;
            }
        }
    }
    Ok(())
}

/// The fonts of the system, read one time. beam.com uses the std of Linux
/// on each system, so the folders of macOS and Windows are here too.
fn fonts() -> Arc<fontdb::Database> {
    static FONTS: OnceLock<Arc<fontdb::Database>> = OnceLock::new();
    FONTS
        .get_or_init(|| {
            let mut db = fontdb::Database::new();
            db.load_system_fonts();
            for dir in ["/System/Library/Fonts", "/Library/Fonts", "/C/Windows/Fonts"] {
                db.load_fonts_dir(dir);
            }
            if let Some(home) = std::env::var_os("HOME") {
                db.load_fonts_dir(Path::new(&home).join("Library/Fonts"));
            }
            generic_families(&mut db);
            Arc::new(db)
        })
        .clone()
}

/// The generic families (serif, sans-serif, monospace, cursive, fantasy)
/// with fonts that the system has. usvg uses serif when it finds no font.
fn generic_families(db: &mut fontdb::Database) {
    let names: Vec<String> = db
        .faces()
        .flat_map(|face| face.families.iter().map(|(name, _)| name.clone()))
        .collect();
    let find = |list: &[&str]| -> Option<String> {
        list.iter()
            .find(|want| names.iter().any(|n| n.eq_ignore_ascii_case(want)))
            .map(|s| s.to_string())
    };
    let serif = ["Times New Roman", "DejaVu Serif", "Liberation Serif", "Noto Serif", "Times"];
    let sans = ["Arial", "DejaVu Sans", "Liberation Sans", "Noto Sans", "Helvetica"];
    let mono = ["Courier New", "DejaVu Sans Mono", "Liberation Mono", "Noto Sans Mono", "Menlo"];
    let any = names.first().cloned();
    let sans = find(&sans).or_else(|| any.clone());
    if let Some(f) = find(&serif).or_else(|| sans.clone()) {
        db.set_serif_family(f);
    }
    if let Some(f) = sans.clone() {
        db.set_sans_serif_family(f);
    }
    if let Some(f) = find(&["Comic Sans MS"]).or_else(|| sans.clone()) {
        db.set_cursive_family(f);
    }
    if let Some(f) = find(&["Impact"]).or_else(|| sans.clone()) {
        db.set_fantasy_family(f);
    }
    if let Some(f) = find(&mono).or(sans) {
        db.set_monospace_family(f);
    }
}
