//! MCP Server implementation
const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");

/// Tool context provided to tool handlers
pub const ToolCtx = struct {
    alloc: std.mem.Allocator,
    request_id: protocol.RequestId,
    guard: *SecurityGuard,
    fs: std.fs.Dir,

    pub fn init(allocator: std.mem.Allocator, request_id: protocol.RequestId) ToolCtx {
        return ToolCtx{
            .alloc = allocator,
            .request_id = request_id,
            .guard = &default_guard,
            .fs = std.fs.cwd(),
        };
    }
};

/// Security guard for consent and permissions (placeholder)
pub const SecurityGuard = struct {
    pub fn require(self: *SecurityGuard, permission: []const u8, args: anytype) !void {
        _ = self;
        _ = permission;
        _ = args;
        // TODO: Implement actual security checks
    }
};

var default_guard = SecurityGuard{};

/// Tool handler function signature
pub const ToolHandler = *const fn (ctx: *ToolCtx, params: std.json.Value) anyerror!protocol.ToolResult;

/// Registered tool
const RegisteredTool = struct {
    name: []const u8,
    handler: ToolHandler,
    description: ?[]const u8 = null,
};

/// MCP Server for providing tools and resources
pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: transport.Transport,
    tools: std.ArrayList(RegisteredTool),
    server_info: protocol.ServerInfo,
    initialized: bool,

    const Self = @This();

    pub const Config = struct {
        transport: transport.TransportType = .stdio,
        name: []const u8 = "rune-server",
        version: []const u8 = "0.1.0",
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        return Self{
            .allocator = allocator,
            .transport = try transport.Transport.init(allocator, config.transport),
            .tools = std.ArrayList(RegisteredTool){},
            .server_info = .{
                .name = config.name,
                .version = config.version,
            },
            .initialized = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.tools.deinit(self.allocator);
        self.transport.deinit();
    }

    /// Register a tool handler
    pub fn registerTool(self: *Self, name: []const u8, handler: ToolHandler) !void {
        try self.tools.append(self.allocator, .{
            .name = name,
            .handler = handler,
        });
    }

    /// Register a tool handler with description
    pub fn registerToolWithDesc(self: *Self, name: []const u8, description: []const u8, handler: ToolHandler) !void {
        try self.tools.append(self.allocator, .{
            .name = name,
            .handler = handler,
            .description = description,
        });
    }

    /// Run the server main loop
    pub fn run(self: *Self) !void {
        while (true) {
            if (try self.transport.receive()) |message| {
                try self.handleMessage(message);
            } else {
                // No more messages, exit gracefully
                break;
            }
        }
    }

    /// Handle incoming JSON-RPC message
    fn handleMessage(self: *Self, message: protocol.JsonRpcMessage) !void {
        switch (message) {
            .request => |req| try self.handleRequest(req),
            .notification => |notif| try self.handleNotification(notif),
            .response => {}, // Servers typically don't handle responses
        }
    }

    /// Handle JSON-RPC request
    fn handleRequest(self: *Self, request: protocol.Request) !void {
        if (std.mem.eql(u8, request.method, protocol.Methods.INITIALIZE)) {
            try self.handleInitialize(request);
        } else if (std.mem.eql(u8, request.method, protocol.Methods.TOOLS_LIST)) {
            try self.handleToolsList(request);
        } else if (std.mem.eql(u8, request.method, protocol.Methods.TOOLS_CALL)) {
            try self.handleToolsCall(request);
        } else {
            // Method not found
            const error_response = protocol.Response{
                .id = request.id,
                .@"error" = .{
                    .code = protocol.ErrorCodes.METHOD_NOT_FOUND,
                    .message = "Method not found",
                },
            };
            try self.transport.send(.{ .response = error_response });
        }
    }

    /// Handle notification (no response expected)
    fn handleNotification(self: *Self, notification: protocol.Notification) !void {
        _ = self;
        _ = notification;
        // TODO: Handle notifications
    }

    /// Handle initialize request
    fn handleInitialize(self: *Self, request: protocol.Request) !void {
        // TODO: Parse and validate initialize params
        _ = request.params;

        const result = protocol.InitializeResult{
            .protocolVersion = "2024-11-05",
            .capabilities = .{
                .tools = .{ .listChanged = true },
                .resources = null,
            },
            .serverInfo = self.server_info,
        };

        const response = protocol.Response{
            .id = request.id,
            .result = try self.valueFromStruct(result),
        };

        try self.transport.send(.{ .response = response });
        self.initialized = true;
    }

    /// Handle tools/list request
    fn handleToolsList(self: *Self, request: protocol.Request) !void {
        if (!self.initialized) {
            const error_response = protocol.Response{
                .id = request.id,
                .@"error" = .{
                    .code = protocol.ErrorCodes.INVALID_REQUEST,
                    .message = "Server not initialized",
                },
            };
            try self.transport.send(.{ .response = error_response });
            return;
        }

        var tools_list = std.ArrayList(protocol.Tool){};
        defer tools_list.deinit(self.allocator);

        for (self.tools.items) |registered_tool| {
            try tools_list.append(self.allocator, .{
                .name = registered_tool.name,
                .description = registered_tool.description,
                .inputSchema = .{ .object = std.json.ObjectMap.init(self.allocator) },
            });
        }

        const result = std.json.Value{ .object = blk: {
            var obj = std.json.ObjectMap.init(self.allocator);
            try obj.put("tools", .{ .array = blk2: {
                var arr = std.json.Array.init(self.allocator);
                for (tools_list.items) |tool| {
                    try arr.append(try self.valueFromStruct(tool));
                }
                break :blk2 arr;
            } });
            break :blk obj;
        } };

        const response = protocol.Response{
            .id = request.id,
            .result = result,
        };

        try self.transport.send(.{ .response = response });
    }

    /// Handle tools/call request
    fn handleToolsCall(self: *Self, request: protocol.Request) !void {
        if (!self.initialized) {
            const error_response = protocol.Response{
                .id = request.id,
                .@"error" = .{
                    .code = protocol.ErrorCodes.INVALID_REQUEST,
                    .message = "Server not initialized",
                },
            };
            try self.transport.send(.{ .response = error_response });
            return;
        }

        const params = request.params orelse {
            const error_response = protocol.Response{
                .id = request.id,
                .@"error" = .{
                    .code = protocol.ErrorCodes.INVALID_PARAMS,
                    .message = "Missing parameters",
                },
            };
            try self.transport.send(.{ .response = error_response });
            return;
        };

        const tool_call = self.structFromValue(protocol.ToolCall, params) catch {
            const error_response = protocol.Response{
                .id = request.id,
                .@"error" = .{
                    .code = protocol.ErrorCodes.INVALID_PARAMS,
                    .message = "Invalid tool call parameters",
                },
            };
            try self.transport.send(.{ .response = error_response });
            return;
        };

        // Find the tool handler
        for (self.tools.items) |registered_tool| {
            if (std.mem.eql(u8, registered_tool.name, tool_call.name)) {
                var ctx = ToolCtx.init(self.allocator, request.id);

                const result = registered_tool.handler(&ctx, tool_call.arguments orelse .null) catch |err| {
                    const error_response = protocol.Response{
                        .id = request.id,
                        .@"error" = .{
                            .code = protocol.ErrorCodes.TOOL_EXECUTION_ERROR,
                            .message = @errorName(err),
                        },
                    };
                    try self.transport.send(.{ .response = error_response });
                    return;
                };

                const response = protocol.Response{
                    .id = request.id,
                    .result = try self.valueFromStruct(result),
                };

                try self.transport.send(.{ .response = response });
                return;
            }
        }

        // Tool not found
        const error_response = protocol.Response{
            .id = request.id,
            .@"error" = .{
                .code = protocol.ErrorCodes.INVALID_TOOL,
                .message = "Tool not found",
            },
        };
        try self.transport.send(.{ .response = error_response });
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

test "server creation" {
    const testing = std.testing;

    var server = try Server.init(testing.allocator, .{});
    defer server.deinit();

    try testing.expect(!server.initialized);
    try testing.expect(server.tools.items.len == 0);
}
