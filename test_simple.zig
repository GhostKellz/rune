const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var list = std.ArrayList(u8){};
    defer list.deinit();
    
    try list.append(allocator, 'A');
    std.debug.print("Success: {s}\n", .{list.items});
}
