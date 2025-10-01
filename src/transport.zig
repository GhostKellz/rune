//! Transport layer abstraction for MCP communication
const std = @import("std");
const protocol = @import("protocol.zig");
const json_rpc = @import("json_rpc.zig");

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
        // Serialize the message
        const json_str = switch (message) {
            .request => |req| try json_rpc.stringifyRequest(self.allocator, req),
            .response => |res| try json_rpc.stringifyResponse(self.allocator, res),
            .notification => |notif| try json_rpc.stringifyNotification(self.allocator, notif),
        };
        defer self.allocator.free(json_str);

        // Write to stdout with newline
        _ = try self.stdout.writeAll(json_str);
        _ = try self.stdout.writeAll("\n");
    }

    pub fn receive(self: *StdioTransport) !?protocol.JsonRpcMessage {
        // Read a line from stdin
        const reader = self.stdin.reader();

        // Try to read until newline
        while (true) {
            if (reader.readUntilDelimiterOrEof(self.stdin_buf[0..], '\n')) |maybe_line| {
                if (maybe_line) |line| {
                    // Parse the JSON-RPC message
                    return json_rpc.parseMessage(self.allocator, line);
                } else {
                    // EOF reached
                    return null;
                }
            } else |err| {
                return err;
            }
        }
    }
};

