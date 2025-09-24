const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(allocator);
    
    try list.append(allocator, 'A');
    std.debug.print("Success with unmanaged\n", .{});
    
    // Also test the managed version
    var list2 = std.ArrayList(u8).init(allocator);
    defer list2.deinit();
    try list2.append('B');
    std.debug.print("Success with managed\n", .{});
}
