//! The scene's walk in Rust: a mirror of what lua/scene.lua's export reads (each object's place in the tree, shown,
//! alpha, rectangle, scale, layer, button state, masks), kept up to date by the Lua side with only what changed
//! (lua/scenesync.lua), and the walk over it each frame: the frames by level, their regions sorted together, which
//! regions show (a button's state textures, highlights), each one's alpha and clip, and whether its items stand as they
//! were, only moved (their new boxes worked out here), or must be made again by the Lua side (lua/scene.lua's
//! builders). Rules ported one for one from lua/scene.lua's buildScene; ADDONSIM_CHECK_SCENE=1 compares the two.
//!
//! Objects have ids handed out from 1 on, so everything about one sits in vectors indexed by its id; what the walk
//! works out once per frame (alphas, clips) is kept with the walk's number beside it, never cleared.

use crate::store::{Boxes, Store};
use std::collections::HashMap;

/// An object as the Lua side reports it (lua/scenesync.lua fills the same struct through the FFI)
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct ObjectRecord {
    pub id: u32,
    pub parent: u32,
    pub scroll_child_of: u32,
    pub masks: [u32; 3],
    pub visual_version: u32,
    pub flags: u32,
    pub sublevel: i32,
    pub art_order: i32,
    pub kind: u8,
    pub layer: u8,
    pub role: u8,
    pub mask_count: u8,
    pub alpha: f64,
    /// its own scale (SetScale); the effective one is worked out here (layout.rs)
    pub scale: f64,
    /// what it is laid out from besides its anchors (layout.rs): its size as set (0: none), its atlas's size, a
    /// scroll frame's offsets
    pub width: f64,
    pub height: f64,
    pub atlas_width: f64,
    pub atlas_height: f64,
    pub scroll_x: f64,
    pub scroll_y: f64,
}

/// An anchor (SetPoint): its point and the other object's (TOPLEFT 1 .. BOTTOMRIGHT 9), that object, the offset
#[repr(C)]
#[derive(Clone, Copy, PartialEq)]
pub struct Point {
    pub relative: u32,
    pub point: u8,
    pub relative_point: u8,
    pub pad: [u8; 2],
    pub x: f64,
    pub y: f64,
}

// flags
pub const SHOWN: u32 = 1 << 0;
pub const IS_ROOT: u32 = 1 << 1;
pub const IGNORE_PARENT_ALPHA: u32 = 1 << 2;
pub const CLIPS: u32 = 1 << 3;
pub const FLATTENS: u32 = 1 << 4;
pub const USE_PARENT_LEVEL: u32 = 1 << 5;
pub const ENABLED: u32 = 1 << 6;
pub const CHECKED: u32 = 1 << 7;
pub const BUTTON_PUSHED: u32 = 1 << 8;
pub const HAS_PUSHED: u32 = 1 << 9;
pub const HAS_DISABLED: u32 = 1 << 10;
pub const MOTION_WHILE_DISABLED: u32 = 1 << 11;
pub const HIGHLIGHT_LOCKED: u32 = 1 << 12;
pub const DISABLED_CHECKED: u32 = 1 << 13;
pub const HAS_BACKDROP: u32 = 1 << 14;
pub const HAS_MESSAGES: u32 = 1 << 15;
pub const IS_UNITS: u32 = 1 << 16;
pub const IS_LIVE_COOLDOWN: u32 = 1 << 17;
pub const TIMER_BAR: u32 = 1 << 18;
pub const MAP_CANVAS: u32 = 1 << 19;
pub const PARENT_MAP_CANVAS: u32 = 1 << 20;
pub const EDIT_TEXT: u32 = 1 << 21;
pub const HIGHLIGHT_LAYER: u32 = 1 << 22;
pub const HAS_ART: u32 = 1 << 23;
pub const IGNORE_PARENT_SCALE: u32 = 1 << 24;
pub const MADE_BY_CODE: u32 = 1 << 25;
pub const COLLAPSES_LAYOUT: u32 = 1 << 26;
pub const CLAMPED: u32 = 1 << 27;
pub const HAS_ATLAS_SIZE: u32 = 1 << 28;

