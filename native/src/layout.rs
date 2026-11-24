//! The widgets' layout in Rust, for the scene's walk: each object's rectangle from its anchors, size, scale and
//! content, ported rule for rule from lua/widgets.lua's computeRect, getNaturalSize and getEffectiveScale (the game's
//! own layout stays the Lua one: what addons ask, GetRect and the like, is answered there). Rectangles are worked out
//! when the walk asks and kept until what they come from changes: an object's anchors, size, scale or parent, or one
//! they are worked out from (each records whose rectangle it fed, its dependents). A text's size is measured by the Lua
//! side (lua/fonts.lua, through a callback) and kept until its text or the font objects change.
//! ADDONSIM_CHECK_SCENE=1 compares these rectangles with the Lua ones.

use crate::graph::{
    grow, Graph, ObjectRecord, Rect, CLAMPED, COLLAPSES_LAYOUT, FONT_STRING, FRAME, HAS_ATLAS_SIZE,
    IGNORE_PARENT_SCALE, IS_ROOT, MADE_BY_CODE, SHOWN, TEXTURE,
};

/// What the Lua side measures: 1 a text's width, 2 its height (for a width, or NaN for none)
pub type Measure = extern "C" fn(id: u32, kind: i32, width: f64) -> f64;
const MEASURE_WIDTH: i32 = 1;
const MEASURE_HEIGHT: i32 = 2;

/// A text's measurements, kept while its text (its visual version) and the font objects stand
#[derive(Clone, Default)]
struct TextSizes {
    version: u32,
    fonts: f64,
    width: Option<f64>,
    heights: Vec<(u64, f64)>,
}

#[derive(Default)]
pub struct Layout {
    /// the number of the layout as a whole: a rectangle or scale kept under another number is worked out again
    generation: u64,
    rect_valid: Vec<u64>,
    rects: Vec<Option<Rect>>,
    scale_valid: Vec<u64>,
    scales: Vec<f64>,
    /// [object] = those whose rectangles were worked out from its (its anchors' others, its children)
    dependents: Vec<Vec<u32>>,
    computing: Vec<bool>,
    texts: Vec<TextSizes>,
    pub measure: Option<Measure>,
}

// The anchor points: TOPLEFT 1, TOP 2, TOPRIGHT 3, LEFT 4, CENTER 5, RIGHT 6, BOTTOMLEFT 7, BOTTOM 8, BOTTOMRIGHT 9
// (their number is also their rank: the lower wins an edge two anchors give)
fn point_x(point: u8) -> Option<f64> {
    match point {
        1 | 4 | 7 => Some(0.0),
        3 | 6 | 9 => Some(1.0),
        2 | 5 | 8 => Some(0.5),
        _ => None,
    }
}
fn point_y(point: u8) -> Option<f64> {
    match point {
        1..=3 => Some(1.0),
        7..=9 => Some(0.0),
        4..=6 => Some(0.5),
        _ => None,
    }
}
fn point_rank(point: u8) -> u32 {
    if (1..=9).contains(&point) {
        point as u32
    } else {
        9
    }
}

impl Graph {
    fn layout_generation(&mut self) -> u64 {
        if self.layout.generation == 0 {
            self.layout.generation = 1;
        }
        self.layout.generation
    }

    /// Every rectangle and scale to be worked out again (the screen or the font objects changed)
    pub(crate) fn invalidate_all(&mut self) {
        self.layout.generation = self.layout_generation() + 1;
        for list in &mut self.layout.dependents {
            list.clear();
        }
    }

    /// An object's rectangle to be worked out again, and those worked out from it
    pub(crate) fn invalidate(&mut self, id: u32) {
        let at = id as usize;
        if let Some(valid) = self.layout.rect_valid.get_mut(at) {
            *valid = 0;
        }
        let dependents = match self.layout.dependents.get_mut(at) {
            Some(list) if !list.is_empty() => std::mem::take(list),
            _ => return,
        };
        for dependent in dependents {
            self.invalidate(dependent);
        }
    }

