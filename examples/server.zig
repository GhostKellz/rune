const std = @import("std");
const rune = @import("rune");

pub fn readFile(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Extract path from params
    const path = switch (params) {
        .object => |obj| blk: {
            if (obj.get("path")) |path_value| {
                switch (path_value) {
                    .string => |s| break :blk s,
                    else => return error.InvalidPathParameter,
                }
            } else {
                return error.MissingPathParameter;
            }
        },
        else => return error.InvalidParameters,
    };

    // Optional consent check (placeholder)
    try ctx.guard.require("fs.read", .{});

    // Read file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{
                    .text = std.fmt.allocPrint(ctx.alloc, "Error opening file: {}", .{err}) catch "Unknown error",
                },
            }},
            .isError = true,
        };
    };
    defer file.close();

    const file_size = file.getEndPos() catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{
                    .text = std.fmt.allocPrint(ctx.alloc, "Error getting file size: {}", .{err}) catch "Unknown error",
                },
            }},
            .isError = true,
        };
    };

    const contents = ctx.alloc.alloc(u8, file_size) catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{
                    .text = std.fmt.allocPrint(ctx.alloc, "Error allocating memory: {}", .{err}) catch "Unknown error",
                },
            }},
            .isError = true,
        };
    };

    _ = file.readAll(contents) catch |err| {
        ctx.alloc.free(contents);
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{
                    .text = std.fmt.allocPrint(ctx.alloc, "Error reading file: {}", .{err}) catch "Unknown error",
                },
            }},
            .isError = true,
        };
    };

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{
                .text = contents,
            },
        }},
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var srv = try rune.Server.init(allocator, .{ .transport = .stdio });
    defer srv.deinit();

    try srv.registerToolWithDesc("read_file", "Read a file from the filesystem", readFile);

    try srv.run();
}