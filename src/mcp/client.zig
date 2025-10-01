const std = @import("std");
const protocol = @import("protocol.zig");
const json = std.json;

pub const Client = struct {
    allocator: std.mem.Allocator,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    request_id: i64 = 0,
    pending_requests: std.AutoHashMap(i64, PendingRequest),
    initialized: bool = false,

    const Self = @This();

    const PendingRequest = struct {
        method: []const u8,
        callback: ?*const fn (result: json.Value) void = null,
    };

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Self {
        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .pending_requests = std.AutoHashMap(i64, PendingRequest).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_requests.deinit();
    }

    pub fn initialize(self: *Self, client_info: protocol.ClientInfo) !protocol.InitializeResult {
        const params = protocol.InitializeParams{
            .protocolVersion = "2024-11-05",
            .capabilities = .{
                .roots = null,
                .sampling = null,
            },
            .clientInfo = client_info,
        };

        const result = try self.request("initialize", params);
        self.initialized = true;

        // Send initialized notification
        try self.notify("notifications/initialized", null);

        return self.parseInitializeResult(result);
    }

    pub fn listTools(self: *Self) !protocol.ListToolsResult {
        const result = try self.request("tools/list", null);
        return self.parseListToolsResult(result);
    }

    pub fn callTool(self: *Self, name: []const u8, arguments: ?json.Value) !protocol.CallToolResult {
        const params = protocol.CallToolParams{
            .name = name,
            .arguments = arguments,
        };

        const result = try self.request("tools/call", params);
        return self.parseCallToolResult(result);
    }

    fn request(self: *Self, method: []const u8, params: anytype) !json.Value {
        const id = self.getNextRequestId();

        const req = protocol.Request{
            .id = .{ .number = id },
            .method = method,
            .params = if (params != null) try self.toJsonValue(params) else null,
        };

        try self.sendRequest(req);
        return self.waitForResponse(id);
    }

    fn notify(self: *Self, method: []const u8, params: anytype) !void {
        const notification = protocol.Notification{
            .method = method,
            .params = if (params != null) try self.toJsonValue(params) else null,
        };

        var string = std.ArrayList(u8).init(self.allocator);
        defer string.deinit();

        try json.stringify(notification, .{}, string.writer());
        try self.writer.print("{s}\n", .{string.items});
    }

    fn sendRequest(self: *Self, req: protocol.Request) !void {
        var string = std.ArrayList(u8).init(self.allocator);
        defer string.deinit();

        try json.stringify(req, .{}, string.writer());
        try self.writer.print("{s}\n", .{string.items});

        try self.pending_requests.put(req.id.number, .{
            .method = req.method,
        });
    }

    fn waitForResponse(self: *Self, id: i64) !json.Value {
        var buf: [65536]u8 = undefined;

        while (self.pending_requests.contains(id)) {
            const line = try self.reader.readUntilDelimiter(&buf, '\n');
            const response = try self.parseResponse(line);

            if (response.id.number == id) {
                _ = self.pending_requests.remove(id);
                if (response.@"error") |err| {
                    std.log.err("RPC error {}: {s}", .{ err.code, err.message });
                    return error.RpcError;
                }
                return response.result orelse error.NullResult;
            }
        }

        return error.ResponseNotReceived;
    }

    fn parseResponse(self: *Self, data: []const u8) !protocol.Response {
        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();

        const value = try parser.parse(data);
        const obj = value.object;

        return .{
            .id = try self.parseRequestId(obj.get("id").?),
            .result = obj.get("result"),
            .@"error" = if (obj.get("error")) |e| try self.parseError(e) else null,
        };
    }

    fn parseRequestId(self: *Self, id: json.Value) !protocol.RequestId {
        _ = self;
        return switch (id) {
            .integer => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .null => .{ .null = {} },
            else => error.InvalidRequestId,
        };
    }

    fn parseError(self: *Self, err: json.Value) !protocol.Error {
        _ = self;
        const obj = err.object;
        return .{
            .code = @intCast(obj.get("code").?.integer),
            .message = obj.get("message").?.string,
            .data = obj.get("data"),
        };
    }

    fn parseInitializeResult(self: *Self, value: json.Value) !protocol.InitializeResult {
        _ = self;
        const obj = value.object;
        return .{
            .protocolVersion = obj.get("protocolVersion").?.string,
            .capabilities = .{
                .tools = if (obj.get("capabilities").?.object.get("tools")) |_| .{} else null,
                .prompts = null,
                .resources = null,
                .logging = if (obj.get("capabilities").?.object.get("logging")) |_| .{} else null,
            },
            .serverInfo = .{
                .name = obj.get("serverInfo").?.object.get("name").?.string,
                .version = obj.get("serverInfo").?.object.get("version").?.string,
            },
        };
    }

    fn parseListToolsResult(self: *Self, value: json.Value) !protocol.ListToolsResult {
        _ = self;
        _ = value;
        // TODO: Implement proper parsing
        return .{ .tools = &.{} };
    }

    fn parseCallToolResult(self: *Self, value: json.Value) !protocol.CallToolResult {
        _ = self;
        _ = value;
        // TODO: Implement proper parsing
        return .{ .content = &.{} };
    }

    fn getNextRequestId(self: *Self) i64 {
        self.request_id += 1;
        return self.request_id;
    }

    fn toJsonValue(self: *Self, value: anytype) !json.Value {
        var string = std.ArrayList(u8).init(self.allocator);
        defer string.deinit();

        try json.stringify(value, .{}, string.writer());

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();

        return try parser.parse(string.items);
    }
};