// kinds
pub const FRAME: u8 = 1;
pub const TEXTURE: u8 = 2;
pub const FONT_STRING: u8 = 3;
pub const LINE: u8 = 4;
pub const MASK: u8 = 5;

// roles
const ROLE_NORMAL: u8 = 1;
const ROLE_PUSHED: u8 = 2;
const ROLE_DISABLED: u8 = 3;
const ROLE_HIGHLIGHT: u8 = 4;
const ROLE_CHECKED: u8 = 5;
const ROLE_DISABLED_CHECKED: u8 = 6;
const ROLE_BAR: u8 = 7;
const ROLE_THUMB: u8 = 8;

// animation effects (lua/animation.lua): a transform (move, scale, turn), an alpha
pub const EFFECT_TRANSFORM: u32 = 2;
pub const EFFECT_ALPHA: u32 = 4;

// what a request asks the Lua side to make
pub const REQUEST_REGION: u32 = 1;
pub const REQUEST_FRAME_BEFORE: u32 = 2;
pub const REQUEST_FRAME_AFTER: u32 = 3;

pub(crate) type Rect = [f64; 4];
const NO_PLACE: f64 = f64::NEG_INFINITY;

#[derive(Clone, Default)]
pub(crate) struct Object {
    pub(crate) record: Option<ObjectRecord>,
    pub(crate) points: Vec<Point>,
    /// the regions and frames whose parent this is (kept as records come in)
    pub(crate) regions: Vec<u32>,
    pub(crate) children: Vec<u32>,
}

/// An object's items as last made, and what they were made from
#[derive(Clone, Default)]
struct Kept {
    stamp: Vec<f64>,
    place: Vec<f64>,
    keys: Vec<u32>,
}

#[derive(Clone)]
enum Decision {
    Kept,
    Moved(Boxes),
    Make(usize),
}

struct Slot {
    is_before: bool,
    id: u32,
    decision: Decision,
    /// what the items were made from (made again, or moved), None when nothing is kept for them
    stamp: Option<(Vec<f64>, Vec<f64>)>,
}

/// A value worked out once a walk: kept with the walk's number
#[derive(Clone, Copy, Default)]
pub(crate) struct Memo<T: Copy + Default> {
    pub(crate) walk: u64,
    pub(crate) value: T,
}

#[derive(Default)]
pub struct Graph {
    pub(crate) objects: Vec<Object>,
    pub(crate) layout: crate::layout::Layout,
    order: Vec<u32>,
    groups: Vec<u32>,
    // globals
    motion_focus: u32,
    pressed: u32,
    focus: u32,
    pub(crate) fonts_version: f64,
    pub(crate) screen_height: f64,
    pub(crate) screen_width: f64,
    effects: HashMap<u32, (u32, f64)>,
    kept_regions: Vec<Option<Kept>>,
    kept_before: Vec<Option<Kept>>,
    // this walk
    walk_number: u64,
    slots: Vec<Slot>,
    requests: Vec<(u32, u32)>,
    made: Vec<Vec<(u32, Vec<u8>)>>,
    alpha_memo: Vec<Memo<f64>>,
    clip_memo: Vec<Memo<Option<Rect>>>,
    inside_memo: Vec<Memo<Option<Rect>>>,
    transform_memo: Vec<Memo<bool>>,
    drawn: Vec<u64>,
    gathered: Vec<(u32, u32, u64)>,
    scratch_children: Vec<u32>,
    shape: Vec<f64>,
    place: Vec<f64>,
    pub kept_count: u32,
    pub moved_count: u32,
    pub made_count: u32,
    pub dropped_count: u32,
}

fn round1(value: f64) -> f64 {
    (value * 10.0 + 0.5).floor() / 10.0
}
fn fine(value: f64) -> f64 {
    (value * 1_000_000.0 + 0.5).floor() / 1_000_000.0
}
pub(crate) fn grow<T: Default + Clone>(list: &mut Vec<T>, id: u32) {
    let need = id as usize + 1;
    if list.len() < need {
        list.resize(need.max(list.len() * 2), T::default());
    }
}

