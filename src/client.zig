//! MCP Client implementation
const std = @import("std");
const protocol = @import("protocol.zig");
const transport = @import("transport.zig");
const zsync = @import("zsync");
const json_ser = @import("json_serialization.zig");

/// MCP Client for calling tools and resources
pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: transport.Transport,
    next_id: u64,
    initialized: bool,
    runtime: *zsync.Runtime,
    io: zsync.Io,

    const Self = @This();

    pub const Config = struct {
        transport_type: transport.TransportType = .stdio,
        execution_model: zsync.ExecutionModel = .auto,
    };

    /// Create a new client with specified configuration
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
            .transport = try transport.Transport.init(allocator, config.transport_type),
            .next_id = 1,
            .initialized = false,
            .runtime = runtime,
            .io = io,
        };
    }

    /// Connect to MCP server via stdio (convenience wrapper)
    pub fn connectStdio(allocator: std.mem.Allocator) !Self {
        return init(allocator, .{ .transport_type = .stdio });
    }

    /// Connect to MCP server via WebSocket (convenience wrapper)
    pub fn connectWs(allocator: std.mem.Allocator, url: []const u8) !Self {
        _ = url; // TODO: Pass URL to transport configuration
        return init(allocator, .{ .transport_type = .websocket });
    }

    pub fn deinit(self: *Self) void {
        self.transport.deinit();
        self.runtime.deinit();
    }

    /// Initialize the MCP session
    pub fn initialize(self: *Self, client_info: protocol.ClientInfo) !protocol.InitializeResult {
        if (self.initialized) return error.AlreadyInitialized;

        const init_params = protocol.InitializeParams{
            .protocolVersion = "2024-11-05",
            .capabilities = .{},
            .clientInfo = client_info,
        };

        const params_json = try json_ser.toJsonValue(self.allocator, init_params);
        defer json_ser.freeJsonValue(self.allocator, params_json);

        const request = protocol.Request{
            .id = .{ .number = @intCast(self.next_id) },
            .method = protocol.Methods.INITIALIZE,
            .params = params_json,
        };
        self.next_id += 1;

        try self.transport.send(.{ .request = request });

        // Wait for response (async-ready)
        if (try self.transport.receive()) |message| {
            switch (message) {
                .response => |resp| {
                    if (resp.result) |result| {
                        self.initialized = true;
                        return try json_ser.fromJsonValue(protocol.InitializeResult, self.allocator, result);
                    } else if (resp.@"error") |err| {
                        std.log.err("Initialization failed: {s}", .{err.message});
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
            .params = null,
        };
        self.next_id += 1;

        try self.transport.send(.{ .request = request });

        if (try self.transport.receive()) |message| {
            switch (message) {
                .response => |resp| {
                    if (resp.result) |result| {
                        // Parse tools list from result
                        const tools_response = try json_ser.fromJsonValue(
                            struct { tools: []protocol.Tool },
                            self.allocator,
                            result,
                        );
                        return tools_response.tools;
                    } else if (resp.@"error") |err| {
                        std.log.err("Tools list failed: {s}", .{err.message});
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

        const params_json = try json_ser.toJsonValue(self.allocator, call);
        defer json_ser.freeJsonValue(self.allocator, params_json);

        const request = protocol.Request{
            .id = .{ .number = @intCast(self.next_id) },
            .method = protocol.Methods.TOOLS_CALL,
            .params = params_json,
        };
        self.next_id += 1;

        try self.transport.send(.{ .request = request });

        if (try self.transport.receive()) |message| {
            switch (message) {
                .response => |resp| {
                    if (resp.result) |result| {
                        return try json_ser.fromJsonValue(protocol.ToolResult, self.allocator, result);
                    } else if (resp.@"error") |err| {
                        std.log.err("Tool call failed: {s}", .{err.message});
                        return error.ToolCallFailed;
                    }
                },
                else => return error.UnexpectedMessage,
            }
        }

        return error.NoResponse;
    }
};

test "client creation" {
    const testing = std.testing;

    var client = try Client.connectStdio(testing.allocator);
    defer client.deinit();

    try testing.expect(!client.initialized);
    try testing.expect(client.next_id == 1);
}