/// WebSocket transport implementation
pub const WebSocketTransport = struct {
    allocator: std.mem.Allocator,
    stream: ?std.net.Stream,
    connected: bool,
    read_buffer: std.ArrayList(u8),
    url: []const u8,

    pub fn init(allocator: std.mem.Allocator) !WebSocketTransport {
        return WebSocketTransport{
            .allocator = allocator,
            .stream = null,
            .connected = false,
            .read_buffer = std.ArrayList(u8){},
            .url = "",
        };
    }

    pub fn connect(self: *WebSocketTransport, url: []const u8) !void {
        self.url = try self.allocator.dupe(u8, url);

        // Parse URL to extract host and port
        const parsed_url = try parseWebSocketUrl(self.allocator, url);
        defer self.allocator.free(parsed_url.host);
        defer self.allocator.free(parsed_url.path);

        // Connect to the server
        const address = try std.net.Address.parseIp(parsed_url.host, parsed_url.port);
        self.stream = try std.net.tcpConnectToAddress(address);

        // Perform WebSocket handshake
        try self.performHandshake(parsed_url.host, parsed_url.path);
        self.connected = true;
    }

    pub fn deinit(self: *WebSocketTransport) void {
        if (self.stream) |stream| {
            stream.close();
        }
        self.read_buffer.deinit(self.allocator);
        if (self.url.len > 0) {
            self.allocator.free(self.url);
        }
    }

    pub fn send(self: *WebSocketTransport, message: protocol.JsonRpcMessage) !void {
        if (!self.connected or self.stream == null) {
            return error.NotConnected;
        }

        // Serialize the message
        const json_str = switch (message) {
            .request => |req| try json_rpc.stringifyRequest(self.allocator, req),
            .response => |res| try json_rpc.stringifyResponse(self.allocator, res),
            .notification => |notif| try json_rpc.stringifyNotification(self.allocator, notif),
        };
        defer self.allocator.free(json_str);

        // Send as WebSocket text frame
        try self.sendFrame(.text, json_str);
    }

    pub fn receive(self: *WebSocketTransport) !?protocol.JsonRpcMessage {
        if (!self.connected or self.stream == null) {
            return error.NotConnected;
        }

        // Read WebSocket frame
        const frame = try self.readFrame() orelse return null;
        defer self.allocator.free(frame.payload);

        if (frame.opcode != .text) {
            return null; // Skip non-text frames
        }

        // Parse JSON-RPC message
        return try json_rpc.parseMessage(self.allocator, frame.payload);
    }

    const WebSocketFrame = struct {
        opcode: WebSocketOpcode,
        payload: []u8,
    };

    const WebSocketOpcode = enum(u4) {
        continuation = 0x0,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
    };

    const ParsedUrl = struct {
        host: []u8,
        port: u16,
        path: []u8,
        secure: bool,
    };

    fn parseWebSocketUrl(allocator: std.mem.Allocator, url: []const u8) !ParsedUrl {
        var secure = false;
        var start_idx: usize = 0;

        if (std.mem.startsWith(u8, url, "wss://")) {
            secure = true;
            start_idx = 6;
        } else if (std.mem.startsWith(u8, url, "ws://")) {
            start_idx = 5;
        } else {
            return error.InvalidUrl;
        }

        const rest = url[start_idx..];
        const slash_idx = std.mem.indexOf(u8, rest, "/") orelse rest.len;
        const host_port = rest[0..slash_idx];
        const path = if (slash_idx < rest.len) rest[slash_idx..] else "/";

        var host: []const u8 = host_port;
        var port: u16 = if (secure) 443 else 80;

        if (std.mem.indexOf(u8, host_port, ":")) |colon_idx| {
            host = host_port[0..colon_idx];
            port = try std.fmt.parseInt(u16, host_port[colon_idx + 1 ..], 10);
        }

        return ParsedUrl{
            .host = try allocator.dupe(u8, host),
            .port = port,
            .path = try allocator.dupe(u8, path),
            .secure = secure,
        };
    }

    fn performHandshake(self: *WebSocketTransport, host: []const u8, path: []const u8) !void {
        const stream = self.stream.?;

        // Generate WebSocket key
        var key_bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&key_bytes);
        var key_b64: [24]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&key_b64, &key_bytes);

        // Send HTTP request
        const request = try std.fmt.allocPrint(self.allocator, "GET {s} HTTP/1.1\r\n" ++
            "Host: {s}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: {s}\r\n" ++
            "Sec-WebSocket-Version: 13\r\n" ++
            "\r\n", .{ path, host, key_b64 });
        defer self.allocator.free(request);

        _ = try stream.writeAll(request);

        // Read and parse response (simplified)
        var response_buf: [2048]u8 = undefined;
        const bytes_read = try stream.readAll(&response_buf);
        const response = response_buf[0..bytes_read];

        if (!std.mem.startsWith(u8, response, "HTTP/1.1 101")) {
            return error.HandshakeFailed;
        }
    }

    fn sendFrame(self: *WebSocketTransport, opcode: WebSocketOpcode, payload: []const u8) !void {
        const stream = self.stream.?;

        // Calculate frame size
        var frame_size: usize = 2; // Initial 2 bytes
        if (payload.len < 126) {
            // Payload length fits in 7 bits
        } else if (payload.len < 65536) {
            frame_size += 2; // Extended 16-bit length
        } else {
            frame_size += 8; // Extended 64-bit length
        }
        frame_size += 4; // Masking key
        frame_size += payload.len;

        var frame = try self.allocator.alloc(u8, frame_size);
        defer self.allocator.free(frame);

        var idx: usize = 0;

        // First byte: FIN + opcode
        frame[idx] = 0x80 | @intFromEnum(opcode); // FIN=1, RSV=000, opcode
        idx += 1;

        // Second byte: MASK + payload length
        if (payload.len < 126) {
            frame[idx] = 0x80 | @as(u8, @intCast(payload.len)); // MASK=1, length
            idx += 1;
        } else if (payload.len < 65536) {
            frame[idx] = 0x80 | 126; // MASK=1, length=126
            idx += 1;
            std.mem.writeInt(u16, frame[idx .. idx + 2], @as(u16, @intCast(payload.len)), .big);
            idx += 2;
        } else {
            frame[idx] = 0x80 | 127; // MASK=1, length=127
            idx += 1;
            std.mem.writeInt(u64, frame[idx .. idx + 8], payload.len, .big);
            idx += 8;
        }

        // Masking key
        var mask_key: [4]u8 = undefined;
        std.crypto.random.bytes(&mask_key);
        @memcpy(frame[idx .. idx + 4], &mask_key);
        idx += 4;

        // Masked payload
        for (payload, 0..) |byte, i| {
            frame[idx + i] = byte ^ mask_key[i % 4];
        }

        _ = try stream.writeAll(frame);
    }

    fn readFrame(self: *WebSocketTransport) !?WebSocketFrame {
        const stream = self.stream.?;

        // Read frame header (minimum 2 bytes)
        var header: [2]u8 = undefined;
        const bytes_read = try stream.readAll(&header);
        if (bytes_read < 2) return null;

        const fin = (header[0] & 0x80) != 0;
        const opcode: WebSocketOpcode = @enumFromInt(header[0] & 0x0F);
        const masked = (header[1] & 0x80) != 0;
        var payload_len: u64 = header[1] & 0x7F;

        // Read extended payload length
        if (payload_len == 126) {
            var len_bytes: [2]u8 = undefined;
            _ = try stream.readAll(&len_bytes);
            payload_len = std.mem.readInt(u16, &len_bytes, .big);
        } else if (payload_len == 127) {
            var len_bytes: [8]u8 = undefined;
            _ = try stream.readAll(&len_bytes);
            payload_len = std.mem.readInt(u64, &len_bytes, .big);
        }

        // Read masking key if present
        var mask_key: [4]u8 = undefined;
        if (masked) {
            _ = try stream.readAll(&mask_key);
        }

        // Read payload
        const payload = try self.allocator.alloc(u8, @as(usize, @intCast(payload_len)));
        _ = try stream.readAll(payload);

        // Unmask payload if needed
        if (masked) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= mask_key[i % 4];
            }
        }

        if (!fin) {
            // Handle fragmented messages (simplified - just return the fragment)
            std.log.warn("Received fragmented WebSocket frame", .{});
        }

        return WebSocketFrame{
            .opcode = opcode,
            .payload = payload,
        };
    }
};