impl Graph {
    fn to_box(&self, rect: &Rect) -> [f64; 4] {
        let (left, right) = (round1(rect[0]), round1(rect[2]));
        let (top, bottom) = (
            round1(self.screen_height - rect[3]),
            round1(self.screen_height - rect[1]),
        );
        [left, top, right - left, bottom - top]
    }

    fn object_mut(&mut self, id: u32) -> &mut Object {
        grow(&mut self.objects, id);
        &mut self.objects[id as usize]
    }

    pub fn set_object(&mut self, record: &ObjectRecord) {
        let id = record.id;
        if id == 0 {
            return;
        }
        let old = self.record(id).copied();
        if let Some(old) = &old {
            self.layout_changed(id, old, record);
        }
        let (old_parent, old_kind) = old.map(|r| (r.parent, r.kind)).unwrap_or((0, 0));
        if old.is_none() || old_parent != record.parent || old_kind != record.kind {
            if old_parent != 0 {
                let parent = self.object_mut(old_parent);
                parent.regions.retain(|&x| x != id);
                parent.children.retain(|&x| x != id);
            }
            if record.parent != 0 {
                let parent = self.object_mut(record.parent);
                if record.kind == FRAME {
                    parent.children.push(id);
                } else {
                    parent.regions.push(id);
                }
            }
        }
        self.object_mut(id).record = Some(*record);
    }

    /// An object's anchors, as the Lua side has them now
    pub fn set_points(&mut self, id: u32, points: &[Point]) {
        if id == 0 {
            return;
        }
        if self.object_mut(id).points.as_slice() != points {
            self.object_mut(id).points = points.to_vec();
            self.invalidate(id);
        }
    }

    pub fn set_order(&mut self, frames: &[u32], groups: &[u32]) {
        self.order.clear();
        self.order.extend_from_slice(frames);
        self.groups.clear();
        self.groups.extend_from_slice(groups);
    }

    #[allow(clippy::too_many_arguments)]
    pub fn set_globals(
        &mut self,
        motion_focus: u32,
        pressed: u32,
        focus: u32,
        fonts_version: f64,
        screen_width: f64,
        screen_height: f64,
    ) {
        self.motion_focus = motion_focus;
        self.pressed = pressed;
        self.focus = focus;
        // (the screen's size or the font objects changed: every rectangle is worked out again)
        if fonts_version != self.fonts_version
            || screen_width != self.screen_width
            || screen_height != self.screen_height
        {
            self.invalidate_all();
        }
        self.fonts_version = fonts_version;
        self.screen_width = screen_width;
        self.screen_height = screen_height;
    }

    pub fn clear_effects(&mut self) {
        self.effects.clear();
    }
    pub fn set_effect(&mut self, id: u32, flags: u32, alpha: f64) {
        self.effects.insert(id, (flags, alpha));
    }

    pub(crate) fn record(&self, id: u32) -> Option<&ObjectRecord> {
        self.objects.get(id as usize).and_then(|o| o.record.as_ref())
    }

    /// An object's rectangle, laid out here (layout.rs)
    fn rect(&mut self, id: u32) -> Option<Rect> {
        self.layout_rect(id)
    }

    /// An object's own alpha: an Alpha animation's while one plays on it
    fn own_alpha(&self, id: u32, record: &ObjectRecord) -> f64 {
        if self.effects.is_empty() {
            return record.alpha;
        }
        match self.effects.get(&id) {
            Some(&(flags, alpha)) if flags & EFFECT_ALPHA != 0 => alpha,
            _ => record.alpha,
        }
    }

