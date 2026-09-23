//! How a tab is divided into panes.
//!
//! A tab holds a binary tree: every leaf is a pane, every branch splits its
//! area in two. Splitting the focused pane replaces that leaf with a branch
//! holding the old pane and a new one, which is what lets a layout grow in any
//! shape rather than only in rows or only in columns.
//!
//! This file is pure geometry and bookkeeping — no pty, no terminal, no
//! drawing — so the layout can be checked exactly, at sizes and in shapes that
//! would be tedious to reach by hand.

const std = @import("std");

/// Panes per tab. Eight is already more than fits a screen legibly, and the
/// fixed bound keeps the tree in the tab rather than on the heap.
pub const MAX_PANES: usize = 8;
const MAX_NODES: usize = MAX_PANES * 2 - 1;

/// The cells a pane is never shrunk below. A pane narrower than this cannot
/// show a prompt, so a split that would produce one is refused instead.
pub const MIN_COLS: u32 = 20;
pub const MIN_ROWS: u32 = 3;

/// The gap between siblings, where the divider is drawn.
pub const GAP: u32 = 1;

pub const Dir = enum {
    /// Side by side: the area is divided along its width.
    horizontal,
    /// Stacked: the area is divided along its height.
    vertical,
};

pub const Side = enum { left, right, up, down };

/// A rectangle in terminal cells.
pub const Rect = struct {
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    pub fn isEmpty(self: Rect) bool {
        return self.w == 0 or self.h == 0;
    }

    pub fn contains(self: Rect, x: u32, y: u32) bool {
        return x >= self.x and x < self.x + self.w and
            y >= self.y and y < self.y + self.h;
    }
};

const Node = union(enum) {
    /// An unused slot in the node pool.
    free,
    /// A pane, identified by its slot in the tab's pane array.
    leaf: u8,
    branch: struct {
        dir: Dir,
        first: u8,
        second: u8,
        /// Share of the area the first child gets.
        ratio: f32,
    },
};

pub const Error = error{ TooManyPanes, NoRoom };

