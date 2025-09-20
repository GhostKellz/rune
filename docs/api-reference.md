# Rune API Reference

## Core Types

### Client

```zig
pub const Client = struct {
    pub fn connectStdio(allocator: std.mem.Allocator) !Client
    pub fn connectWs(allocator: std.mem.Allocator, url: []const u8) !Client
    pub fn deinit(self: *Client) void
    pub fn initialize(self: *Client, client_info: protocol.ClientInfo) !protocol.InitializeResult
    pub fn listTools(self: *Client) ![]protocol.Tool
    pub fn invoke(self: *Client, call: protocol.ToolCall) !protocol.ToolResult
};
```

#### Methods

**`connectStdio(allocator)`**
- Creates a new MCP client using stdio transport
- Returns: `Client` instance
- Errors: `OutOfMemory`

**`connectWs(allocator, url)`**
- Creates a new MCP client using WebSocket transport (placeholder)
- Returns: `Client` instance
- Errors: `OutOfMemory`, `NotImplemented`

**`initialize(client_info)`**
- Initializes the MCP session with the server
- Returns: `InitializeResult` containing server capabilities
- Errors: `AlreadyInitialized`, `InitializationFailed`, `NoResponse`

**`listTools()`**
- Lists all available tools from the server
- Returns: Array of `Tool` structs
- Errors: `NotInitialized`, `ToolsListFailed`, `NoResponse`

**`invoke(call)`**
- Invokes a tool on the server
- Returns: `ToolResult` with tool output
- Errors: `NotInitialized`, `ToolCallFailed`, `NoResponse`

### Server

```zig
pub const Server = struct {
    pub fn init(allocator: std.mem.Allocator, config: Config) !Server
    pub fn deinit(self: *Server) void
    pub fn registerTool(self: *Server, name: []const u8, handler: ToolHandler) !void
    pub fn registerToolWithDesc(self: *Server, name: []const u8, description: []const u8, handler: ToolHandler) !void
    pub fn run(self: *Server) !void
};
```

#### Configuration

```zig
pub const Config = struct {
    transport: TransportType = .stdio,
    name: []const u8 = "rune-server",
    version: []const u8 = "0.1.0",
};
```

#### Methods

**`init(allocator, config)`**
- Creates a new MCP server
- Returns: `Server` instance
- Errors: `OutOfMemory`

**`registerTool(name, handler)`**
- Registers a tool handler function
- Parameters:
  - `name`: Tool name as it appears to clients
  - `handler`: Function implementing the tool
- Errors: `OutOfMemory`

**`registerToolWithDesc(name, description, handler)`**
- Registers a tool handler with description
- Parameters:
  - `name`: Tool name
  - `description`: Human-readable description
  - `handler`: Function implementing the tool
- Errors: `OutOfMemory`

**`run()`**
- Starts the server main loop (blocking)
- Processes incoming requests until connection closes
- Errors: Transport-specific errors

### Tool Context

```zig
pub const ToolCtx = struct {
    alloc: std.mem.Allocator,
    request_id: protocol.RequestId,
    guard: *SecurityGuard,
    fs: std.fs.File,

    pub fn init(allocator: std.mem.Allocator, request_id: protocol.RequestId) ToolCtx
};
```

The context provided to every tool handler, containing:

- `alloc`: Memory allocator for the tool's use
- `request_id`: Unique identifier for this request
- `guard`: Security interface for permission checks
- `fs`: File system access (current working directory)

### Tool Handler

```zig
pub const ToolHandler = *const fn (ctx: *ToolCtx, params: std.json.Value) anyerror!protocol.ToolResult;
```

Function signature for tool implementations. Receives:
- `ctx`: Tool context with allocator and utilities
- `params`: JSON parameters from the client

Returns:
- `ToolResult`: Result to send back to client

## Protocol Types

### Messages

```zig
pub const JsonRpcMessage = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
};

pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: RequestId,
    method: []const u8,
    params: ?std.json.Value = null,
};

pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};
```

### Tool Types

```zig
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value,
};

pub const ToolCall = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};

pub const ToolResult = struct {
    content: []const ToolContent,
    isError: ?bool = null,
};

pub const ToolContent = union(enum) {
    text: TextContent,
    image: ImageContent,
    resource: ResourceContent,
};
```

### Transport

```zig
pub const TransportType = enum {
    stdio,
    websocket,
    http_sse,
};

pub const Transport = union(TransportType) {
    stdio: StdioTransport,
    websocket: WebSocketTransport,
    http_sse: HttpSseTransport,

    pub fn init(allocator: std.mem.Allocator, transport_type: TransportType) !Transport
    pub fn deinit(self: *Transport) void
    pub fn send(self: *Transport, message: JsonRpcMessage) !void
    pub fn receive(self: *Transport) !?JsonRpcMessage
};
```

## Error Handling

### Common Errors

- `OutOfMemory`: Memory allocation failed
- `NotInitialized`: Client not initialized before use
- `AlreadyInitialized`: Client already initialized
- `NoResponse`: No response received from server
- `NotImplemented`: Feature not yet implemented

### Tool-Specific Errors

- `InvalidParameters`: Tool parameters invalid or missing
- `ToolExecutionError`: Tool handler threw an error
- `PermissionDenied`: Security guard denied permission

## Security

### Permission System

```zig
pub const SecurityGuard = struct {
    pub fn require(self: *SecurityGuard, permission: []const u8, args: anytype) !void
};
```

Use the guard to check permissions before sensitive operations:

```zig
try ctx.guard.require("fs.read", .{ .path = path });
try ctx.guard.require("net.connect", .{ .host = "example.com", .port = 443 });
try ctx.guard.require("env.read", .{ .var = "HOME" });
```

## Examples

### File Reader Tool

```zig
pub fn readFile(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    const path = extractPath(params); // Your parsing logic

    try ctx.guard.require("fs.read", .{ .path = path });

    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{ .text = "File not found" },
            }},
            .isError = true,
        };
    };
    defer file.close();

    const contents = try file.readToEndAlloc(ctx.alloc, 1024 * 1024);

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = contents },
        }},
    };
}
```

### Simple Echo Tool

```zig
pub fn echo(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    const message = switch (params) {
        .object => |obj| if (obj.get("message")) |msg| switch (msg) {
            .string => |s| s,
            else => "Invalid message parameter",
        } else "Missing message parameter",
        else => "Invalid parameters",
    };

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = message },
        }},
    };
}
```

## Implementation Status

Current implementation status of features:

- ✅ **Core Types**: All protocol types defined
- ✅ **Basic Client**: Connection and method calling framework
- ✅ **Basic Server**: Request handling and tool registration
- ✅ **Transport Framework**: Pluggable transport architecture
- ⚠️ **JSON Serialization**: Placeholder implementations
- ⚠️ **stdio Transport**: Basic structure, needs full implementation
- ❌ **WebSocket Transport**: Not implemented
- ❌ **HTTP/SSE Transport**: Not implemented
- ❌ **Full Security**: Basic framework in place

This provides a strong foundation for MCP development with full implementations planned for future releases.