    fn effective_alpha(&mut self, id: u32) -> f64 {
        let walk = self.walk_number;
        if let Some(memo) = self.alpha_memo.get(id as usize) {
            if memo.walk == walk {
                return memo.value;
            }
        }
        let Some(record) = self.record(id).copied() else {
            return 1.0;
        };
        let mut alpha = self.own_alpha(id, &record);
        if record.flags & (IGNORE_PARENT_ALPHA | IS_ROOT) == 0
            && record.parent != 0
            && self.record(record.parent).is_some()
        {
            alpha *= self.effective_alpha(record.parent);
        }
        grow(&mut self.alpha_memo, id);
        self.alpha_memo[id as usize] = Memo { walk, value: alpha };
        alpha
    }

    fn clip_to(&mut self, clip: Option<Rect>, frame: u32) -> Option<Rect> {
        let Some(rect) = self.rect(frame) else { return clip };
        match clip {
            None => Some(rect),
            Some(c) => Some([
                c[0].max(rect[0]),
                c[1].max(rect[1]),
                c[2].min(rect[2]),
                c[3].min(rect[3]),
            ]),
        }
    }

    /// The clip a frame puts on what it holds: its own rectangle if it clips, within the clip it is in
    fn inside_clip(&mut self, frame: u32) -> Option<Rect> {
        let walk = self.walk_number;
        if let Some(memo) = self.inside_memo.get(frame as usize) {
            if memo.walk == walk {
                return memo.value;
            }
        }
        let mut clip = self.export_clip(frame);
        if self.record(frame).is_some_and(|r| r.flags & CLIPS != 0) {
            clip = self.clip_to(clip, frame);
        }
        grow(&mut self.inside_memo, frame);
        self.inside_memo[frame as usize] = Memo { walk, value: clip };
        clip
    }

    fn export_clip(&mut self, frame: u32) -> Option<Rect> {
        let walk = self.walk_number;
        if let Some(memo) = self.clip_memo.get(frame as usize) {
            if memo.walk == walk {
                return memo.value;
            }
        }
        let mut clip = None;
        if let Some(record) = self.record(frame).copied() {
            if record.parent != 0 && self.record(record.parent).is_some() {
                clip = self.inside_clip(record.parent);
            }
            // (a scroll child: cut to its scroll frame, which clips only it)
            if record.scroll_child_of != 0 && self.record(record.scroll_child_of).is_some() {
                clip = self.clip_to(clip, record.scroll_child_of);
            }
        }
        grow(&mut self.clip_memo, frame);
        self.clip_memo[frame as usize] = Memo { walk, value: clip };
        clip
    }

    /// Whether an animation moves, sizes or turns the object or one it is in
    fn is_transformed(&mut self, id: u32) -> bool {
        if self.effects.is_empty() {
            return false;
        }
        let walk = self.walk_number;
        if let Some(memo) = self.transform_memo.get(id as usize) {
            if memo.walk == walk {
                return memo.value;
            }
        }
        let own = self
            .effects
            .get(&id)
            .is_some_and(|&(flags, _)| flags & EFFECT_TRANSFORM != 0);
        let parent = self
            .record(id)
            .filter(|r| r.flags & IS_ROOT == 0 && r.parent != 0)
            .map(|r| r.parent)
            .filter(|&p| self.record(p).is_some());
        let result = own || parent.is_some_and(|p| self.is_transformed(p));
        grow(&mut self.transform_memo, id);
        self.transform_memo[id as usize] = Memo { walk, value: result };
        result
    }

    /// Whether a button's state texture shows now, as the game swaps them
    fn is_role_shown(&self, frame: &ObjectRecord, frame_id: u32, role: u8) -> bool {
        let flags = frame.flags;
        let enabled = flags & ENABLED != 0;
        let pressed = self.pressed == frame_id && self.motion_focus == frame_id;
        let pushed = pressed || flags & BUTTON_PUSHED != 0;
        match role {
            ROLE_NORMAL => !(pushed && flags & HAS_PUSHED != 0) && !(!enabled && flags & HAS_DISABLED != 0),
            ROLE_PUSHED => enabled && pushed,
            ROLE_DISABLED => !enabled,
            ROLE_HIGHLIGHT => {
                (self.motion_focus == frame_id && (enabled || flags & MOTION_WHILE_DISABLED != 0))
                    || flags & HIGHLIGHT_LOCKED != 0
            }
            ROLE_CHECKED => flags & CHECKED != 0 && (enabled || flags & DISABLED_CHECKED == 0),
            ROLE_DISABLED_CHECKED => flags & CHECKED != 0 && !enabled,
            _ => true,
        }
    }

