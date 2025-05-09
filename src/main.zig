const std = @import("std");
const builtin = @import("builtin");
const proc = std.process;
const cmds = @import("cmds.zig");

const MAX_PROMPT = 1 * 1024 * 1024;

const debug = builtin.mode == .Debug;

pub const State = struct {
    const File = std.fs.File;

    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    env_arena: std.mem.Allocator,
    env_map: proc.EnvMap,
    exiting: bool = false,
    bw_o: std.io.BufferedWriter(4096, File.Writer),
    bw_e: std.io.BufferedWriter(4096, File.Writer),
    bw_i: std.io.BufferedReader(4096, File.Reader),

    const Self = @This();

    pub fn print(self: *Self, comptime format: []const u8, args: anytype) File.WriteError!void {
        const stdout = self.bw_o.writer();
        return stdout.print(format, args);
    }
    pub fn eprint(self: *Self, comptime format: []const u8, args: anytype) File.WriteError!void {
        @branchHint(.unlikely);
        const stderr = self.bw_e.writer();
        return stderr.print(format, args);
    }

    pub fn prompt(self: *Self) !void {
        const user = self.env_map.get("USER") orelse "$USER";
        const hostname = std.mem.sliceTo(&std.posix.uname().nodename, 0);
        const pwd = self.env_map.get("PWD") orelse "$PWD";
        const home = self.env_map.get("HOME") orelse "$HOME";

        const path = try std.mem.replaceOwned(u8, self.arena, pwd, home, "~");
        defer self.arena.free(path);

        try self.print("{s}@{s}:{s}$ ", .{ user, hostname, path });
        try self.bw_o.flush();
    }
    pub fn run_program(self: *Self, program: []const u8, args: []const []const u8) !void {
        search: {
            if (std.mem.indexOfScalar(u8, program, std.fs.path.sep)) |_| {
                break :search;
            }

            const path = self.env_map.get("PATH") orelse "";
            var bin_dirs = std.mem.splitScalar(u8, path, ':');

            while (bin_dirs.next()) |bin_dir| {
                var dir = std.fs.openDirAbsolute(bin_dir, .{}) catch continue;
                defer dir.close();
                const exists = !std.meta.isError(dir.statFile(program));
                if (exists) {
                    break :search;
                }
            }
            return error.NoProgram;
        }

        var child = std.process.Child.init(args, self.arena);
        child.env_map = &self.env_map;
        _ = try child.spawnAndWait();
    }
};

pub fn main() !void {
    var dbg_gpa = std.heap.DebugAllocator(.{ .verbose_log = true }).init;
    defer _ = dbg_gpa.deinit();

    const gpa_upper = if (debug) dbg_gpa.allocator() else std.heap.smp_allocator;
    var env_arena_allocator = std.heap.ArenaAllocator.init(gpa_upper);
    defer env_arena_allocator.deinit();
    var state: State = s: {
        const env_arena = env_arena_allocator.allocator();
        break :s .{
            .env_arena = env_arena,
            .env_map = try proc.getEnvMap(env_arena),
            .gpa = gpa_upper,
            .bw_o = std.io.bufferedWriter(std.io.getStdOut().writer()),
            .bw_e = std.io.bufferedWriter(std.io.getStdErr().writer()),
            .bw_i = std.io.bufferedReader(std.io.getStdIn().reader()),
            .arena = undefined,
        };
    };

    var arena_allocator = std.heap.ArenaAllocator.init(state.gpa);
    state.arena = arena_allocator.allocator();
    defer arena_allocator.deinit();
    while (!state.exiting) {
        defer _ = arena_allocator.reset(.{ .retain_with_limit = std.heap.pageSize() });

        try state.prompt();
        const line = state.bw_i.reader().readUntilDelimiterAlloc(state.arena, '\n', MAX_PROMPT) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return e,
        };

        const args = try split_args(line, state.arena);

        if (args.len == 0) continue;

        const arg0 = args[0];

        if (cmds.list.get(arg0)) |cmd| {
            try cmd.call(args, &state);
        } else {
            const stderr = state.bw_e.writer();
            state.run_program(arg0, args) catch |e| switch (e) {
                error.FileNotFound => {
                    try stderr.print("{s}: No such file or directory\n", .{arg0});
                    try state.bw_e.flush();
                },
                error.AccessDenied => {
                    try stderr.print("{s}: Permission denied\n", .{arg0});
                    try state.bw_e.flush();
                },
                error.NoProgram => {
                    try stderr.print("{s}: could not find command\n", .{arg0});
                    try state.bw_e.flush();
                },
                else => return e,
            };
        }
    }

    try state.bw_e.flush();
    try state.print("\n", .{});
    try state.bw_o.flush();
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