    /// An object's scale changed (or its parent): its and everything it holds, scales and rectangles
    fn invalidate_scale(&mut self, id: u32) {
        if let Some(valid) = self.layout.scale_valid.get_mut(id as usize) {
            *valid = 0;
        }
        self.invalidate(id);
        let (children, regions) = match self.objects.get(id as usize) {
            Some(object) => (object.children.clone(), object.regions.clone()),
            None => return,
        };
        for child in children.into_iter().chain(regions) {
            self.invalidate_scale(child);
        }
    }

    /// A new record against the old one: what of the layout it changes
    pub(crate) fn layout_changed(&mut self, id: u32, old: &ObjectRecord, new: &ObjectRecord) {
        const SCALE_FLAGS: u32 = IGNORE_PARENT_SCALE | IS_ROOT;
        if old.scale != new.scale || old.parent != new.parent || (old.flags ^ new.flags) & SCALE_FLAGS != 0 {
            self.invalidate_scale(id);
            return;
        }
        const LAYOUT_FLAGS: u32 = MADE_BY_CODE | COLLAPSES_LAYOUT | CLAMPED | HAS_ATLAS_SIZE;
        let collapses = new.flags & COLLAPSES_LAYOUT != 0 && (old.flags ^ new.flags) & SHOWN != 0;
        let text = new.kind == FONT_STRING && old.visual_version != new.visual_version;
        if old.width != new.width
            || old.height != new.height
            || old.atlas_width != new.atlas_width
            || old.atlas_height != new.atlas_height
            || old.scroll_x != new.scroll_x
            || old.scroll_y != new.scroll_y
            || old.kind != new.kind
            || old.scroll_child_of != new.scroll_child_of
            || (old.flags ^ new.flags) & LAYOUT_FLAGS != 0
            || collapses
            || text
        {
            self.invalidate(id);
        }
    }

    fn add_dependent(&mut self, source: u32, object: u32) {
        grow(&mut self.layout.dependents, source);
        let list = &mut self.layout.dependents[source as usize];
        if !list.contains(&object) {
            list.push(object);
        }
    }

    /// The scale the object is drawn at, against the screen
    pub(crate) fn effective_scale(&mut self, id: u32) -> f64 {
        let generation = self.layout_generation();
        if self.layout.scale_valid.get(id as usize) == Some(&generation) {
            return self.layout.scales[id as usize];
        }
        let Some(record) = self.record(id).copied() else {
            return 1.0;
        };
        let result = if record.flags & IS_ROOT != 0 {
            record.scale
        } else {
            let parent_scale = if record.parent != 0 && record.flags & IGNORE_PARENT_SCALE == 0 {
                self.effective_scale(record.parent)
            } else {
                1.0
            };
            record.scale * parent_scale
        };
        grow(&mut self.layout.scale_valid, id);
        grow(&mut self.layout.scales, id);
        self.layout.scale_valid[id as usize] = generation;
        self.layout.scales[id as usize] = result;
        result
    }

    /// A text's measurement by the Lua side, kept while its text and the font objects stand
    fn measure(&mut self, id: u32, kind: i32, width: Option<f64>) -> f64 {
        let version = self.record(id).map(|r| r.visual_version).unwrap_or(0);
        let fonts = self.fonts_version;
        grow(&mut self.layout.texts, id);
        let sizes = &mut self.layout.texts[id as usize];
        if sizes.version != version || sizes.fonts != fonts {
            *sizes = TextSizes {
                version,
                fonts,
                width: None,
                heights: Vec::new(),
            };
        }
        let Some(measure) = self.layout.measure else { return 0.0 };
        if kind == MEASURE_WIDTH {
            if let Some(known) = sizes.width {
                return known;
            }
            let measured = measure(id, MEASURE_WIDTH, f64::NAN);
            self.layout.texts[id as usize].width = Some(measured);
            return measured;
        }
        let key = width.map(|w| w.to_bits()).unwrap_or(u64::MAX);
        if let Some(&(_, known)) = sizes.heights.iter().find(|(k, _)| *k == key) {
            return known;
        }
        let measured = measure(id, MEASURE_HEIGHT, width.unwrap_or(f64::NAN));
        let heights = &mut self.layout.texts[id as usize].heights;
        if heights.len() >= 4 {
            heights.remove(0);
        }
        heights.push((key, measured));
        measured
    }