    fn is_drawn(&self, id: u32) -> bool {
        self.drawn.get(id as usize) == Some(&self.walk_number)
    }
    fn mark_drawn(&mut self, id: u32) {
        grow(&mut self.drawn, id);
        self.drawn[id as usize] = self.walk_number;
    }

    /// The regions of a frame and of its children drawn at its level (useParentLevel), each with its owner and sort key
    fn gather(&mut self, owner: u32, rank: u32) {
        let Some(object) = self.objects.get(owner as usize) else {
            return;
        };
        for &region in &object.regions {
            let Some(record) = self.objects.get(region as usize).and_then(|o| o.record.as_ref()) else {
                continue;
            };
            if record.flags & SHOWN == 0 || record.kind == MASK || record.parent != owner {
                continue;
            }
            let sublevel = record.sublevel.clamp(-512, 511) as i64;
            let text = if record.kind == FONT_STRING { 1 } else { 0 };
            let key = (((record.layer as i64) * 2 + text) * 1024 + sublevel + 512) * 1024 + (rank.min(1023) as i64);
            self.gathered.push((region, owner, key as u64));
        }
        if object.children.is_empty() {
            return;
        }
        let start = self.scratch_children.len();
        self.scratch_children
            .extend_from_slice(&self.objects[owner as usize].children);
        let end = self.scratch_children.len();
        for index in start..end {
            let child = self.scratch_children[index];
            let Some(record) = self.record(child).copied() else {
                continue;
            };
            if record.flags & USE_PARENT_LEVEL != 0 && record.flags & SHOWN != 0 && !self.is_drawn(child) {
                let has_rect = self.rect(child).is_some();
                if has_rect && self.effective_alpha(child) > 0.002 {
                    self.mark_drawn(child);
                    self.gather(child, rank + 1);
                }
            }
        }
        self.scratch_children.truncate(start);
    }

    fn put_size(&mut self, rect: &Option<Rect>) {
        match rect {
            Some(r) => {
                self.shape.push(fine(r[2] - r[0]));
                self.shape.push(fine(r[3] - r[1]));
            }
            None => self.shape.push(NO_PLACE),
        }
    }
    fn put_relative(&mut self, box_: &Option<Rect>, rect: &Option<Rect>) {
        match (box_, rect) {
            (Some(b), Some(r)) => {
                self.shape.push(fine(b[0] - r[0]));
                self.shape.push(fine(b[1] - r[1]));
                self.shape.push(fine(b[2] - b[0]));
                self.shape.push(fine(b[3] - b[1]));
            }
            (b, _) => self.shape.push(if b.is_some() { 1.0 } else { 0.0 }),
        }
    }
    fn put_place(&mut self, rect: &Option<Rect>) {
        match rect {
            Some(r) => self.place.extend_from_slice(r),
            None => self.place.push(NO_PLACE),
        }
    }

