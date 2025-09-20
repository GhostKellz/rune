//! MCP Client implementation
const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

/// MCP Client for calling tools and resources
pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: transport.Transport,
    next_id: u64,
    initialized: bool,

    const Self = @This();

    /// Connect to MCP server via stdio
    pub fn connectStdio(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
            .transport = try transport.Transport.init(allocator, .stdio),
            .next_id = 1,
            .initialized = false,
        };
    }

    /// Connect to MCP server via WebSocket (placeholder)
    pub fn connectWs(allocator: std.mem.Allocator, url: []const u8) !Self {
        _ = url; // TODO: Use URL for WebSocket connection
        return Self{
            .allocator = allocator,
            .transport = try transport.Transport.init(allocator, .websocket),
            .next_id = 1,
            .initialized = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.transport.deinit();
    }

    /// Initialize the MCP session
    pub fn initialize(self: *Self, client_info: protocol.ClientInfo) !protocol.InitializeResult {
        if (self.initialized) return error.AlreadyInitialized;

        const init_params = protocol.InitializeParams{
            .protocolVersion = "2024-11-05",
            .capabilities = .{},
            .clientInfo = client_info,
        };

        const request = protocol.Request{
            .id = .{ .number = @intCast(self.next_id) },
            .method = protocol.Methods.INITIALIZE,
            .params = try self.valueFromStruct(init_params),
        };
        self.next_id += 1;

        try self.transport.send(.{ .request = request });

        // Wait for response
        if (try self.transport.receive()) |message| {
            switch (message) {
                .response => |resp| {
                    if (resp.result) |result| {
                        self.initialized = true;
                        return try self.structFromValue(protocol.InitializeResult, result);
                    } else if (resp.@"error") |_| {
                        return error.InitializationFailed;
                    }
                },
                else => return error.UnexpectedMessage,
            }
        }

        return error.NoResponse;
    }

    /// List available tools
    pub fn listTools(self: *Self) ![]protocol.Tool {
        if (!self.initialized) return error.NotInitialized;

        const request = protocol.Request{
            .id = .{ .number = @intCast(self.next_id) },
            .method = protocol.Methods.TOOLS_LIST,
        };
        self.next_id += 1;

        try self.transport.send(.{ .request = request });

        if (try self.transport.receive()) |message| {
            switch (message) {
                .response => |resp| {
                    if (resp.result) |result| {
                        // TODO: Parse tools list from result
                        _ = result;
                        return &[_]protocol.Tool{};
                    } else if (resp.@"error") |_| {
                        return error.ToolsListFailed;
                    }
                },
                else => return error.UnexpectedMessage,
            }
        }

        return error.NoResponse;
    }

    /// Call a tool
    pub fn invoke(self: *Self, call: protocol.ToolCall) !protocol.ToolResult {
        if (!self.initialized) return error.NotInitialized;

        const request = protocol.Request{
            .id = .{ .number = @intCast(self.next_id) },
            .method = protocol.Methods.TOOLS_CALL,
            .params = try self.valueFromStruct(call),
        };
        self.next_id += 1;

        try self.transport.send(.{ .request = request });

        if (try self.transport.receive()) |message| {
            switch (message) {
                .response => |resp| {
                    if (resp.result) |result| {
                        return try self.structFromValue(protocol.ToolResult, result);
                    } else if (resp.@"error") |_| {
                        return error.ToolCallFailed;
                    }
                },
                else => return error.UnexpectedMessage,
            }
        }

        return error.NoResponse;
    }

    /// Helper to convert struct to JSON Value (simplified placeholder)
    fn valueFromStruct(self: *Self, value: anytype) !std.json.Value {
        _ = value;
        // For now, return a simple placeholder value
        return std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
    }

    /// Helper to convert JSON Value to struct (simplified placeholder)
    fn structFromValue(self: *Self, comptime T: type, value: std.json.Value) !T {
        _ = self;
        _ = value;
        // For now, return a default-initialized struct
        return std.mem.zeroes(T);
    }
};

test "client creation" {
    const testing = std.testing;

    var client = try Client.connectStdio(testing.allocator);
    defer client.deinit();

    try testing.expect(!client.initialized);
    try testing.expect(client.next_id == 1);
}