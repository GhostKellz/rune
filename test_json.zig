const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    
    try arr.append(std.json.Value{ .string = "test" });
    std.debug.print("Success\n", .{});
}