pub const Tree = struct {
    nodes: [MAX_NODES]Node = @splat(.free),
    parent: [MAX_NODES]u8 = @splat(NONE),
    root: u8 = 0,
    /// Which pane ids are in use.
    used: [MAX_PANES]bool = @splat(false),

    const NONE: u8 = 0xFF;

    /// A tab starts as a single pane holding id 0.
    pub fn single() Tree {
        var t = Tree{};
        t.nodes[0] = .{ .leaf = 0 };
        t.used[0] = true;
        t.root = 0;
        return t;
    }

    pub fn count(self: *const Tree) usize {
        var n: usize = 0;
        for (self.used) |u| {
            if (u) n += 1;
        }
        return n;
    }

    fn freeNode(self: *Tree) ?u8 {
        for (&self.nodes, 0..) |*node, i| {
            if (node.* == .free) return @intCast(i);
        }
        return null;
    }

    fn freePane(self: *Tree) ?u8 {
        for (self.used, 0..) |u, i| {
            if (!u) return @intCast(i);
        }
        return null;
    }

    fn findLeaf(self: *const Tree, pane: u8) ?u8 {
        for (self.nodes, 0..) |node, i| {
            if (node == .leaf and node.leaf == pane) return @intCast(i);
        }
        return null;
    }

    /// Splits `pane` in `dir`, returning the id of the pane created.
    ///
    /// Refused when the tab is full, or when the halves would be too small to
    /// be usable — better to leave the layout alone than to produce a pane
    /// nothing can be read in. `area` is the tab's whole area in cells.
    pub fn split(self: *Tree, pane: u8, dir: Dir, area: Rect) Error!u8 {
        if (self.count() >= MAX_PANES) return error.TooManyPanes;

        var rects: [MAX_PANES]Rect = @splat(.{});
        self.layout(area, &rects);
        const current = rects[pane];
        const halved = halve(current, dir, 0.5);
        if (!fits(halved.first) or !fits(halved.second)) return error.NoRoom;

        const leaf = self.findLeaf(pane) orelse return error.NoRoom;
        const new_pane = self.freePane() orelse return error.TooManyPanes;

        // The old leaf moves down into the branch, so the branch can take its
        // place without anything above it having to be rewritten.
        const moved = self.freeNode() orelse return error.TooManyPanes;
        self.nodes[moved] = .{ .leaf = pane };
        const added = self.freeNode() orelse return error.TooManyPanes;
        self.nodes[added] = .{ .leaf = new_pane };

        self.nodes[leaf] = .{ .branch = .{
            .dir = dir,
            .first = moved,
            .second = added,
            .ratio = 0.5,
        } };
        self.parent[moved] = leaf;
        self.parent[added] = leaf;
        self.used[new_pane] = true;
        return new_pane;
    }

    /// Removes a pane. Its sibling takes over the space.
    ///
    /// Returns the pane focus should move to, or null when that was the last
    /// one and the tab itself is finished.
    pub fn close(self: *Tree, pane: u8) ?u8 {
        const leaf = self.findLeaf(pane) orelse return null;
        self.used[pane] = false;

        const parent = self.parent[leaf];
        if (parent == NONE) {
            // The root pane: nothing is left.
            self.nodes[leaf] = .free;
            return null;
        }

        const branch = self.nodes[parent].branch;
        const sibling = if (branch.first == leaf) branch.second else branch.first;

        // The sibling is lifted into the parent's place, which keeps the tree
        // free of branches with one child.
        self.nodes[parent] = self.nodes[sibling];
        if (self.nodes[parent] == .branch) {
            self.parent[self.nodes[parent].branch.first] = parent;
            self.parent[self.nodes[parent].branch.second] = parent;
        }
        self.nodes[sibling] = .free;
        self.nodes[leaf] = .free;
        self.parent[sibling] = NONE;
        self.parent[leaf] = NONE;

        return self.firstPane(parent);
    }

    fn firstPane(self: *const Tree, node: u8) ?u8 {
        return switch (self.nodes[node]) {
            .free => null,
            .leaf => |p| p,
            .branch => |b| self.firstPane(b.first) orelse self.firstPane(b.second),
        };
    }

    /// Fills `out[pane]` with each pane's rectangle. Unused ids are left empty.
    pub fn layout(self: *const Tree, area: Rect, out: []Rect) void {
        for (out) |*r| r.* = .{};
        self.layoutNode(self.root, area, out);
    }

    fn layoutNode(self: *const Tree, node: u8, area: Rect, out: []Rect) void {
        switch (self.nodes[node]) {
            .free => {},
            .leaf => |pane| {
                if (pane < out.len) out[pane] = area;
            },
            .branch => |b| {
                const parts = halve(area, b.dir, b.ratio);
                self.layoutNode(b.first, parts.first, out);
                self.layoutNode(b.second, parts.second, out);
            },
        }
    }

    /// The pane to focus when moving `side` from `pane`.
    ///
    /// Decided on the laid-out rectangles rather than by walking the tree: the
    /// question the user is asking is "what is over there", and geometry
    /// answers that directly however the splits happen to nest.
    pub fn neighbour(self: *const Tree, pane: u8, side: Side, area: Rect) ?u8 {
        var rects: [MAX_PANES]Rect = @splat(.{});
        self.layout(area, &rects);
        const from = rects[pane];
        if (from.isEmpty()) return null;

        var best: ?u8 = null;
        var best_gap: u32 = std.math.maxInt(u32);
        var best_off: u32 = std.math.maxInt(u32);

        for (rects, 0..) |r, i| {
            if (i == pane or r.isEmpty()) continue;
            const gap: u32 = switch (side) {
                .left => if (r.x + r.w <= from.x) from.x - (r.x + r.w) else continue,
                .right => if (r.x >= from.x + from.w) r.x - (from.x + from.w) else continue,
                .up => if (r.y + r.h <= from.y) from.y - (r.y + r.h) else continue,
                .down => if (r.y >= from.y + from.h) r.y - (from.y + from.h) else continue,
            };
            // Among equally close candidates, the one most in line with where
            // the focus is coming from.
            const off: u32 = switch (side) {
                .left, .right => offset(from.y, from.h, r.y, r.h),
                .up, .down => offset(from.x, from.w, r.x, r.w),
            };
            if (gap < best_gap or (gap == best_gap and off < best_off)) {
                best = @intCast(i);
                best_gap = gap;
                best_off = off;
            }
        }
        return best;
    }

    /// Panes in id order, for iterating a tab's contents.
    pub fn panes(self: *const Tree, out: []u8) []u8 {
        var n: usize = 0;
        for (self.used, 0..) |u, i| {
            if (u and n < out.len) {
                out[n] = @intCast(i);
                n += 1;
            }
        }
        return out[0..n];
    }

    /// The pane under a cell, if any.
    pub fn paneAt(self: *const Tree, area: Rect, x: u32, y: u32) ?u8 {
        var rects: [MAX_PANES]Rect = @splat(.{});
        self.layout(area, &rects);
        for (rects, 0..) |r, i| {
            if (!r.isEmpty() and r.contains(x, y)) return @intCast(i);
        }
        return null;
    }
};