/// HTTP Server-Sent Events transport implementation
pub const HttpSseTransport = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    base_url: []const u8,
    connected: bool,
    event_buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !HttpSseTransport {
        return HttpSseTransport{
            .allocator = allocator,
            .http_client = std.http.Client{ .allocator = allocator },
            .base_url = "",
            .connected = false,
            .event_buffer = std.ArrayList(u8){},
        };
    }

    pub fn connect(self: *HttpSseTransport, base_url: []const u8) !void {
        self.base_url = try self.allocator.dupe(u8, base_url);
        self.connected = true;
    }

    pub fn deinit(self: *HttpSseTransport) void {
        self.http_client.deinit();
        self.event_buffer.deinit(self.allocator);
        if (self.base_url.len > 0) {
            self.allocator.free(self.base_url);
        }
    }

    pub fn send(self: *HttpSseTransport, message: protocol.JsonRpcMessage) !void {
        if (!self.connected) {
            return error.NotConnected;
        }

        // Serialize the message
        const json_str = switch (message) {
            .request => |req| try json_rpc.stringifyRequest(self.allocator, req),
            .response => |res| try json_rpc.stringifyResponse(self.allocator, res),
            .notification => |notif| try json_rpc.stringifyNotification(self.allocator, notif),
        };
        defer self.allocator.free(json_str);

        // Create HTTP request URL
        const url = try std.fmt.allocPrint(self.allocator, "{s}/rpc", .{self.base_url});
        defer self.allocator.free(url);

        // Send POST request
        var request = try self.http_client.open(.POST, try std.Uri.parse(url), .{
            .server_header_buffer = try self.allocator.alloc(u8, 8192),
        });
        defer request.deinit();

        request.headers.content_type = .{ .override = "application/json" };
        request.headers.content_length = json_str.len;

        try request.send();
        try request.writeAll(json_str);
        try request.finish();

        // Read response (we don't need the result for SSE)
        try request.wait();
    }

    pub fn receive(self: *HttpSseTransport) !?protocol.JsonRpcMessage {
        if (!self.connected) {
            return error.NotConnected;
        }

        // Connect to SSE endpoint
        const url = try std.fmt.allocPrint(self.allocator, "{s}/events", .{self.base_url});
        defer self.allocator.free(url);

        var request = try self.http_client.open(.GET, try std.Uri.parse(url), .{
            .server_header_buffer = try self.allocator.alloc(u8, 8192),
        });
        defer request.deinit();

        request.headers.accept = .{ .override = "text/event-stream" };
        request.headers.cache_control = .{ .override = "no-cache" };

        try request.send();
        try request.finish();
        try request.wait();

        // Read SSE data
        const body = request.reader();
        var line_buf: [4096]u8 = undefined;

        while (true) {
            if (try body.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\n");

                if (std.mem.startsWith(u8, trimmed, "data: ")) {
                    const data = trimmed[6..]; // Skip "data: "
                    if (data.len > 0) {
                        // Parse the JSON-RPC message
                        return json_rpc.parseMessage(self.allocator, data);
                    }
                }
                // Skip other SSE event types (event:, id:, retry:)
            } else {
                // Connection closed or error
                return null;
            }
        }
    }
};

test "stdio transport" {
    const testing = std.testing;
    var transport = try StdioTransport.init(testing.allocator);
    defer transport.deinit();

    // Basic initialization test
    try testing.expect(transport.read_buffer.items.len == 0);
}