    /// A region's stamp into self.shape and self.place, with whether a move of it can be kept and its moved boxes;
    /// None when its items are made every time
    #[allow(clippy::too_many_arguments)]
    fn stamp_region(
        &mut self,
        region: u32,
        record: &ObjectRecord,
        owner: u32,
        owner_record: &ObjectRecord,
        owner_rect: &Rect,
        clip: Option<Rect>,
        flattened: bool,
        owner_alpha: f64,
        region_alpha: f64,
    ) -> Option<(bool, Boxes)> {
        if record.kind == LINE {
            return None;
        }
        if !self.effects.is_empty() && (self.effects.contains_key(&region) || self.is_transformed(region)) {
            return None;
        }
        let role = record.role;
        let is_value = role == ROLE_BAR || role == ROLE_THUMB;
        if is_value && owner_record.flags & TIMER_BAR != 0 {
            return None;
        }
        let rect = self.rect(region);
        self.shape.clear();
        self.place.clear();
        self.shape.push(record.visual_version as f64);
        self.put_size(&rect);
        let scale = self.effective_scale(region);
        self.shape.push(scale);
        self.shape.push(region_alpha);
        self.shape.push(self.screen_height);
        self.put_place(&rect);
        let mut boxes = Boxes {
            own: rect.map(|r| self.to_box(&r)).unwrap_or_default(),
            ..Default::default()
        };
        if record.kind == FONT_STRING {
            let string_clip = if owner_record.flags & CLIPS != 0 {
                Some(*owner_rect)
            } else {
                clip
            };
            self.put_relative(&string_clip, &rect);
            self.put_place(&string_clip);
            boxes.clip = string_clip.map(|c| self.to_box(&c));
            self.shape.push(self.fonts_version);
            self.shape
                .push(if record.flags & EDIT_TEXT != 0 && self.focus == owner {
                    1.0
                } else {
                    0.0
                });
        } else {
            self.put_relative(&clip, &rect);
            self.put_place(&clip);
            boxes.clip = clip.map(|c| self.to_box(&c));
            if is_value {
                self.shape.push(owner_record.visual_version as f64);
                self.put_place(&Some(*owner_rect));
            }
            for &mask in record.masks.iter().take((record.mask_count as usize).min(3)) {
                let mask_record = self.record(mask).copied();
                let mask_rect = mask_record
                    .filter(|m| m.flags & HAS_ART != 0)
                    .and_then(|_| self.rect(mask));
                self.shape
                    .push(mask_record.map(|m| m.visual_version as f64).unwrap_or(0.0));
                self.put_relative(&mask_rect, &rect);
                let mask_scale = if mask_record.is_some() {
                    self.effective_scale(mask)
                } else {
                    1.0
                };
                self.shape.push(mask_scale);
                if let Some(mask_rect) = mask_rect {
                    self.put_place(&Some(mask_rect));
                    boxes.masks.push(self.to_box(&mask_rect));
                }
            }
            self.shape.push(owner as f64);
            self.shape
                .push(if owner_record.flags & MAP_CANVAS != 0 { 1.0 } else { 0.0 });
            self.shape.push(if owner_record.flags & PARENT_MAP_CANVAS != 0 {
                1.0
            } else {
                0.0
            });
        }
        self.shape.push(if flattened { 1.0 } else { 0.0 });
        if flattened {
            self.shape.push(owner as f64);
            self.shape.push(owner_alpha);
        }
        Some((!is_value, boxes))
    }

    /// The stamp just made against what was kept: Some(false) kept as it is, Some(true) moved, None made again
    fn decide(&self, kept: Option<&Kept>, can_move: bool, store: &Store) -> Option<bool> {
        let kept = kept?;
        if kept.stamp != self.shape {
            return None;
        }
        // (its items must still be held: those of an object out of sight for a frame were let go)
        if kept.keys.iter().any(|&key| !store.holds(key)) {
            return None;
        }
        if kept.place == self.place {
            Some(false)
        } else if can_move {
            Some(true)
        } else {
            None
        }
    }

    fn request(&mut self, kind: u32, id: u32) -> Decision {
        self.requests.push((kind, id));
        if self.made.len() < self.requests.len() {
            self.made.push(Vec::new());
        }
        Decision::Make(self.requests.len() - 1)
    }

    fn stamp_copy(&self) -> Option<(Vec<f64>, Vec<f64>)> {
        Some((self.shape.clone(), self.place.clone()))
    }

