//! The scene stream's item store: what the page holds (every item's packed bytes, the boxes of those moved since, the
//! order), and the binary frames of what changed.
//!
//! The frame (little-endian), read by src/ui/engine/binaryFrame.ts:
//!   u8 kind (1: changes, 2: whole)
//!   u32 new keys, each: u32 id, u16 length, the key's bytes
//!   u8 order changed (0/1), then u32 count and the ids
//!   u32 items, each: u32 id, u32 length, the packed item
//!   u32 moves, each: u32 id, f64 x y w h, u8 clip (0/1) then f64 x y w h, u8 masks then f64 x y w h each
//!
//! An item's bytes are opaque here: the Lua side packs them (lua/pack.lua), the page unpacks them. Keys get ids from
//! 0 on, so everything about an item sits in vectors indexed by its id.

use std::collections::HashMap;

/// A moved item's boxes: its own, its clip's, its masks' (x, y, w, h each, as the page draws them)
#[derive(Clone, PartialEq, Debug, Default)]
pub struct Boxes {
    pub own: [f64; 4],
    pub clip: Option<[f64; 4]>,
    pub masks: Vec<[f64; 4]>,
}

#[derive(Default)]
pub struct Store {
    /// key bytes -> id, and id -> key bytes
    ids: HashMap<Vec<u8>, u32>,
    keys: Vec<Vec<u8>>,
    /// keys made since the last frame written: the page learns them with it
    new_keys: Vec<u32>,
    /// by id: the item's bytes as the page holds them (None: not held), the boxes it was moved to since, the frame it
    /// was last placed in
    items: Vec<Option<Vec<u8>>>,
    moved: Vec<Option<Boxes>>,
    seen: Vec<u64>,
    /// the order the page holds, and the one being made
    order: Vec<u32>,
    frame_order: Vec<u32>,
    /// this frame's changed items and moves
    changed: Vec<u32>,
    moves: Vec<u32>,
    /// the frame (or whole scene) last written, kept until the next is asked for
    out: Vec<u8>,
    frame: u64,
}

impl Store {
    pub fn intern(&mut self, key: &[u8]) -> u32 {
        if let Some(&id) = self.ids.get(key) {
            return id;
        }
        let id = self.keys.len() as u32;
        self.keys.push(key.to_vec());
        self.ids.insert(key.to_vec(), id);
        self.new_keys.push(id);
        self.items.push(None);
        self.moved.push(None);
        self.seen.push(0);
        id
    }

    pub fn begin(&mut self) {
        self.frame += 1;
        self.frame_order.clear();
        self.changed.clear();
        self.moves.clear();
    }

    /// Whether the page holds the item (an item no frame had since was let go)
    pub fn holds(&self, id: u32) -> bool {
        self.items.get(id as usize).is_some_and(|item| item.is_some())
    }

    /// Whether the item was already placed in this frame (a second item of one key is not drawn)
    pub fn is_seen(&self, id: u32) -> bool {
        self.seen.get(id as usize) == Some(&self.frame)
    }

    fn see(&mut self, id: u32) {
        self.frame_order.push(id);
        self.seen[id as usize] = self.frame;
    }

    /// An item made this frame: changed when its bytes differ from the page's (or it had been moved)
    pub fn item(&mut self, id: u32, bytes: &[u8]) {
        self.see(id);
        let at = id as usize;
        let is_same = self.items[at].as_deref() == Some(bytes) && self.moved[at].is_none();
        if !is_same {
            self.items[at] = Some(bytes.to_vec());
            self.moved[at] = None;
            self.changed.push(id);
        }
    }

    /// A kept item, as the page holds it
    pub fn same(&mut self, id: u32) {
        self.see(id);
    }

    /// A kept item given new boxes
    pub fn moved(&mut self, id: u32, boxes: Boxes) {
        self.see(id);
        let at = id as usize;
        if self.moved[at].as_ref() != Some(&boxes) {
            self.moved[at] = Some(boxes);
            self.moves.push(id);
        }
    }

    /// Ends the frame: the binary frame of what changed, or None when nothing did
    pub fn end(&mut self) -> Option<&[u8]> {
        // (those the page held that this frame did not place are let go)
        let frame = self.frame;
        for index in 0..self.order.len() {
            let at = self.order[index] as usize;
            if self.seen[at] != frame {
                self.items[at] = None;
                self.moved[at] = None;
            }
        }
        let is_order_changed = self.frame_order != self.order;
        if !is_order_changed && self.changed.is_empty() && self.moves.is_empty() {
            return None;
        }
        self.out.clear();
        self.out.push(1);
        let new_keys = std::mem::take(&mut self.new_keys);
        self.write_keys(&new_keys);
        if is_order_changed {
            let order = std::mem::take(&mut self.frame_order);
            self.write_order(&order);
            self.frame_order = std::mem::replace(&mut self.order, order);
        } else {
            self.out.push(0);
        }
        let changed = std::mem::take(&mut self.changed);
        self.write_items(&changed);
        self.changed = changed;
        let moves = std::mem::take(&mut self.moves);
        self.write_moves(&moves);
        self.moves = moves;
        Some(&self.out)
    }