fn offset(a_pos: u32, a_len: u32, b_pos: u32, b_len: u32) u32 {
    const a_mid = a_pos + a_len / 2;
    const b_mid = b_pos + b_len / 2;
    return if (a_mid > b_mid) a_mid - b_mid else b_mid - a_mid;
}

fn fits(r: Rect) bool {
    return r.w >= MIN_COLS and r.h >= MIN_ROWS;
}

const Halves = struct { first: Rect, second: Rect };

/// Divides an area in two, leaving `GAP` cells between them for the divider.
fn halve(area: Rect, dir: Dir, ratio: f32) Halves {
    switch (dir) {
        .horizontal => {
            if (area.w <= GAP) return .{ .first = area, .second = .{} };
            const usable = area.w - GAP;
            var first_w: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(usable)) * ratio));
            first_w = std.math.clamp(first_w, 0, usable);
            return .{
                .first = .{ .x = area.x, .y = area.y, .w = first_w, .h = area.h },
                .second = .{
                    .x = area.x + first_w + GAP,
                    .y = area.y,
                    .w = usable - first_w,
                    .h = area.h,
                },
            };
        },
        .vertical => {
            if (area.h <= GAP) return .{ .first = area, .second = .{} };
            const usable = area.h - GAP;
            var first_h: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(usable)) * ratio));
            first_h = std.math.clamp(first_h, 0, usable);
            return .{
                .first = .{ .x = area.x, .y = area.y, .w = area.w, .h = first_h },
                .second = .{
                    .x = area.x,
                    .y = area.y + first_h + GAP,
                    .w = area.w,
                    .h = usable - first_h,
                },
            };
        },
    }
}

// -- tests -----------------------------------------------------------------

const testing = std.testing;

const wide = Rect{ .x = 0, .y = 0, .w = 120, .h = 40 };

fn layoutOf(t: *const Tree, area: Rect) [MAX_PANES]Rect {
    var rects: [MAX_PANES]Rect = @splat(.{});
    t.layout(area, &rects);
    return rects;
}

/// No two panes may overlap, and none may leave the tab's area.
fn expectDisjoint(rects: [MAX_PANES]Rect, area: Rect) !void {
    for (rects, 0..) |a, i| {
        if (a.isEmpty()) continue;
        try testing.expect(a.x >= area.x and a.y >= area.y);
        try testing.expect(a.x + a.w <= area.x + area.w);
        try testing.expect(a.y + a.h <= area.y + area.h);
        for (rects[i + 1 ..]) |b| {
            if (b.isEmpty()) continue;
            const apart = a.x + a.w <= b.x or b.x + b.w <= a.x or
                a.y + a.h <= b.y or b.y + b.h <= a.y;
            try testing.expect(apart);
        }
    }
}

test "a new tab is one pane filling the area" {
    var t = Tree.single();
    try testing.expectEqual(@as(usize, 1), t.count());
    const rects = layoutOf(&t, wide);
    try testing.expectEqual(wide, rects[0]);
}

test "splitting side by side divides the width" {
    var t = Tree.single();
    const added = try t.split(0, .horizontal, wide);
    try testing.expectEqual(@as(u8, 1), added);
    try testing.expectEqual(@as(usize, 2), t.count());

    const rects = layoutOf(&t, wide);
    try testing.expectEqual(@as(u32, 40), rects[0].h);
    try testing.expectEqual(@as(u32, 40), rects[1].h);
    // The two halves and the divider account for the whole width.
    try testing.expectEqual(wide.w, rects[0].w + GAP + rects[1].w);
    try testing.expectEqual(rects[0].x + rects[0].w + GAP, rects[1].x);
    try expectDisjoint(rects, wide);
}

test "splitting stacked divides the height" {
    var t = Tree.single();
    _ = try t.split(0, .vertical, wide);
    const rects = layoutOf(&t, wide);
    try testing.expectEqual(@as(u32, 120), rects[0].w);
    try testing.expectEqual(@as(u32, 120), rects[1].w);
    try testing.expectEqual(wide.h, rects[0].h + GAP + rects[1].h);
    try expectDisjoint(rects, wide);
}

