const std = @import("std");
const proc = std.process;

const MAX_PROMPT = 1 * 1024 * 1024;

pub fn main() !void {
    var std_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = std_gpa.deinit();
    const gpa = std_gpa.allocator();

    var env_map = try proc.getEnvMap(gpa);
    defer env_map.deinit();

    var bw_o = std.io.bufferedWriter(std.io.getStdOut().writer());
    var bw_e = std.io.bufferedWriter(std.io.getStdErr().writer());
    var bw_i = std.io.bufferedReader(std.io.getStdIn().reader());
    const stdout = bw_o.writer();
    const stderr = bw_e.writer();
    const stdin = bw_i.reader();

    var exiting = false;

    while (!exiting) {
        try prompt(stdout, &bw_o, env_map, gpa);
        const line = stdin.readUntilDelimiterAlloc(gpa, '\n', MAX_PROMPT) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };
        defer gpa.free(line);

        const args = try split_args(line, gpa);
        defer gpa.free(args);

        if (args.len == 0) continue;

        const arg0 = args[0];

        if (std.mem.eql(u8, arg0, "exit")) {
            exiting = true;
        } else if (std.mem.eql(u8, arg0, "echo")) {
            var print_space = false;
            for (args[1..]) |arg| {
                if (print_space)
                    try stdout.writeAll(" ");
                print_space = true;
                try stdout.writeAll(arg);
            }
            try stdout.writeAll("\n");
            try bw_o.flush();
        } else if (std.mem.eql(u8, arg0, "cd")) {
            const next_dir = std.fs.cwd().openDir(args[1], .{}) catch |e| {
                try stderr.print("Could not open directory: {s}\n", .{@errorName(e)});
                try bw_e.flush();
                continue;
            };
            var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
            const new_path = try std.os.getFdPath(next_dir.fd, &path_buf);
            const old_pwd = env_map.get("PWD");
            try env_map.put("PWD", new_path);
            if (old_pwd) |old|
                try env_map.put("OLDPWD", old);

            try next_dir.setAsCwd();
        } else {
            if (!try run_program(arg0, args, env_map, gpa)) {
                try stderr.print("{s}: could not find command\n", .{arg0});
                try bw_e.flush();
            }
        }
    }

    try stdout.print("\n", .{});
    try bw_o.flush();
}

fn prompt(writer: anytype, flusher: anytype, env_map: proc.EnvMap, alloc: std.mem.Allocator) !void {
    const user = env_map.get("USER") orelse "$USER";
    const hostname = std.mem.sliceTo(&std.posix.uname().nodename, 0);
    const pwd = env_map.get("PWD") orelse "$PWD";
    const home = env_map.get("HOME") orelse "$HOME";

    const path = try std.mem.replaceOwned(u8, alloc, pwd, home, "~");
    defer alloc.free(path);

    try writer.print("{s}@{s}:{s}$ ", .{ user, hostname, path });
    try flusher.flush();
}

fn split_args(input: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    var input_buf = input;
    var args = std.ArrayList([]const u8).init(alloc);
    var cur_start = input.ptr;
    var cur_len: usize = 0;

    var white_space_mode = true;

    while (input_buf.len > 0) : (input_buf = input_buf[1..]) {
        if (std.ascii.isWhitespace(input_buf[0])) {
            if (!white_space_mode) {
                white_space_mode = true;
                try args.append(cur_start[0..cur_len]);
            }
        } else {
            if (white_space_mode) {
                white_space_mode = false;
                cur_start = input_buf.ptr;
                cur_len = 0;
            }
            cur_len += 1;
        }
    }
    if (!white_space_mode) {
        try args.append(cur_start[0..cur_len]);
    }

    return try args.toOwnedSlice();
}

fn run_program(program: []const u8, args: []const []const u8, env_map: proc.EnvMap, alloc: std.mem.Allocator) !bool {
    const path = env_map.get("PATH") orelse return error.NoPath;
    var bin_dirs = std.mem.split(u8, path, ":");
    while (bin_dirs.next()) |bin_dir| {
        const dir = std.fs.openDirAbsolute(bin_dir, .{}) catch continue;
        const exists = !std.meta.isError(dir.statFile(program));
        if (exists) {
            var child = std.process.Child.init(args, alloc);
            _ = try child.spawnAndWait();
            return true;
        }
    }
    return false;
}
