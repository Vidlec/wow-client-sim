//! AddonSim's native core, loaded by LuaJIT's FFI (lua/native.lua). One handle holds:
//!
//! - the scene stream's item store (store.rs): what the page holds, compared and written as binary frames;
//! - the scene's walk (graph.rs): a mirror of what the export reads, kept up to date by the Lua side with what
//!   changed (lua/scenesync.lua), walked each frame to decide which items stand, which only moved and which the Lua
//!   side must make again.
//!
//! Two ways to fill a frame: item by item from Lua's own export (`sc_begin`, `sc_item`, `sc_same`, `sc_move`,
//! `sc_end`), or by the walk (`sg_*`: the mirror's updates, `sg_walk`, the Lua side's `sg_submit` for each request,
//! `sg_finish`).

mod graph;
mod layout;
mod store;

use graph::{Graph, ObjectRecord, Point};
use std::slice;
use store::{Boxes, Store};

#[derive(Default)]
pub struct Native {
    store: Store,
    graph: Graph,
}

unsafe fn bytes<'a>(pointer: *const u8, length: usize) -> &'a [u8] {
    if pointer.is_null() || length == 0 {
        &[]
    } else {
        slice::from_raw_parts(pointer, length)
    }
}

unsafe fn written(out: Option<&[u8]>, length: *mut usize) -> *const u8 {
    match out {
        Some(frame) => {
            *length = frame.len();
            frame.as_ptr()
        }
        None => {
            *length = 0;
            std::ptr::null()
        }
    }
}

/// A new handle (one a stream: the server's simulator keeps one)
#[no_mangle]
pub extern "C" fn sc_new() -> *mut Native {
    Box::into_raw(Box::default())
}

/// # Safety
/// `native` comes from `sc_new` and is not used again
#[no_mangle]
pub unsafe extern "C" fn sc_free(native: *mut Native) {
    if !native.is_null() {
        drop(Box::from_raw(native));
    }
}

/// The handle's version, for the Lua side to check it loaded the build it knows
#[no_mangle]
pub extern "C" fn sc_version() -> u32 {
    3
}

// The store, filled item by item from Lua's own export

/// # Safety
/// `native` comes from `sc_new`
#[no_mangle]
pub unsafe extern "C" fn sc_begin(native: *mut Native) {
    (*native).store.begin();
}

/// An item made this frame: its key and packed bytes
///
/// # Safety
/// `native` comes from `sc_new`; the pointers hold the lengths given
#[no_mangle]
pub unsafe extern "C" fn sc_item(
    native: *mut Native,
    key: *const u8,
    key_length: usize,
    item: *const u8,
    item_length: usize,
) {
    let store = &mut (*native).store;
    let id = store.intern(bytes(key, key_length));
    store.item(id, bytes(item, item_length));
}

/// A kept item, as the page holds it
///
/// # Safety
/// `native` comes from `sc_new`; `key` holds `key_length` bytes
#[no_mangle]
pub unsafe extern "C" fn sc_same(native: *mut Native, key: *const u8, key_length: usize) {
    let store = &mut (*native).store;
    let id = store.intern(bytes(key, key_length));
    store.same(id);
}

/// A kept item given new boxes: 4 numbers its own box, then 4 its clip's (all NaN: none), then 4 each mask's
///
/// # Safety
/// `native` comes from `sc_new`; `key` holds `key_length` bytes, `boxes` `count` numbers (8 or more, a multiple of 4)
#[no_mangle]
pub unsafe extern "C" fn sc_move(
    native: *mut Native,
    key: *const u8,
    key_length: usize,
    boxes: *const f64,
    count: usize,
) {
    let store = &mut (*native).store;
    let id = store.intern(bytes(key, key_length));
    if boxes.is_null() || count < 8 {
        store.same(id);
        return;
    }
    let numbers = slice::from_raw_parts(boxes, count);
    let take = |at: usize| [numbers[at], numbers[at + 1], numbers[at + 2], numbers[at + 3]];
    let clip = take(4);
    store.moved(
        id,
        Boxes {
            own: take(0),
            clip: if clip[0].is_nan() { None } else { Some(clip) },
            masks: (8..count.saturating_sub(3)).step_by(4).map(take).collect(),
        },
    );
}

/// Ends the frame: the binary frame of what changed (its length in `length`; 0 when nothing did), valid until the
/// handle is next called
///
/// # Safety
/// `native` comes from `sc_new`; `length` is writable
#[no_mangle]
pub unsafe extern "C" fn sc_end(native: *mut Native, length: *mut usize) -> *const u8 {
    written((*native).store.end(), length)
}

/// The whole scene the page should hold (for one that joins or fell behind)
///
/// # Safety
/// `native` comes from `sc_new`; `length` is writable
#[no_mangle]
pub unsafe extern "C" fn sc_whole(native: *mut Native, length: *mut usize) -> *const u8 {
    let frame = (*native).store.whole();
    *length = frame.len();
    frame.as_ptr()
}

// The walk

/// An object's state, as the Lua side has it now
///
/// # Safety
/// `native` comes from `sc_new`; `record` points to a whole record
#[no_mangle]
pub unsafe extern "C" fn sg_object(native: *mut Native, record: *const ObjectRecord) {
    (*native).graph.set_object(&*record);
}