    /// The walk: the slots of this frame's scene, and the requests for what the Lua side has to make
    pub fn walk(&mut self, store: &Store) -> usize {
        self.walk_number += 1;
        self.slots.clear();
        self.requests.clear();
        for made in &mut self.made {
            made.clear();
        }
        let order = std::mem::take(&mut self.order);
        let groups = std::mem::take(&mut self.groups);
        let mut first = 0;
        while first < order.len() {
            let mut last = first;
            while last + 1 < order.len() && groups[last + 1] == groups[first] {
                last += 1;
            }
            // Each frame's own drawing before its regions (a backdrop, a message frame's lines)
            self.gathered.clear();
            for (offset, &frame) in order[first..=last].iter().enumerate() {
                let Some(record) = self.record(frame).copied() else {
                    continue;
                };
                let Some(rect) = self.rect(frame) else { continue };
                let alpha = self.effective_alpha(frame);
                if alpha <= 0.002 {
                    continue;
                }
                let clip = self.export_clip(frame);
                self.slot_before(frame, &record, &rect, alpha, clip, store);
                if !self.is_drawn(frame) {
                    self.mark_drawn(frame);
                    self.gather(frame, ((offset * 8) as u32).min(1000));
                }
            }
            // Every region of the level in one order: layer, text over textures, sublevel, rank, art order, id
            let mut gathered = std::mem::take(&mut self.gathered);
            gathered.sort_by(|a, b| {
                a.2.cmp(&b.2).then_with(|| {
                    let art_a = self.record(a.0).map(|r| r.art_order).unwrap_or(0);
                    let art_b = self.record(b.0).map(|r| r.art_order).unwrap_or(0);
                    art_a.cmp(&art_b).then_with(|| a.0.cmp(&b.0))
                })
            });
            for &(region, owner, _) in &gathered {
                self.slot_region(region, owner, store);
            }
            self.gathered = gathered;
            // What is drawn over a frame's regions: a map's units, a cooldown's swipe (made every time)
            for &frame in &order[first..=last] {
                let Some(record) = self.record(frame).copied() else {
                    continue;
                };
                if record.flags & (IS_UNITS | IS_LIVE_COOLDOWN) == 0 {
                    continue;
                }
                if self.rect(frame).is_none() || self.effective_alpha(frame) <= 0.002 {
                    continue;
                }
                let decision = self.request(REQUEST_FRAME_AFTER, frame);
                self.slots.push(Slot {
                    is_before: false,
                    id: frame,
                    decision,
                    stamp: None,
                });
            }
            first = last + 1;
        }
        self.order = order;
        self.groups = groups;
        self.requests.len()
    }

    fn slot_before(
        &mut self,
        frame: u32,
        record: &ObjectRecord,
        rect: &Rect,
        alpha: f64,
        clip: Option<Rect>,
        store: &Store,
    ) {
        let flags = record.flags;
        if flags & HAS_MESSAGES != 0 || (flags & HAS_BACKDROP != 0 && self.is_transformed(frame)) {
            let decision = self.request(REQUEST_FRAME_BEFORE, frame);
            self.slots.push(Slot {
                is_before: true,
                id: frame,
                decision,
                stamp: None,
            });
            return;
        }
        if flags & HAS_BACKDROP == 0 {
            return;
        }
        // (a backdrop: kept while it, its place, alpha and clip stand)
        self.shape.clear();
        self.place.clear();
        self.shape.push(record.visual_version as f64);
        self.put_size(&Some(*rect));
        self.shape.push(alpha);
        self.put_relative(&clip, &Some(*rect));
        self.shape.push(self.screen_height);
        self.put_place(&Some(*rect));
        self.put_place(&clip);
        let kept = self.kept_before.get(frame as usize).and_then(|k| k.as_ref());
        let decision = match self.decide(kept, true, store) {
            Some(false) => Decision::Kept,
            Some(true) => Decision::Moved(Boxes {
                own: self.to_box(rect),
                clip: clip.map(|c| self.to_box(&c)),
                masks: Vec::new(),
            }),
            None => self.request(REQUEST_FRAME_BEFORE, frame),
        };
        let stamp = if matches!(decision, Decision::Kept) {
            None
        } else {
            self.stamp_copy()
        };
        self.slots.push(Slot {
            is_before: true,
            id: frame,
            decision,
            stamp,
        });
    }

