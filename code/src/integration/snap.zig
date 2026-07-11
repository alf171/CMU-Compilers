const std = @import("std");
const runCommand = @import("run.zig").runCommand;

pub fn run(
    compiler_path: []const u8,
    file_name: []const u8,
    update: bool,
    alloc: std.mem.Allocator,
    io: std.Io,
) !void {
    std.debug.print("running {s}", .{file_name});
    const result = try runCommand(alloc, io, &.{ compiler_path, file_name, "/tmp/out.s", "--run", "--dump-stats", "--omit-escape-codes" });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);

    // snapshot dir
    const snapshot_dir_path = "tst/snapshot";
    const dir = try std.Io.Dir.cwd().openDir(io, snapshot_dir_path, .{ .iterate = true });
    defer dir.close(io);
    const snapshot_file_name = try std.fmt.allocPrint(alloc, "{s}.snapshot", .{std.fs.path.basename(file_name)});
    defer alloc.free(snapshot_file_name);

    // perform snapshotting
    if (update) {
        const file = try dir.createFile(io, snapshot_file_name, .{});
        defer file.close(io);

        var file_buf: [1028]u8 = undefined;
        var file_writer: std.Io.File.Writer = .init(file, io, &file_buf);
        try file_writer.interface.writeAll(result.stderr);
        try file_writer.interface.flush();
        std.debug.print(" [[REGENERATED]]\n", .{});
        return;
    }

    // verify
    const temp_file_path_with_dir = try std.fs.path.join(alloc, &.{ "/tmp", snapshot_file_name });
    defer alloc.free(temp_file_path_with_dir);
    const temp_file = try std.Io.Dir.createFileAbsolute(io, temp_file_path_with_dir, .{});
    defer temp_file.close(io);
    try temp_file.writeStreamingAll(io, result.stderr);

    const snapshot_file_name_with_dir = try std.fs.path.join(alloc, &.{ snapshot_dir_path, snapshot_file_name });
    defer alloc.free(snapshot_file_name_with_dir);
    const diff = try std.process.run(alloc, io, .{ .argv = &.{
        "git",
        "diff",
        "--no-index",
        "--color=always",
        "--",
        snapshot_file_name_with_dir,
        temp_file_path_with_dir,
    } });
    defer alloc.free(diff.stdout);
    defer alloc.free(diff.stderr);

    const code = diff.term.exited;

    if (code == 1) {
        std.debug.print(" [[NOT EQUAL]]\n", .{});
        std.debug.print("{s}", .{diff.stdout});
        return error.SnapshotMistmatch;
    }
    if (code == 0) {
        std.debug.print(" [[EQUAL]]\n", .{});
        return;
    }
    return error.CommandFailed;
}

pub fn main(init: std.process.Init) !void {
    const arena = init.arena;
    const args = try init.minimal.args.toSlice(arena.allocator());
    std.debug.assert(args.len == 2 or args.len == 3);
    const io = init.io;
    const alloc = init.gpa;

    var should_regen_snapshot = false;
    if (args.len == 3) {
        const arg = args[2];
        if (std.mem.eql(u8, arg, "--regen")) should_regen_snapshot = true;
    }
    const compiler_path = args[1];

    const dir = try std.Io.Dir.cwd().openDir(io, "tst/python", .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        std.debug.assert(entry.kind == .file);

        const path = try std.fs.path.join(alloc, &.{ "tst/python", entry.path });
        defer alloc.free(path);
        run(compiler_path, path, should_regen_snapshot, alloc, io) catch {
            std.debug.print(" [[ERROR]]\n", .{});
        };
    }
}