/// An object's anchors, as the Lua side has them now
///
/// # Safety
/// `native` comes from `sc_new`; `points` holds `count` anchors
#[no_mangle]
pub unsafe extern "C" fn sg_points(native: *mut Native, id: u32, points: *const Point, count: usize) {
    let points = if points.is_null() || count == 0 {
        &[][..]
    } else {
        slice::from_raw_parts(points, count)
    };
    (*native).graph.set_points(id, points);
}

/// The Lua side's measure of a text (layout.rs): called while the walk lays out
///
/// # Safety
/// `native` comes from `sc_new`; `measure` stays callable while the handle lives
#[no_mangle]
pub unsafe extern "C" fn sg_set_measure(native: *mut Native, measure: Option<layout::Measure>) {
    (*native).graph.layout.measure = measure;
}

/// An object's rectangle as laid out here (for the check against the Lua layout); false when it has none
///
/// # Safety
/// `native` comes from `sc_new`; `rect` holds 4 numbers
#[no_mangle]
pub unsafe extern "C" fn sg_layout_rect(native: *mut Native, id: u32, rect: *mut f64) -> bool {
    match (*native).graph.layout_rect(id) {
        Some(r) => {
            for (index, value) in r.iter().enumerate() {
                *rect.add(index) = *value;
            }
            true
        }
        None => false,
    }
}

/// The shown frames in drawing order, each with its level group (frames of one strata, level and raise)
///
/// # Safety
/// `native` comes from `sc_new`; `frames` and `groups` hold `count` numbers
#[no_mangle]
pub unsafe extern "C" fn sg_order(native: *mut Native, frames: *const u32, groups: *const u32, count: usize) {
    if count == 0 || frames.is_null() || groups.is_null() {
        (*native).graph.set_order(&[], &[]);
        return;
    }
    (*native).graph.set_order(
        slice::from_raw_parts(frames, count),
        slice::from_raw_parts(groups, count),
    );
}

/// What the whole scene depends on: the frame under the mouse, the one pressed, the edit box with the focus, the font
/// objects' version, the screen's size
///
/// # Safety
/// `native` comes from `sc_new`
#[no_mangle]
pub unsafe extern "C" fn sg_globals(
    native: *mut Native,
    motion_focus: u32,
    pressed: u32,
    focus: u32,
    fonts_version: f64,
    screen_width: f64,
    screen_height: f64,
) {
    (*native)
        .graph
        .set_globals(motion_focus, pressed, focus, fonts_version, screen_width, screen_height);
}

/// This frame's animation effects: cleared, then one for each object an animation plays on
///
/// # Safety
/// `native` comes from `sc_new`
#[no_mangle]
pub unsafe extern "C" fn sg_effects_clear(native: *mut Native) {
    (*native).graph.clear_effects();
}

/// # Safety
/// `native` comes from `sc_new`
#[no_mangle]
pub unsafe extern "C" fn sg_effect(native: *mut Native, id: u32, flags: u32, alpha: f64) {
    (*native).graph.set_effect(id, flags, alpha);
}

/// Walks the scene: the number of requests for the Lua side (read with `sg_request`, answered with `sg_submit`)
///
/// # Safety
/// `native` comes from `sc_new`
#[no_mangle]
pub unsafe extern "C" fn sg_walk(native: *mut Native) -> u32 {
    let native = &mut *native;
    native.graph.walk(&native.store) as u32
}

/// A request: what to make (1 a region's items, 2 a frame's before its regions, 3 a frame's after them) and the
/// object's id; false past the last
///
/// # Safety
/// `native` comes from `sc_new`; `kind` and `id` are writable
#[no_mangle]
pub unsafe extern "C" fn sg_request(native: *mut Native, index: u32, kind: *mut u32, id: *mut u32) -> bool {
    match (*native).graph.request_at(index as usize) {
        Some((k, i)) => {
            *kind = k;
            *id = i;
            true
        }
        None => false,
    }
}

/// An item the Lua side made for a request: its key and packed bytes
///
/// # Safety
/// `native` comes from `sc_new`; the pointers hold the lengths given
#[no_mangle]
pub unsafe extern "C" fn sg_submit(
    native: *mut Native,
    request: u32,
    key: *const u8,
    key_length: usize,
    item: *const u8,
    item_length: usize,
) {
    let native = &mut *native;
    let id = native.store.intern(bytes(key, key_length));
    native.graph.submit(request as usize, id, bytes(item, item_length));
}

/// Puts the walked frame together: the binary frame of what changed (0 length when nothing did)
///
/// # Safety
/// `native` comes from `sc_new`; `length` is writable
#[no_mangle]
pub unsafe extern "C" fn sg_finish(native: *mut Native, length: *mut usize) -> *const u8 {
    let native = &mut *native;
    native.graph.finish(&mut native.store);
    written(native.store.end(), length)
}

/// The last walk's counts: regions and backdrops kept, moved, made; items dropped as a second of one key
///
/// # Safety
/// `native` comes from `sc_new`; the pointers are writable
#[no_mangle]
pub unsafe extern "C" fn sg_counts(
    native: *mut Native,
    kept: *mut u32,
    moved: *mut u32,
    made: *mut u32,
    dropped: *mut u32,
) {
    let graph = &(*native).graph;
    *kept = graph.kept_count;
    *moved = graph.moved_count;
    *made = graph.made_count;
    *dropped = graph.dropped_count;
}
