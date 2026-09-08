// SPDX-FileCopyrightText: 2026 Grant Reaber
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const reflink = @import("reflink.zig");

fn printDir(dir: *model.Dir, out: *std.Io.Writer) !void {
    var item = dir.sub.ptr;
    while (item) |entry| : (item = entry.next.ptr)
        if (entry.dir()) |child| try printDir(child, out);

    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(main.allocator);
    dir.fmtPath(main.allocator, true, &path);
    const bytes = if (main.config.show_blocks) dir.entry.pack.blocks *| 512 else dir.entry.size;
    try out.print("{}\t{s}\n", .{ bytes, path.items });
}

pub fn print(root: *model.Dir) void {
    if (main.config.reflink and reflink.errors > 0)
        std.debug.print("Warning: FIEMAP failed for {} files; their sizes were not deduplicated.\n", .{reflink.errors});
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(main.io, &buf);
    printDir(root, &writer.interface) catch |e|
        @panic(@errorName(e));
    writer.interface.flush() catch |e|
        @panic(@errorName(e));
}