    /// The size an object takes when its anchors do not give one: set, its text's, its atlas's
    fn natural_size(&mut self, id: u32, record: &ObjectRecord) -> (f64, f64) {
        if record.flags & COLLAPSES_LAYOUT != 0 && record.flags & SHOWN == 0 {
            return (0.0, 0.0);
        }
        let scale = self.effective_scale(id);
        if record.kind == FONT_STRING && record.width == 0.0 {
            let width = self.measure(id, MEASURE_WIDTH, None);
            let height = if record.height > 0.0 {
                record.height
            } else {
                self.measure(id, MEASURE_HEIGHT, None)
            };
            return (width * scale, height * scale);
        }
        if record.kind == FONT_STRING && record.height == 0.0 {
            let height = self.measure(id, MEASURE_HEIGHT, Some(record.width));
            return (record.width * scale, height * scale);
        }
        if record.width == 0.0 && record.height == 0.0 && record.flags & HAS_ATLAS_SIZE != 0 {
            return (record.atlas_width * scale, record.atlas_height * scale);
        }
        (record.width * scale, record.height * scale)
    }

    /// An object's rectangle (left, bottom, right, top; y up), as lua/widgets.lua's computeRect works it out
    pub(crate) fn layout_rect(&mut self, id: u32) -> Option<Rect> {
        let generation = self.layout_generation();
        let at = id as usize;
        if self.layout.rect_valid.get(at) == Some(&generation) {
            return self.layout.rects[at];
        }
        let record = self.record(id).copied()?;
        let rect = self.compute_rect(id, &record);
        grow(&mut self.layout.rect_valid, id);
        grow(&mut self.layout.rects, id);
        self.layout.rect_valid[at] = generation;
        self.layout.rects[at] = rect;
        rect
    }

    fn compute_rect(&mut self, id: u32, record: &ObjectRecord) -> Option<Rect> {
        let points = self
            .objects
            .get(id as usize)
            .map(|o| o.points.clone())
            .unwrap_or_default();
        // A texture an addon's code makes has no place until it is given points
        if record.flags & MADE_BY_CODE != 0 && points.is_empty() {
            return None;
        }
        if record.flags & IS_ROOT != 0 {
            return Some([0.0, 0.0, self.screen_width, self.screen_height]);
        }
        grow(&mut self.layout.computing, id);
        if self.layout.computing[id as usize] {
            return None; // (anchored in a circle)
        }
        self.layout.computing[id as usize] = true;
        let rect = self.compute_rect_inner(id, record, &points);
        self.layout.computing[id as usize] = false;
        rect
    }

