//! MCP Server implementation
const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const security = @import("security.zig");
const json_ser = @import("json_serialization.zig");
const zsync = @import("zsync");

/// Tool context provided to tool handlers
pub const ToolCtx = struct {
    alloc: std.mem.Allocator,
    request_id: protocol.RequestId,
    guard: *security.SecurityGuard,
    fs: std.fs.Dir,
    io: zsync.Io, // Add async I/O support

    pub fn init(allocator: std.mem.Allocator, request_id: protocol.RequestId, guard: *security.SecurityGuard, io: zsync.Io) ToolCtx {
        return ToolCtx{
            .alloc = allocator,
            .request_id = request_id,
            .guard = guard,
            .fs = std.fs.cwd(),
            .io = io,
        };
    }
};

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
    capabilities: protocol.ServerCapabilities,
    client_capabilities: ?protocol.ClientCapabilities,
    security_guard: security.SecurityGuard,
    initialized: bool,
    runtime: *zsync.Runtime,
    io: zsync.Io,

    const Self = @This();

    pub const Config = struct {
        transport: transport.TransportType = .stdio,
        name: []const u8 = "rune-server",
        version: []const u8 = "0.1.0",
        execution_model: zsync.ExecutionModel = .auto,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
        // Initialize async runtime
        const runtime_config = zsync.Config{
            .execution_model = if (config.execution_model == .auto)
                zsync.ExecutionModel.detect()
            else
                config.execution_model,
        };
        
        const runtime = try zsync.Runtime.init(allocator, runtime_config);
        const io = runtime.getIo();

        return Self{
            .allocator = allocator,
            .transport = try transport.Transport.init(allocator, config.transport),
            .tools = .{},
            .server_info = .{
                .name = config.name,
                .version = config.version,
            },
            .capabilities = .{
                .tools = .{ .listChanged = true },
                .resources = null,
            },
            .client_capabilities = null,
            .security_guard = security.SecurityGuard.init(allocator),
            .initialized = false,
            .runtime = runtime,
            .io = io,
        };
    }

    pub fn deinit(self: *Self) void {
        self.tools.deinit(self.allocator);
        self.security_guard.deinit();
        self.transport.deinit();
        self.runtime.deinit();
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
        if (self.initialized) {
            const error_response = protocol.Response{
                .id = request.id,
                .@"error" = .{
                    .code = protocol.ErrorCodes.INVALID_REQUEST,
                    .message = "Already initialized",
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

        const init_params = json_ser.fromJsonValue(protocol.InitializeParams, self.allocator, params) catch {
            const error_response = protocol.Response{
                .id = request.id,
                .@"error" = .{
                    .code = protocol.ErrorCodes.INVALID_PARAMS,
                    .message = "Invalid initialize parameters",
                },
            };
            try self.transport.send(.{ .response = error_response });
            return;
        };

        // Store client capabilities
        self.client_capabilities = init_params.capabilities;
        self.initialized = true;

        const result = protocol.InitializeResult{
            .protocolVersion = "2024-11-05",
            .capabilities = .{
                .tools = .{ .listChanged = true },
                .resources = null,
            },
            .serverInfo = self.server_info,
        };

        const result_json = try json_ser.toJsonValue(self.allocator, result);
        defer json_ser.freeJsonValue(self.allocator, result_json);

        const response = protocol.Response{
            .id = request.id,
            .result = result_json,
        };

        try self.transport.send(.{ .response = response });
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

        var tools_list: std.ArrayList(protocol.Tool) = .{};
        defer tools_list.deinit(self.allocator);

        for (self.tools.items) |registered_tool| {
            try tools_list.append(self.allocator, .{
                .name = registered_tool.name,
                .description = registered_tool.description,
                .inputSchema = .{ .object = std.json.ObjectMap.init(self.allocator) },
            });
        }

        // Use proper JSON serialization
        const result = try json_ser.toJsonValue(self.allocator, .{
            .tools = tools_list.items,
        });
        defer json_ser.freeJsonValue(self.allocator, result);

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

        const tool_call = json_ser.fromJsonValue(protocol.ToolCall, self.allocator, params) catch {
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
                var ctx = ToolCtx.init(self.allocator, request.id, &self.security_guard, self.io);

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

                const result_json = try json_ser.toJsonValue(self.allocator, result);
                defer json_ser.freeJsonValue(self.allocator, result_json);

                const response = protocol.Response{
                    .id = request.id,
                    .result = result_json,
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
};

test "server creation" {
    const testing = std.testing;

    var server = try Server.init(testing.allocator, .{});
    defer server.deinit();

    try testing.expect(!server.initialized);
    try testing.expect(server.tools.items.len == 0);
}