    /// The whole scene the page should hold: every key, the order, every item, the boxes of those moved since
    pub fn whole(&mut self) -> &[u8] {
        self.out.clear();
        self.out.push(2);
        let all: Vec<u32> = (0..self.keys.len() as u32).collect();
        self.write_keys(&all);
        self.new_keys.clear();
        let order = std::mem::take(&mut self.order);
        self.write_order(&order);
        self.write_items(&order);
        self.write_moves(&order);
        self.order = order;
        &self.out
    }

    fn write_keys(&mut self, ids: &[u32]) {
        put_u32(&mut self.out, ids.len() as u32);
        for &id in ids {
            let key = &self.keys[id as usize];
            put_u32(&mut self.out, id);
            put_u16(&mut self.out, key.len() as u16);
            self.out.extend_from_slice(key);
        }
    }

    fn write_order(&mut self, order: &[u32]) {
        self.out.push(1);
        put_u32(&mut self.out, order.len() as u32);
        for &id in order {
            put_u32(&mut self.out, id);
        }
    }

    fn write_items(&mut self, ids: &[u32]) {
        put_u32(&mut self.out, ids.len() as u32);
        for &id in ids {
            let bytes = self.items[id as usize].as_deref().unwrap_or(&[]);
            put_u32(&mut self.out, id);
            put_u32(&mut self.out, bytes.len() as u32);
            self.out.extend_from_slice(bytes);
        }
    }

    /// The moves among these ids (those moved since they were made)
    fn write_moves(&mut self, ids: &[u32]) {
        let count = ids.iter().filter(|&&id| self.moved[id as usize].is_some()).count();
        put_u32(&mut self.out, count as u32);
        for &id in ids {
            let Some(boxes) = &self.moved[id as usize] else {
                continue;
            };
            put_u32(&mut self.out, id);
            put_box(&mut self.out, &boxes.own);
            match boxes.clip {
                Some(clip) => {
                    self.out.push(1);
                    put_box(&mut self.out, &clip);
                }
                None => self.out.push(0),
            }
            self.out.push(boxes.masks.len() as u8);
            for mask in &boxes.masks {
                put_box(&mut self.out, mask);
            }
        }
    }
}

fn put_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_le_bytes());
}
fn put_u32(out: &mut Vec<u8>, value: u32) {
    out.extend_from_slice(&value.to_le_bytes());
}
fn put_box(out: &mut Vec<u8>, value: &[f64; 4]) {
    for part in value {
        out.extend_from_slice(&part.to_le_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::{Boxes, Store};

    #[test]
    fn nothing_changed_writes_no_frame() {
        let mut store = Store::default();
        let id = store.intern(b"a");
        store.begin();
        store.item(id, &[1, 2, 3]);
        assert!(store.end().is_some());
        store.begin();
        store.item(id, &[1, 2, 3]);
        assert!(store.end().is_none());
        store.begin();
        store.same(id);
        assert!(store.end().is_none());
    }

    #[test]
    fn a_frame_carries_new_keys_order_items_and_moves() {
        let mut store = Store::default();
        let a = store.intern(b"a");
        let b = store.intern(b"bb");
        store.begin();
        store.item(a, &[7]);
        store.moved(
            b,
            Boxes {
                own: [1.0, 2.0, 3.0, 4.0],
                clip: None,
                masks: vec![],
            },
        );
        let frame = store.end().unwrap().to_vec();
        assert_eq!(frame[0], 1); // changes
        assert_eq!(u32::from_le_bytes(frame[1..5].try_into().unwrap()), 2); // two new keys
                                                                            // after the keys (4+2+1 and 4+2+2 bytes): the order, both ids
        let order_at = 5 + 7 + 8;
        assert_eq!(frame[order_at], 1);
        assert_eq!(
            u32::from_le_bytes(frame[order_at + 1..order_at + 5].try_into().unwrap()),
            2
        );
        let items_at = order_at + 5 + 8;
        assert_eq!(u32::from_le_bytes(frame[items_at..items_at + 4].try_into().unwrap()), 1);
        let moves_at = items_at + 4 + 4 + 4 + 1;
        assert_eq!(u32::from_le_bytes(frame[moves_at..moves_at + 4].try_into().unwrap()), 1);
        assert_eq!(frame.len(), moves_at + 4 + 4 + 32 + 1 + 1);
    }

    #[test]
    fn items_left_out_are_let_go() {
        let mut store = Store::default();
        let a = store.intern(b"a");
        let b = store.intern(b"b");
        store.begin();
        store.item(a, &[1]);
        store.item(b, &[2]);
        store.end();
        assert!(store.holds(b));
        store.begin();
        store.same(a);
        assert!(store.end().is_some()); // (the order changed)
        assert!(store.holds(a));
        assert!(!store.holds(b));
    }

    #[test]
    fn the_whole_scene_holds_every_item() {
        let mut store = Store::default();
        let a = store.intern(b"a");
        store.begin();
        store.item(a, &[9, 9]);
        store.end();
        let whole = store.whole().to_vec();
        assert_eq!(whole[0], 2);
        assert!(whole.ends_with(&[9, 9, 0, 0, 0, 0]));
    }
}
