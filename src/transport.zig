//! Transport layer abstraction for MCP communication
const std = @import("std");
const protocol = @import("protocol.zig");

/// Transport types supported by Rune
pub const TransportType = enum {
    stdio,
    websocket,
    http_sse,
};

/// Generic transport interface
pub const Transport = union(TransportType) {
    stdio: StdioTransport,
    websocket: WebSocketTransport,
    http_sse: HttpSseTransport,

    pub fn init(allocator: std.mem.Allocator, transport_type: TransportType) !Transport {
        switch (transport_type) {
            .stdio => return .{ .stdio = try StdioTransport.init(allocator) },
            .websocket => return .{ .websocket = try WebSocketTransport.init(allocator) },
            .http_sse => return .{ .http_sse = try HttpSseTransport.init(allocator) },
        }
    }

    pub fn deinit(self: *Transport) void {
        switch (self.*) {
            .stdio => |*t| t.deinit(),
            .websocket => |*t| t.deinit(),
            .http_sse => |*t| t.deinit(),
        }
    }

    pub fn send(self: *Transport, message: protocol.JsonRpcMessage) !void {
        switch (self.*) {
            .stdio => |*t| try t.send(message),
            .websocket => |*t| try t.send(message),
            .http_sse => |*t| try t.send(message),
        }
    }

    pub fn receive(self: *Transport) !?protocol.JsonRpcMessage {
        switch (self.*) {
            .stdio => |*t| return try t.receive(),
            .websocket => |*t| return try t.receive(),
            .http_sse => |*t| return try t.receive(),
        }
    }
};

/// stdio transport implementation (most common for MCP)
pub const StdioTransport = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdout: std.fs.File,
    read_buffer: std.ArrayList(u8),
    stdin_buf: [4096]u8,
    stdout_buf: [4096]u8,

    pub fn init(allocator: std.mem.Allocator) !StdioTransport {
        return StdioTransport{
            .allocator = allocator,
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
            .read_buffer = std.ArrayList(u8){},
            .stdin_buf = undefined,
            .stdout_buf = undefined,
        };
    }

    pub fn deinit(self: *StdioTransport) void {
        self.read_buffer.deinit(self.allocator);
    }

    pub fn send(self: *StdioTransport, message: protocol.JsonRpcMessage) !void {
        _ = self;
        _ = message;
        // Placeholder implementation - in a real scenario this would serialize and send the message
    }

    pub fn receive(self: *StdioTransport) !?protocol.JsonRpcMessage {
        // For now, return null to indicate no input (this would be implemented properly in a real scenario)
        _ = self;
        return null;
    }
};

/// WebSocket transport (placeholder for now)
pub const WebSocketTransport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !WebSocketTransport {
        return WebSocketTransport{ .allocator = allocator };
    }

    pub fn deinit(self: *WebSocketTransport) void {
        _ = self;
    }

    pub fn send(self: *WebSocketTransport, message: protocol.JsonRpcMessage) !void {
        _ = self;
        _ = message;
        return error.NotImplemented;
    }

    pub fn receive(self: *WebSocketTransport) !?protocol.JsonRpcMessage {
        _ = self;
        return error.NotImplemented;
    }
};

/// HTTP Server-Sent Events transport (placeholder for now)
pub const HttpSseTransport = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !HttpSseTransport {
        return HttpSseTransport{ .allocator = allocator };
    }

    pub fn deinit(self: *HttpSseTransport) void {
        _ = self;
    }

    pub fn send(self: *HttpSseTransport, message: protocol.JsonRpcMessage) !void {
        _ = self;
        _ = message;
        return error.NotImplemented;
    }

    pub fn receive(self: *HttpSseTransport) !?protocol.JsonRpcMessage {
        _ = self;
        return error.NotImplemented;
    }
};

test "stdio transport" {
    const testing = std.testing;
    var transport = try StdioTransport.init(testing.allocator);
    defer transport.deinit();

    // Basic initialization test
    try testing.expect(transport.read_buffer.items.len == 0);
}