test "splitting a pane divides that pane, not the tab" {
    // This is what a tree buys over a row of panes: the second split lands
    // inside the half that was focused.
    var t = Tree.single();
    const right = try t.split(0, .horizontal, wide);
    const below = try t.split(right, .vertical, wide);

    const rects = layoutOf(&t, wide);
    // The left pane is untouched and still full height.
    try testing.expectEqual(@as(u32, 40), rects[0].h);
    // The right half is the one that got divided.
    try testing.expectEqual(rects[right].x, rects[below].x);
    try testing.expectEqual(rects[right].w, rects[below].w);
    try testing.expect(rects[below].y > rects[right].y);
    try expectDisjoint(rects, wide);
}

test "panes never overlap, however the splits nest" {
    var t = Tree.single();
    var focus: u8 = 0;
    const dirs = [_]Dir{ .horizontal, .vertical, .vertical, .horizontal, .horizontal };
    for (dirs) |dir| {
        focus = t.split(focus, dir, wide) catch break;
        try expectDisjoint(layoutOf(&t, wide), wide);
    }
    try testing.expect(t.count() > 3);
}

test "a split that would leave an unusable pane is refused" {
    // Better to leave the layout alone than to make a pane nothing can be
    // read in.
    const narrow = Rect{ .x = 0, .y = 0, .w = 30, .h = 40 };
    var t = Tree.single();
    try testing.expectError(error.NoRoom, t.split(0, .horizontal, narrow));
    try testing.expectEqual(@as(usize, 1), t.count());

    const short = Rect{ .x = 0, .y = 0, .w = 120, .h = 5 };
    var t2 = Tree.single();
    try testing.expectError(error.NoRoom, t2.split(0, .vertical, short));
    try testing.expectEqual(@as(usize, 1), t2.count());
}

test "the pane limit is enforced" {
    // Alternating directions is what keeps every pane usable long enough to
    // reach the limit: halving one axis repeatedly hits the minimum size
    // first, which is a different refusal.
    var t = Tree.single();
    const area = Rect{ .x = 0, .y = 0, .w = 400, .h = 64 };
    var focus: u8 = 0;
    for (0..MAX_PANES - 1) |i| {
        const dir: Dir = if (i % 2 == 0) .horizontal else .vertical;
        focus = try t.split(focus, dir, area);
    }
    try testing.expectEqual(MAX_PANES, t.count());
    try testing.expectError(error.TooManyPanes, t.split(focus, .horizontal, area));
}

test "halving one axis runs out of room before it runs out of panes" {
    var t = Tree.single();
    const area = Rect{ .x = 0, .y = 0, .w = 400, .h = 40 };
    var focus: u8 = 0;
    var splits: usize = 0;
    while (t.split(focus, .horizontal, area)) |added| {
        focus = added;
        splits += 1;
    } else |err| {
        try testing.expectEqual(error.NoRoom, err);
    }
    try testing.expect(splits > 0);
    try testing.expect(t.count() < MAX_PANES);
    // Whatever it stopped at, every pane is still usable.
    const rects = layoutOf(&t, area);
    for (rects) |r| {
        if (r.isEmpty()) continue;
        try testing.expect(r.w >= MIN_COLS and r.h >= MIN_ROWS);
    }
}

test "closing a pane gives its space to its sibling" {
    var t = Tree.single();
    const right = try t.split(0, .horizontal, wide);

    const next = t.close(right).?;
    try testing.expectEqual(@as(u8, 0), next);
    try testing.expectEqual(@as(usize, 1), t.count());
    // The survivor is back to the whole area, with no gap left behind.
    try testing.expectEqual(wide, layoutOf(&t, wide)[0]);
}

test "closing the last pane reports the tab is finished" {
    var t = Tree.single();
    try testing.expect(t.close(0) == null);
    try testing.expectEqual(@as(usize, 0), t.count());
}

test "closing inside a nested layout keeps the rest intact" {
    var t = Tree.single();
    const right = try t.split(0, .horizontal, wide);
    const below = try t.split(right, .vertical, wide);
    try testing.expectEqual(@as(usize, 3), t.count());

    _ = t.close(below);
    try testing.expectEqual(@as(usize, 2), t.count());
    const rects = layoutOf(&t, wide);
    // The right pane took back the full height of its column.
    try testing.expectEqual(@as(u32, 40), rects[right].h);
    try expectDisjoint(rects, wide);
}

