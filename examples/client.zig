const std = @import("std");
const rune = @import("rune");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Note: In a real scenario, you'd connect to a running server
    // For this example, we show the basic API usage
    var client = try rune.Client.connectStdio(allocator);
    defer client.deinit();

    // Initialize the client
    _ = rune.protocol.ClientInfo{
        .name = "example-client",
        .version = "0.1.0",
    };

    // In a real scenario, this would work with a running server
    // For now, this demonstrates the API structure
    std.debug.print("Client initialized. API structure:\n", .{});
    std.debug.print("- client.initialize(client_info)\n", .{});
    std.debug.print("- client.listTools()\n", .{});
    std.debug.print("- client.invoke(.{{ .name = \"read_file\", .arguments = ... }})\n", .{});

    // Example tool call structure
    const example_call = rune.protocol.ToolCall{
        .name = "read_file",
        .arguments = .{ .object = std.json.ObjectMap.init(allocator) },
    };
    _ = example_call;

    std.debug.print("Example completed successfully!\n", .{});
}