    fn slot_region(&mut self, region: u32, owner: u32, store: &Store) {
        let Some(record) = self.record(region).copied() else {
            return;
        };
        let Some(owner_record) = self.record(owner).copied() else {
            return;
        };
        let Some(owner_rect) = self.rect(owner) else { return };
        let alpha = self.effective_alpha(owner);
        let clip = self.export_clip(owner);
        let mut shown = record.role == 0 || self.is_role_shown(&owner_record, owner, record.role);
        if record.flags & HIGHLIGHT_LAYER != 0 && record.role == 0 {
            shown = self.motion_focus == owner || owner_record.flags & HIGHLIGHT_LOCKED != 0;
        }
        if !shown {
            return;
        }
        let flattened = owner_record.flags & FLATTENS != 0 && alpha < 0.999;
        let region_alpha = (if flattened { 1.0 } else { alpha }) * self.own_alpha(region, &record);
        let stamped = self.stamp_region(
            region,
            &record,
            owner,
            &owner_record,
            &owner_rect,
            clip,
            flattened,
            alpha,
            region_alpha,
        );
        let (decision, stamp) = match stamped {
            Some((can_move, boxes)) => {
                let kept = self.kept_regions.get(region as usize).and_then(|k| k.as_ref());
                match self.decide(kept, can_move, store) {
                    Some(false) => (Decision::Kept, None),
                    Some(true) => (Decision::Moved(boxes), self.stamp_copy()),
                    None => (self.request(REQUEST_REGION, region), self.stamp_copy()),
                }
            }
            None => (self.request(REQUEST_REGION, region), None),
        };
        self.slots.push(Slot {
            is_before: false,
            id: region,
            decision,
            stamp,
        });
    }

    pub fn request_at(&self, index: usize) -> Option<(u32, u32)> {
        self.requests.get(index).copied()
    }

    /// An item the Lua side made for a request
    pub fn submit(&mut self, request: usize, key: u32, bytes: &[u8]) {
        if let Some(made) = self.made.get_mut(request) {
            made.push((key, bytes.to_vec()));
        }
    }

    /// The frame put together in the store: the slots in order, kept items by key, moved ones with their boxes, made
    /// ones with their bytes; the kept records brought up to date
    pub fn finish(&mut self, store: &mut Store) {
        store.begin();
        self.kept_count = 0;
        self.moved_count = 0;
        self.made_count = 0;
        self.dropped_count = 0;
        let slots = std::mem::take(&mut self.slots);
        for slot in slots {
            let kept_list = if slot.is_before {
                &mut self.kept_before
            } else {
                &mut self.kept_regions
            };
            grow(kept_list, slot.id);
            let entry = &mut kept_list[slot.id as usize];
            match slot.decision {
                Decision::Kept => {
                    self.kept_count += 1;
                    if let Some(kept) = entry {
                        for &key in &kept.keys {
                            if store.is_seen(key) {
                                self.dropped_count += 1;
                            } else {
                                store.same(key);
                            }
                        }
                    }
                }
                Decision::Moved(boxes) => {
                    self.moved_count += 1;
                    if let Some(kept) = entry {
                        if let Some((_, place)) = slot.stamp {
                            kept.place = place;
                        }
                        for &key in &kept.keys {
                            if store.is_seen(key) {
                                self.dropped_count += 1;
                            } else {
                                store.moved(key, boxes.clone());
                            }
                        }
                    }
                }
                Decision::Make(request) => {
                    self.made_count += 1;
                    let made = std::mem::take(&mut self.made[request]);
                    let mut keys = Vec::with_capacity(made.len());
                    for (key, bytes) in made {
                        if store.is_seen(key) {
                            self.dropped_count += 1;
                            continue;
                        }
                        store.item(key, &bytes);
                        keys.push(key);
                    }
                    *entry = slot.stamp.map(|(stamp, place)| Kept { stamp, place, keys });
                }
            }
        }
    }
}