    fn compute_rect_inner(&mut self, id: u32, record: &ObjectRecord, points: &[crate::graph::Point]) -> Option<Rect> {
        let scale = self.effective_scale(id);
        let (mut left, mut right, mut center_x) = (None::<f64>, None::<f64>, None::<f64>);
        let (mut bottom, mut top, mut center_y) = (None::<f64>, None::<f64>, None::<f64>);
        let (mut left_rank, mut right_rank, mut center_x_rank) = (99, 99, 99);
        let (mut bottom_rank, mut top_rank, mut center_y_rank) = (99, 99, 99);
        let scroll_frame = record.scroll_child_of;
        if scroll_frame != 0 {
            // A scroll frame's child hangs from its top left, moved by the scroll
            let frame_rect = self.layout_rect(scroll_frame);
            self.add_dependent(scroll_frame, id);
            let (scroll_x, scroll_y) = self
                .record(scroll_frame)
                .map(|r| (r.scroll_x, r.scroll_y))
                .unwrap_or((0.0, 0.0));
            if let Some(frame_rect) = frame_rect {
                left = Some(frame_rect[0] - scroll_x * scale);
                top = Some(frame_rect[3] + scroll_y * scale);
            }
        }
        // (the scroll frame alone places its child: the child's own anchors are not used)
        let anchors: &[crate::graph::Point] = if scroll_frame != 0 && left.is_some() {
            &[]
        } else {
            points
        };
        for anchor in anchors {
            let relative_rect = if anchor.relative != 0 {
                self.layout_rect(anchor.relative)
            } else {
                None
            };
            if anchor.relative != 0 {
                self.add_dependent(anchor.relative, id);
            }
            let Some(relative) = relative_rect else { continue };
            let (Some(relative_x), Some(relative_y)) = (point_x(anchor.relative_point), point_y(anchor.relative_point))
            else {
                continue;
            };
            let x = relative[0] + (relative[2] - relative[0]) * relative_x + anchor.x * scale;
            let y = relative[1] + (relative[3] - relative[1]) * relative_y + anchor.y * scale;
            let rank = point_rank(anchor.point);
            match point_x(anchor.point) {
                Some(0.0) => {
                    if rank < left_rank {
                        left = Some(x);
                        left_rank = rank;
                    }
                }
                Some(1.0) => {
                    if rank < right_rank {
                        right = Some(x);
                        right_rank = rank;
                    }
                }
                _ => {
                    if rank < center_x_rank {
                        center_x = Some(x);
                        center_x_rank = rank;
                    }
                }
            }
            match point_y(anchor.point) {
                Some(0.0) => {
                    if rank < bottom_rank {
                        bottom = Some(y);
                        bottom_rank = rank;
                    }
                }
                Some(1.0) => {
                    if rank < top_rank {
                        top = Some(y);
                        top_rank = rank;
                    }
                }
                _ => {
                    if rank < center_y_rank {
                        center_y = Some(y);
                        center_y_rank = rank;
                    }
                }
            }
        }
        // A texture or text given no anchors is drawn on its parent: centred at its own size, or over the whole parent
        if points.is_empty()
            && scroll_frame == 0
            && record.parent != 0
            && (record.kind == TEXTURE || record.kind == FONT_STRING)
        {
            let parent_rect = self.layout_rect(record.parent);
            self.add_dependent(record.parent, id);
            if let Some(parent) = parent_rect {
                let (width, height) = (record.width * scale, record.height * scale);
                if width > 0.0 && height > 0.0 {
                    center_x = Some((parent[0] + parent[2]) / 2.0);
                    center_y = Some((parent[1] + parent[3]) / 2.0);
                } else {
                    left = Some(parent[0]);
                    bottom = Some(parent[1]);
                    right = Some(parent[2]);
                    top = Some(parent[3]);
                }
            }
        }
        let has_horizontal = left.is_some() || right.is_some() || center_x.is_some();
        let has_vertical = top.is_some() || bottom.is_some() || center_y.is_some();
        if !(has_horizontal && has_vertical) {
            return None;
        }
        let mut natural: Option<(f64, f64)> = None;
        if left.is_none() || right.is_none() {
            let (width, _) = *natural.get_or_insert_with(|| self.natural_size(id, record));
            if let Some(l) = left {
                right = Some(l + width);
            } else if let Some(r) = right {
                left = Some(r - width);
            } else {
                let c = center_x.unwrap_or(0.0);
                left = Some(c - width / 2.0);
                right = Some(c + width / 2.0);
            }
        }
        let (left, right) = (left.unwrap_or(0.0), right.unwrap_or(0.0));
        if top.is_none() || bottom.is_none() {
            let height = if record.kind == FONT_STRING && record.height <= 0.0 {
                self.measure(id, MEASURE_HEIGHT, Some((right - left) / scale)) * scale
            } else {
                match natural {
                    Some((_, height)) => height,
                    None => self.natural_size(id, record).1,
                }
            };
            if let Some(t) = top {
                bottom = Some(t - height);
            } else if let Some(b) = bottom {
                top = Some(b + height);
            } else {
                let c = center_y.unwrap_or(0.0);
                bottom = Some(c - height / 2.0);
                top = Some(c + height / 2.0);
            }
        }
        let (bottom, top) = (bottom.unwrap_or(0.0), top.unwrap_or(0.0));
        let mut rect = [left, bottom, right, top];
        // Kept on the screen when clamped: moved down whole rather than cut off
        if record.flags & CLAMPED != 0 && record.kind == FRAME {
            let (mut dx, mut dy) = (0.0, 0.0);
            if right > self.screen_width {
                dx = self.screen_width - right;
            }
            if left + dx < 0.0 {
                dx = -left;
            }
            if top > self.screen_height {
                dy = self.screen_height - top;
            }
            if bottom + dy < 0.0 && top - bottom <= self.screen_height {
                dy = -bottom;
            }
            if dx != 0.0 || dy != 0.0 {
                rect = [left + dx, bottom + dy, right + dx, top + dy];
            }
        }
        Some(rect)
    }
}