test "closing every pane in turn leaves nothing behind" {
    var t = Tree.single();
    var focus: u8 = 0;
    for (0..3) |_| focus = try t.split(focus, .horizontal, Rect{ .w = 400, .h = 40 });

    var ids: [MAX_PANES]u8 = undefined;
    var open = t.panes(&ids).len;
    while (open > 0) : (open -= 1) {
        var live: [MAX_PANES]u8 = undefined;
        const list = t.panes(&live);
        _ = t.close(list[0]);
    }
    try testing.expectEqual(@as(usize, 0), t.count());
    // Every node went back to the pool, so the next tab starts clean.
    for (t.nodes) |n| try testing.expect(n == .free);
}

test "focus moves to the pane that is actually over there" {
    var t = Tree.single();
    const right = try t.split(0, .horizontal, wide);

    try testing.expectEqual(right, t.neighbour(0, .right, wide).?);
    try testing.expectEqual(@as(u8, 0), t.neighbour(right, .left, wide).?);
    // Nothing above or below a full-height pane.
    try testing.expect(t.neighbour(0, .up, wide) == null);
    try testing.expect(t.neighbour(0, .down, wide) == null);
    try testing.expect(t.neighbour(right, .right, wide) == null);
}

test "focus picks the nearest pane in line with where it came from" {
    // Left column full height; right column split in two. Moving right from
    // the left pane lands in the upper right, being the one it faces.
    var t = Tree.single();
    const right = try t.split(0, .horizontal, wide);
    const lower = try t.split(right, .vertical, wide);

    const rects = layoutOf(&t, wide);
    try testing.expect(rects[lower].y > rects[right].y);
    try testing.expectEqual(right, t.neighbour(0, .right, wide).?);
    try testing.expectEqual(lower, t.neighbour(right, .down, wide).?);
    try testing.expectEqual(right, t.neighbour(lower, .up, wide).?);
}

test "a cell resolves to the pane it lies in" {
    var t = Tree.single();
    const right = try t.split(0, .horizontal, wide);
    const rects = layoutOf(&t, wide);

    try testing.expectEqual(@as(u8, 0), t.paneAt(wide, 0, 0).?);
    try testing.expectEqual(@as(u8, 0), t.paneAt(wide, rects[0].w - 1, 20).?);
    try testing.expectEqual(right, t.paneAt(wide, rects[right].x, 20).?);
    // The divider belongs to neither.
    try testing.expect(t.paneAt(wide, rects[0].w, 20) == null);
    try testing.expect(t.paneAt(wide, 999, 999) == null);
}

test "every cell of the area belongs to a pane or to a divider" {
    var t = Tree.single();
    var focus: u8 = 0;
    for ([_]Dir{ .horizontal, .vertical, .horizontal }) |dir| {
        focus = try t.split(focus, dir, wide);
    }
    const rects = layoutOf(&t, wide);

    var covered: usize = 0;
    for (rects) |r| covered += r.w * r.h;
    // The gaps are the only thing unaccounted for, and there are three of them.
    try testing.expect(covered < wide.w * wide.h);
    try testing.expect(covered > wide.w * wide.h * 9 / 10);
    try expectDisjoint(rects, wide);
}

test "the layout survives a tab too small to divide" {
    var t = Tree.single();
    const tiny = Rect{ .x = 0, .y = 0, .w = 1, .h = 1 };
    try testing.expectError(error.NoRoom, t.split(0, .horizontal, tiny));
    const rects = layoutOf(&t, tiny);
    try testing.expectEqual(tiny, rects[0]);
}

test "splitting and closing at random never corrupts the layout" {
    var prng = std.Random.DefaultPrng.init(0x7A7E5);
    const rand = prng.random();
    const area = Rect{ .x = 0, .y = 0, .w = 300, .h = 120 };

    for (0..200) |_| {
        var t = Tree.single();
        for (0..12) |_| {
            var ids: [MAX_PANES]u8 = undefined;
            const list = t.panes(&ids);
            if (list.len == 0) break;
            const pick = list[rand.uintLessThan(usize, list.len)];

            if (list.len > 1 and rand.boolean()) {
                _ = t.close(pick);
            } else {
                const dir: Dir = if (rand.boolean()) .horizontal else .vertical;
                _ = t.split(pick, dir, area) catch {};
            }
            try expectDisjoint(layoutOf(&t, area), area);

            // Every live pane has a rectangle, and nothing else does.
            const rects = layoutOf(&t, area);
            var live: [MAX_PANES]u8 = undefined;
            for (t.panes(&live)) |id| try testing.expect(!rects[id].isEmpty());
            for (rects, 0..) |r, i| {
                if (!r.isEmpty()) try testing.expect(t.used[i]);
            }
        }
    }
}
