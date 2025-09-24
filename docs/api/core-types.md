# Core Types API Reference

This document describes the core types and structures that form the foundation of Rune's MCP implementation.

## Protocol Types (`rune.protocol`)

### JSON-RPC 2.0 Types

#### `JsonRpcMessage`

Union type representing any JSON-RPC 2.0 message.

```zig
pub const JsonRpcMessage = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
};
```

#### `Request`

JSON-RPC 2.0 request message.

```zig
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: RequestId,
    method: []const u8,
    params: ?std.json.Value = null,
};
```

**Fields:**
- `jsonrpc`: Always "2.0" for JSON-RPC 2.0
- `id`: Unique identifier for the request
- `method`: Method name to call
- `params`: Optional parameters for the method

#### `Response`

JSON-RPC 2.0 response message.

```zig
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};
```

**Fields:**
- `jsonrpc`: Always "2.0" for JSON-RPC 2.0
- `id`: Request ID this response corresponds to
- `result`: Result data (mutually exclusive with error)
- `@"error"`: Error information (mutually exclusive with result)

#### `Notification`

JSON-RPC 2.0 notification message (no response expected).

```zig
pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};
```

**Fields:**
- `jsonrpc`: Always "2.0" for JSON-RPC 2.0
- `method`: Method name
- `params`: Optional parameters

#### `RequestId`

Request identifier that can be string, number, or null.

```zig
pub const RequestId = union(enum) {
    string: []const u8,
    number: i64,
    null: void,
};
```

#### `JsonRpcError`

Error information for failed requests.

```zig
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};
```

**Fields:**
- `code`: Error code (see ErrorCodes)
- `message`: Human-readable error message
- `data`: Optional additional error data

### MCP-Specific Types

#### `Methods`

Defines all MCP method names as constants.

```zig
pub const Methods = struct {
    // Client -> Server
    pub const INITIALIZE = "initialize";
    pub const TOOLS_LIST = "tools/list";
    pub const TOOLS_CALL = "tools/call";
    pub const RESOURCES_LIST = "resources/list";
    pub const RESOURCES_READ = "resources/read";

    // Server -> Client
    pub const TOOLS_LIST_CHANGED = "notifications/tools/list_changed";
    pub const RESOURCES_LIST_CHANGED = "notifications/resources/list_changed";
};
```

#### `Tool`

Definition of an MCP tool.

```zig
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value,
};
```

**Fields:**
- `name`: Unique tool identifier
- `description`: Optional human-readable description
- `inputSchema`: JSON Schema for tool parameters

#### `ToolCall`

Request to execute a tool.

```zig
pub const ToolCall = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};
```

**Fields:**
- `name`: Name of the tool to execute
- `arguments`: Parameters to pass to the tool

#### `ToolResult`

Result from tool execution.

```zig
pub const ToolResult = struct {
    content: []const ToolContent,
    isError: ?bool = null,
};
```

**Fields:**
- `content`: Array of content items
- `isError`: Whether this represents an error result

#### `ToolContent`

Content returned by tools.

```zig
pub const ToolContent = union(enum) {
    text: TextContent,
    image: ImageContent,
    resource: ResourceContent,
};
```

##### `TextContent`

Text-based content.

```zig
pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};
```

##### `ImageContent`

Image-based content.

```zig
pub const ImageContent = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,
};
```

##### `ResourceContent`

Resource reference content.

```zig
pub const ResourceContent = struct {
    type: []const u8 = "resource",
    resource: Resource,
};
```

#### `Resource`

MCP resource definition.

```zig
pub const Resource = struct {
    uri: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};
```

**Fields:**
- `uri`: Unique resource identifier
- `name`: Optional human-readable name
- `description`: Optional description
- `mimeType`: Optional MIME type

### Initialization Types

#### `InitializeParams`

Parameters for the initialize request.

```zig
pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: ClientInfo,
};
```

#### `InitializeResult`

Result from the initialize request.

```zig
pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: ServerInfo,
};
```

#### `ClientCapabilities`

Capabilities advertised by the client.

```zig
pub const ClientCapabilities = struct {
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
};
```

#### `ServerCapabilities`

Capabilities advertised by the server.

```zig
pub const ServerCapabilities = struct {
    tools: ?ToolsCapability = null,
    resources: ?ResourcesCapability = null,
};
```

#### `ClientInfo`

Information about the client.

```zig
pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};
```

#### `ServerInfo`

Information about the server.

```zig
pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};
```

### Capability Types

#### `RootsCapability`

```zig
pub const RootsCapability = struct {
    listChanged: ?bool = null,
};
```

#### `SamplingCapability`

