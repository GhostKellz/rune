const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    const value = std.json.Value{ .string = "test" };
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    
    try std.json.stringify(value, .{}, buf.writer(allocator));
    std.debug.print("Result: {s}\n", .{buf.items});
}
