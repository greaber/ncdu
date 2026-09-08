// SPDX-FileCopyrightText: 2026 Grant Reaber
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const model = @import("model.zig");
const c = @import("c");

const Extent = struct {
    dev: u64,
    id: u64,
    start: u64,
    end: u64,
    parent: *model.Dir,
    is_opaque: bool,
};

const DirStats = struct {
    base_blocks: u64 = 0,
    blocks: u64 = 0,
    active: u32 = 0,
    last: u64 = 0,
};

var lock: std.Io.Mutex = .init;
var extents: std.ArrayList(Extent) = .empty;
var dirs = std.AutoHashMap(*model.Dir, DirStats).init(main.allocator);

pub var progress_total: usize = 0;
pub var progress_done: usize = 0;
pub var errors: usize = 0;

pub fn begin() void {
    extents.clearAndFree(main.allocator);
    dirs.clearAndFree();
    progress_total = 0;
    progress_done = 0;
    errors = 0;
}

pub fn addDir(dir: *model.Dir, blocks: u64) void {
    lock.lockUncancelable(main.io);
    defer lock.unlock(main.io);
    const stat = dirs.getOrPut(dir) catch unreachable;
    if (!stat.found_existing) stat.value_ptr.* = .{};
    stat.value_ptr.base_blocks +|= blocks;
}

fn appendOpaque(parent: *model.Dir, dev: u64, ino: u64, blocks: u64) void {
    if (blocks == 0) return;
    extents.append(main.allocator, .{
        .dev = dev,
        .id = ino,
        .start = 0,
        .end = blocks *| 512,
        .parent = parent,
        .is_opaque = true,
    }) catch unreachable;
}

pub const addFile = if (builtin.os.tag == .linux) addFileLinux else addFileUnsupported;

fn addFileUnsupported(_: std.Io.Dir, _: [:0]const u8, _: *model.Dir, _: u64, _: u64, _: u64) void {
    unreachable;
}

fn addFileLinux(dir: std.Io.Dir, name: [:0]const u8, parent: *model.Dir, dev: u64, ino: u64, blocks: u64) void {
    var file_extents: std.ArrayList(Extent) = .empty;
    defer file_extents.deinit(main.allocator);

    const flags = c.O_RDONLY | c.O_CLOEXEC | c.O_NONBLOCK |
        (if (main.config.follow_symlinks) 0 else c.O_NOFOLLOW);
    const fd = c.openat(dir.handle, name.ptr, flags);
    if (fd < 0) return addError(parent, dev, ino, blocks);
    defer _ = c.close(fd);

    const extent_count = 128;
    const Buffer = extern struct {
        map: c.struct_fiemap,
        items: [extent_count]c.struct_fiemap_extent,
    };
    var buf: Buffer = undefined;
    var logical: u64 = 0;
    var mapped_blocks: u64 = 0;
    var last = false;

    while (!last) {
        @memset(std.mem.asBytes(&buf), 0);
        buf.map.fm_start = logical;
        buf.map.fm_length = std.math.maxInt(u64);
        buf.map.fm_flags = c.FIEMAP_FLAG_SYNC;
        buf.map.fm_extent_count = extent_count;
        if (c.ioctl(fd, c.FS_IOC_FIEMAP, &buf.map) < 0)
            return addError(parent, dev, ino, blocks);
        if (buf.map.fm_mapped_extents == 0) break;

        for (buf.items[0..buf.map.fm_mapped_extents]) |item| {
            const invalid = c.FIEMAP_EXTENT_UNKNOWN |
                c.FIEMAP_EXTENT_DELALLOC |
                c.FIEMAP_EXTENT_ENCODED |
                c.FIEMAP_EXTENT_NOT_ALIGNED |
                c.FIEMAP_EXTENT_DATA_INLINE;
            if (item.fe_flags & invalid != 0 or item.fe_length == 0)
                return addError(parent, dev, ino, blocks);
            const next = item.fe_logical +| item.fe_length;
            if (next <= logical)
                return addError(parent, dev, ino, blocks);
            logical = next;
            mapped_blocks +|= item.fe_length / 512;
            file_extents.append(main.allocator, .{
                .dev = dev,
                .id = 0,
                .start = item.fe_physical,
                .end = item.fe_physical +| item.fe_length,
                .parent = parent,
                .is_opaque = false,
            }) catch unreachable;
            last = item.fe_flags & c.FIEMAP_EXTENT_LAST != 0;
        }
    }

    lock.lockUncancelable(main.io);
    defer lock.unlock(main.io);
    extents.appendSlice(main.allocator, file_extents.items) catch unreachable;
    if (blocks > mapped_blocks)
        appendOpaque(parent, dev, ino, blocks - mapped_blocks);
}

