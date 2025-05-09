const std = @import("std");
const main = @import("main.zig");

pub const list: std.StaticStringMap(Command) = .initComptime(.{
    .{ "help", Command.init(help, "Show information about built-in commands") },
    .{ "exit", Command.init(exit, "Exit the shell") },
    .{ "echo", Command.init(echo, "Print the arguments to standard output terminated by a newline") },
    .{ "cd", Command.init(cd, "Change the current working directory") },
});

const CommandError = std.fs.File.WriteError || std.fs.File.ReadError || std.posix.RealPathError || std.mem.Allocator.Error;
const Command = struct {
    call: *const fn (args: [][]const u8, state: *main.State) CommandError!void,
    description: []const u8,

    fn init(call: *const fn (args: [][]const u8, state: *main.State) CommandError!void, description: []const u8) Command {
        return .{
            .call = call,
            .description = description,
        };
    }
};

fn help(args: [][]const u8, state: *main.State) CommandError!void {
    var specific_help = false;
    for (args[1..]) |cmd_name| {
        if (list.get(cmd_name)) |cmd| {
            try state.print("{s}: {s}\n", .{ cmd_name, cmd.description });
            specific_help = true;
        }
    }
    if (specific_help) {
        try state.bw_o.flush();
        return;
    }

    for (list.keys(), list.values()) |cmd_name, cmd| {
        try state.print("{s}: {s}\n", .{ cmd_name, cmd.description });
    }

    try state.bw_o.flush();
}
fn exit(_: [][]const u8, state: *main.State) CommandError!void {
    state.exiting = true;
}
fn echo(args: [][]const u8, state: *main.State) CommandError!void {
    const stdout = state.bw_o.writer();

    var print_space = false;
    for (args[1..]) |arg| {
        if (print_space)
            try stdout.writeAll(" ");
        print_space = true;
        try stdout.writeAll(arg);
    }
    try stdout.writeAll("\n");
    try state.bw_o.flush();
}

fn cd(args: [][]const u8, state: *main.State) CommandError!void {
    if (args.len > 2) {
        try state.eprint("cd: too many arguments\n", .{});
        try state.bw_e.flush();
        return;
    }

    const next_dir = std.fs.cwd().openDir(args[1], .{}) catch |e| {
        try state.eprint("cd: could not open directory: {s}\n", .{@errorName(e)});
        try state.bw_e.flush();
        return;
    };
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const new_path = try std.os.getFdPath(next_dir.fd, &path_buf);
    const old_pwd = state.env_map.get("PWD");
    try state.env_map.put("PWD", new_path);
    if (old_pwd) |old|
        try state.env_map.put("OLDPWD", old);

    try next_dir.setAsCwd();
}