#[cfg(test)]
mod tests {
    use crate::graph::{
        Graph, ObjectRecord, Point, CLAMPED, FONT_STRING, FRAME, HAS_ATLAS_SIZE, IS_ROOT, SHOWN, TEXTURE,
    };

    const TOPLEFT: u8 = 1;
    const CENTER: u8 = 5;
    const BOTTOMRIGHT: u8 = 9;

    fn graph() -> Graph {
        let mut graph = Graph::default();
        graph.set_globals(0, 0, 0, 1.0, 1000.0, 500.0);
        graph.set_object(&ObjectRecord {
            id: 1,
            kind: FRAME,
            flags: IS_ROOT | SHOWN,
            scale: 1.0,
            ..Default::default()
        });
        graph
    }

    fn frame(graph: &mut Graph, id: u32, parent: u32, width: f64, height: f64) {
        let record = ObjectRecord {
            id,
            parent,
            kind: FRAME,
            flags: SHOWN,
            scale: 1.0,
            width,
            height,
            ..Default::default()
        };
        graph.set_object(&record);
    }

    fn point(point: u8, relative: u32, relative_point: u8, x: f64, y: f64) -> Point {
        Point {
            relative,
            point,
            relative_point,
            pad: [0; 2],
            x,
            y,
        }
    }

    #[test]
    fn the_root_is_the_screen() {
        let mut graph = graph();
        assert_eq!(graph.layout_rect(1), Some([0.0, 0.0, 1000.0, 500.0]));
    }

    #[test]
    fn one_anchor_and_a_size() {
        let mut graph = graph();
        frame(&mut graph, 2, 1, 100.0, 50.0);
        graph.set_points(2, &[point(TOPLEFT, 1, TOPLEFT, 10.0, -20.0)]);
        assert_eq!(graph.layout_rect(2), Some([10.0, 430.0, 110.0, 480.0]));
    }

    #[test]
    fn no_anchors_no_place() {
        let mut graph = graph();
        frame(&mut graph, 2, 1, 100.0, 50.0);
        assert_eq!(graph.layout_rect(2), None);
    }

    #[test]
    fn two_anchors_set_the_size() {
        let mut graph = graph();
        frame(&mut graph, 2, 1, 5.0, 5.0);
        graph.set_points(
            2,
            &[
                point(TOPLEFT, 1, TOPLEFT, 10.0, -10.0),
                point(BOTTOMRIGHT, 1, BOTTOMRIGHT, -10.0, 10.0),
            ],
        );
        assert_eq!(graph.layout_rect(2), Some([10.0, 10.0, 990.0, 490.0]));
    }

    #[test]
    fn the_scale_shrinks_size_and_offsets() {
        let mut graph = graph();
        let record = ObjectRecord {
            id: 2,
            parent: 1,
            kind: FRAME,
            flags: SHOWN,
            scale: 0.5,
            width: 100.0,
            height: 100.0,
            ..Default::default()
        };
        graph.set_object(&record);
        graph.set_points(2, &[point(CENTER, 1, CENTER, 20.0, 0.0)]);
        assert_eq!(graph.layout_rect(2), Some([485.0, 225.0, 535.0, 275.0]));
    }

    #[test]
    fn a_moved_anchor_moves_its_dependents() {
        let mut graph = graph();
        frame(&mut graph, 2, 1, 100.0, 100.0);
        frame(&mut graph, 3, 2, 10.0, 10.0);
        graph.set_points(2, &[point(TOPLEFT, 1, TOPLEFT, 0.0, 0.0)]);
        graph.set_points(3, &[point(TOPLEFT, 2, TOPLEFT, 5.0, -5.0)]);
        assert_eq!(graph.layout_rect(3), Some([5.0, 485.0, 15.0, 495.0]));
        graph.set_points(2, &[point(TOPLEFT, 1, TOPLEFT, 100.0, -100.0)]);
        assert_eq!(graph.layout_rect(3), Some([105.0, 385.0, 115.0, 395.0]));
    }

