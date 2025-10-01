const std = @import("std");
const protocol = @import("protocol.zig");
const json = std.json;

pub const Server = struct {
    allocator: std.mem.Allocator,
    reader: std.io.AnyReader,
    writer: std.io.AnyWriter,
    tools: std.StringHashMap(ToolHandler),
    initialized: bool = false,
    server_info: protocol.ServerInfo,

    const Self = @This();

    pub const ToolHandler = struct {
        tool: protocol.Tool,
        handler: *const fn (allocator: std.mem.Allocator, params: json.Value) anyerror!protocol.CallToolResult,
    };

    pub fn init(allocator: std.mem.Allocator, reader: std.io.AnyReader, writer: std.io.AnyWriter) Self {
        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .tools = std.StringHashMap(ToolHandler).init(allocator),
            .server_info = .{
                .name = "rune-mcp",
                .version = "0.1.0",
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.tools.deinit();
    }

    pub fn registerTool(self: *Self, handler: ToolHandler) !void {
        try self.tools.put(handler.tool.name, handler);
    }

    pub fn run(self: *Self) !void {
        var buf: [65536]u8 = undefined;

        while (true) {
            const line = self.reader.readUntilDelimiterOrEof(&buf, '\n') catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            } orelse break;

            if (line.len == 0) continue;

            const message = try self.parseMessage(line);
            try self.handleMessage(message);
        }
    }

    fn parseMessage(self: *Self, data: []const u8) !json.Value {
        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();

        return try parser.parse(data);
    }

    fn handleMessage(self: *Self, message: json.Value) !void {
        const obj = message.object;

        if (obj.get("method")) |method| {
            const method_str = method.string;

            if (obj.get("id")) |id| {
                try self.handleRequest(id, method_str, obj.get("params"));
            } else {
                try self.handleNotification(method_str, obj.get("params"));
            }
        }
    }

    fn handleRequest(self: *Self, id: json.Value, method: []const u8, params: ?json.Value) !void {
        var response = protocol.Response{
            .id = try self.parseRequestId(id),
            .result = null,
            .@"error" = null,
        };

        if (std.mem.eql(u8, method, "initialize")) {
            if (!self.initialized) {
                const result = protocol.InitializeResult{
                    .protocolVersion = "2024-11-05",
                    .capabilities = .{
                        .tools = .{},
                        .prompts = null,
                        .resources = null,
                        .logging = .{},
                    },
                    .serverInfo = self.server_info,
                };

                response.result = try self.toJsonValue(result);
                self.initialized = true;
            } else {
                response.@"error" = .{
                    .code = @intFromEnum(protocol.ErrorCode.invalid_request),
                    .message = "Server already initialized",
                    .data = null,
                };
            }
        } else if (std.mem.eql(u8, method, "tools/list")) {
            var tools = std.ArrayList(protocol.Tool).init(self.allocator);
            defer tools.deinit();

            var it = self.tools.iterator();
            while (it.next()) |entry| {
                try tools.append(entry.value_ptr.tool);
            }

            const result = protocol.ListToolsResult{
                .tools = tools.items,
            };
            response.result = try self.toJsonValue(result);
        } else if (std.mem.eql(u8, method, "tools/call")) {
            if (params) |p| {
                const call_params = try self.parseCallToolParams(p);
                if (self.tools.get(call_params.name)) |handler| {
                    const result = try handler.handler(self.allocator, call_params.arguments orelse .{ .null = {} });
                    response.result = try self.toJsonValue(result);
                } else {
                    response.@"error" = .{
                        .code = @intFromEnum(protocol.ErrorCode.invalid_params),
                        .message = "Tool not found",
                        .data = null,
                    };
                }
            }
        } else if (std.mem.eql(u8, method, "notifications/initialized")) {
            // No response needed for notifications
            return;
        } else {
            response.@"error" = .{
                .code = @intFromEnum(protocol.ErrorCode.method_not_found),
                .message = "Method not found",
                .data = null,
            };
        }

        try self.sendResponse(response);
    }

    fn handleNotification(self: *Self, method: []const u8, params: ?json.Value) !void {
        _ = self;
        _ = params;

        if (std.mem.eql(u8, method, "notifications/initialized")) {
            // Client has acknowledged initialization
        }
    }

    fn sendResponse(self: *Self, response: protocol.Response) !void {
        var string = std.ArrayList(u8).init(self.allocator);
        defer string.deinit();

        try json.stringify(response, .{}, string.writer());
        try self.writer.print("{s}\n", .{string.items});
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

    fn parseCallToolParams(self: *Self, params: json.Value) !protocol.CallToolParams {
        _ = self;
        const obj = params.object;
        return .{
            .name = obj.get("name").?.string,
            .arguments = obj.get("arguments"),
        };
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