fn addError(parent: *model.Dir, dev: u64, ino: u64, blocks: u64) void {
    lock.lockUncancelable(main.io);
    defer lock.unlock(main.io);
    errors += 1;
    parent.pack.suberr = true;
    appendOpaque(parent, dev, ino, blocks);
}

fn lessStart(_: void, a: Extent, b: Extent) bool {
    if (a.is_opaque != b.is_opaque) return @intFromBool(a.is_opaque) < @intFromBool(b.is_opaque);
    if (a.dev != b.dev) return a.dev < b.dev;
    if (a.id != b.id) return a.id < b.id;
    if (a.start != b.start) return a.start < b.start;
    return a.end < b.end;
}

const EndContext = struct {
    items: []const Extent,

    pub fn lessThan(self: @This(), a: usize, b: usize) bool {
        const ae = self.items[a];
        const be = self.items[b];
        if (ae.end != be.end) return ae.end < be.end;
        return a < b;
    }
};

fn sameSpace(a: Extent, b: Extent) bool {
    return a.is_opaque == b.is_opaque and a.dev == b.dev and a.id == b.id;
}

fn update(dir: *model.Dir, pos: u64, start: bool) void {
    var item: ?*model.Dir = dir;
    while (item) |d| : (item = d.parent) {
        const stat = dirs.getPtr(d).?;
        if (stat.active > 0)
            stat.blocks +|= (pos - stat.last) / 512;
        stat.last = pos;
        if (start) stat.active += 1 else stat.active -= 1;
    }
}

pub fn finish() void {
    std.sort.heap(Extent, extents.items, {}, lessStart);

    var stat_it = dirs.iterator();
    while (stat_it.next()) |entry| {
        entry.value_ptr.blocks = 0;
        entry.value_ptr.active = 0;
    }
    stat_it = dirs.iterator();
    while (stat_it.next()) |entry| {
        var parent: ?*model.Dir = entry.key_ptr.*;
        while (parent) |d| : (parent = d.parent)
            dirs.getPtr(d).?.blocks +|= entry.value_ptr.base_blocks;
    }

    var ends: std.ArrayList(usize) = .empty;
    defer ends.deinit(main.allocator);
    ends.resize(main.allocator, extents.items.len) catch unreachable;

    progress_total = extents.items.len *| 2;
    var first: usize = 0;
    while (first < extents.items.len) {
        var limit = first + 1;
        while (limit < extents.items.len and sameSpace(extents.items[first], extents.items[limit]))
            limit += 1;

        for (first..limit, first..) |_, i| ends.items[i] = i;
        std.sort.heap(usize, ends.items[first..limit], EndContext{ .items = extents.items }, EndContext.lessThan);

        var si = first;
        var ei = first;
        while (si < limit or ei < limit) {
            const next_start = if (si < limit) extents.items[si].start else std.math.maxInt(u64);
            const next_end = if (ei < limit) extents.items[ends.items[ei]].end else std.math.maxInt(u64);
            const pos = @min(next_start, next_end);
            while (ei < limit and extents.items[ends.items[ei]].end == pos) : (ei += 1) {
                update(extents.items[ends.items[ei]].parent, pos, false);
                progress_done += 1;
            }
            while (si < limit and extents.items[si].start == pos) : (si += 1) {
                update(extents.items[si].parent, pos, true);
                progress_done += 1;
            }
            if ((progress_done & 0xffff) == 0) main.handleEvent(false, false);
        }
        first = limit;
    }

    stat_it = dirs.iterator();
    while (stat_it.next()) |entry| {
        entry.key_ptr.*.entry.pack.blocks = @intCast(@min(entry.value_ptr.blocks, std.math.maxInt(model.Blocks)));
        entry.key_ptr.*.shared_blocks = 0;
    }
}

test "directory extent unions" {
    const root = model.Entry.create(main.allocator, .dir, false, "root").dir().?;
    defer root.entry.destroy(main.allocator);
    const left = model.Entry.create(main.allocator, .dir, false, "left").dir().?;
    defer left.entry.destroy(main.allocator);
    const right = model.Entry.create(main.allocator, .dir, false, "right").dir().?;
    defer right.entry.destroy(main.allocator);
    left.parent = root;
    right.parent = root;

    begin();
    addDir(root, 1);
    addDir(left, 2);
    addDir(right, 3);
    extents.append(main.allocator, .{ .dev = 1, .id = 0, .start = 0, .end = 1024, .parent = left, .is_opaque = false }) catch unreachable;
    extents.append(main.allocator, .{ .dev = 1, .id = 0, .start = 512, .end = 1536, .parent = right, .is_opaque = false }) catch unreachable;
    finish();

    try std.testing.expectEqual(@as(model.Blocks, 9), root.entry.pack.blocks);
    try std.testing.expectEqual(@as(model.Blocks, 4), left.entry.pack.blocks);
    try std.testing.expectEqual(@as(model.Blocks, 5), right.entry.pack.blocks);
    begin();
}