    #[test]
    fn a_clamped_frame_stays_on_the_screen() {
        let mut graph = graph();
        let record = ObjectRecord {
            id: 2,
            parent: 1,
            kind: FRAME,
            flags: SHOWN | CLAMPED,
            scale: 1.0,
            width: 100.0,
            height: 100.0,
            ..Default::default()
        };
        graph.set_object(&record);
        graph.set_points(2, &[point(TOPLEFT, 1, TOPLEFT, 950.0, 50.0)]);
        assert_eq!(graph.layout_rect(2), Some([900.0, 400.0, 1000.0, 500.0]));
    }

    #[test]
    fn a_texture_without_anchors_fills_its_parent() {
        let mut graph = graph();
        frame(&mut graph, 2, 1, 100.0, 100.0);
        graph.set_points(2, &[point(TOPLEFT, 1, TOPLEFT, 0.0, 0.0)]);
        graph.set_object(&ObjectRecord {
            id: 3,
            parent: 2,
            kind: TEXTURE,
            flags: SHOWN,
            scale: 1.0,
            ..Default::default()
        });
        assert_eq!(graph.layout_rect(3), Some([0.0, 400.0, 100.0, 500.0]));
    }

    #[test]
    fn an_atlas_sizes_a_texture() {
        let mut graph = graph();
        let record = ObjectRecord {
            id: 2,
            parent: 1,
            kind: TEXTURE,
            flags: SHOWN | HAS_ATLAS_SIZE,
            scale: 1.0,
            atlas_width: 32.0,
            atlas_height: 16.0,
            ..Default::default()
        };
        graph.set_object(&record);
        graph.set_points(2, &[point(CENTER, 1, CENTER, 0.0, 0.0)]);
        assert_eq!(graph.layout_rect(2), Some([484.0, 242.0, 516.0, 258.0]));
    }

    #[test]
    fn a_scroll_child_hangs_from_its_frame_moved_by_the_scroll() {
        let mut graph = graph();
        frame(&mut graph, 2, 1, 100.0, 100.0);
        graph.set_points(2, &[point(TOPLEFT, 1, TOPLEFT, 0.0, 0.0)]);
        graph.set_object(&ObjectRecord {
            id: 3,
            parent: 2,
            scroll_child_of: 2,
            kind: FRAME,
            flags: SHOWN,
            scale: 1.0,
            width: 100.0,
            height: 300.0,
            ..Default::default()
        });
        assert_eq!(graph.layout_rect(3), Some([0.0, 200.0, 100.0, 500.0]));
        let scrolled = ObjectRecord {
            id: 2,
            parent: 1,
            kind: FRAME,
            flags: SHOWN,
            scale: 1.0,
            width: 100.0,
            height: 100.0,
            scroll_y: 40.0,
            ..Default::default()
        };
        graph.set_object(&scrolled);
        assert_eq!(graph.layout_rect(3), Some([0.0, 240.0, 100.0, 540.0]));
    }

    extern "C" fn measure(_id: u32, kind: i32, _width: f64) -> f64 {
        if kind == 1 {
            42.0
        } else {
            12.0
        }
    }

    #[test]
    fn a_text_takes_its_measured_size() {
        let mut graph = graph();
        graph.layout.measure = Some(measure);
        graph.set_object(&ObjectRecord {
            id: 2,
            parent: 1,
            kind: FONT_STRING,
            flags: SHOWN,
            scale: 1.0,
            ..Default::default()
        });
        graph.set_points(2, &[point(TOPLEFT, 1, TOPLEFT, 0.0, 0.0)]);
        assert_eq!(graph.layout_rect(2), Some([0.0, 488.0, 42.0, 500.0]));
    }

    #[test]
    fn anchors_in_a_circle_have_no_place() {
        let mut graph = graph();
        frame(&mut graph, 2, 1, 10.0, 10.0);
        frame(&mut graph, 3, 1, 10.0, 10.0);
        graph.set_points(2, &[point(TOPLEFT, 3, TOPLEFT, 0.0, 0.0)]);
        graph.set_points(3, &[point(TOPLEFT, 2, TOPLEFT, 0.0, 0.0)]);
        assert_eq!(graph.layout_rect(2), None);
    }
}