```zig
pub const SamplingCapability = struct {};
```

#### `ToolsCapability`

```zig
pub const ToolsCapability = struct {
    listChanged: ?bool = null,
};
```

#### `ResourcesCapability`

```zig
pub const ResourcesCapability = struct {
    subscribe: ?bool = null,
    listChanged: ?bool = null,
};
```

### Error Codes

#### `ErrorCodes`

Standard JSON-RPC and MCP-specific error codes.

```zig
pub const ErrorCodes = struct {
    // Standard JSON-RPC errors
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;

    // MCP-specific errors
    pub const INVALID_TOOL = -32000;
    pub const TOOL_EXECUTION_ERROR = -32001;
};
```

## JSON-RPC Serialization (`rune.json_rpc`)

### Error Types

```zig
pub const JsonRpcError = error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    InvalidTool,
    ToolExecutionError,
};
```

### Functions

#### `parseMessage`

Parse a JSON-RPC message from a string.

```zig
pub fn parseMessage(allocator: std.mem.Allocator, json_text: []const u8) !protocol.JsonRpcMessage
```

**Parameters:**
- `allocator`: Memory allocator for parsing
- `json_text`: JSON string to parse

**Returns:** Parsed JSON-RPC message

**Errors:** `JsonRpcError` variants for invalid input

#### `stringifyRequest`

Serialize a request to JSON string.

```zig
pub fn stringifyRequest(allocator: std.mem.Allocator, request: protocol.Request) ![]u8
```

**Parameters:**
- `allocator`: Memory allocator for result
- `request`: Request to serialize

**Returns:** JSON string (caller must free)

#### `stringifyResponse`

Serialize a response to JSON string.

```zig
pub fn stringifyResponse(allocator: std.mem.Allocator, response: protocol.Response) ![]u8
```

**Parameters:**
- `allocator`: Memory allocator for result
- `response`: Response to serialize

**Returns:** JSON string (caller must free)

#### `stringifyNotification`

Serialize a notification to JSON string.

```zig
pub fn stringifyNotification(allocator: std.mem.Allocator, notification: protocol.Notification) ![]u8
```

**Parameters:**
- `allocator`: Memory allocator for result
- `notification`: Notification to serialize

**Returns:** JSON string (caller must free)

## Transport Types (`rune.transport`)

### Enums

#### `TransportType`

Available transport mechanisms.

```zig
pub const TransportType = enum {
    stdio,
    websocket,
    http_sse,
};
```

### Transport Interface

#### `Transport`

Union type providing a unified interface for all transport types.

```zig
pub const Transport = union(TransportType) {
    stdio: StdioTransport,
    websocket: WebSocketTransport,
    http_sse: HttpSseTransport,

    pub fn init(allocator: std.mem.Allocator, transport_type: TransportType) !Transport;
    pub fn deinit(self: *Transport) void;
    pub fn send(self: *Transport, message: protocol.JsonRpcMessage) !void;
    pub fn receive(self: *Transport) !?protocol.JsonRpcMessage;
};
```

**Methods:**
- `init`: Create a new transport instance
- `deinit`: Clean up transport resources
- `send`: Send a message
- `receive`: Receive a message (blocking)

## Usage Examples

### Basic Message Creation

```zig
const std = @import("std");
const rune = @import("rune");

// Create a request
const request = rune.protocol.Request{
    .id = .{ .string = "req-123" },
    .method = rune.protocol.Methods.TOOLS_LIST,
    .params = null,
};

// Create a response
const response = rune.protocol.Response{
    .id = .{ .string = "req-123" },
    .result = .{ .object = std.json.ObjectMap.init(allocator) },
};

// Create a tool result
const tool_result = rune.protocol.ToolResult{
    .content = &[_]rune.protocol.ToolContent{.{
        .text = .{ .text = "Hello, world!" },
    }},
};
```

### JSON-RPC Serialization

```zig
const allocator = std.heap.page_allocator;

// Parse a message
const json_text = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
const message = try rune.json_rpc.parseMessage(allocator, json_text);
defer freeMessage(allocator, message);

// Serialize a request
const json_str = try rune.json_rpc.stringifyRequest(allocator, request);
defer allocator.free(json_str);
```

### Transport Usage

```zig
// Create a transport
var transport = try rune.transport.Transport.init(allocator, .stdio);
defer transport.deinit();

// Send a message
try transport.send(.{ .request = request });

// Receive a message
if (try transport.receive()) |received_message| {
    // Process the message
}
```

These core types form the foundation of all MCP communication in Rune, providing type-safe, efficient handling of the protocol while maintaining flexibility for different use cases.