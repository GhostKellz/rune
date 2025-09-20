//! Model Context Protocol (MCP) core protocol definitions
const std = @import("std");

/// JSON-RPC 2.0 Message types
pub const JsonRpcMessage = union(enum) {
    request: Request,
    response: Response,
    notification: Notification,
};

/// JSON-RPC 2.0 Request
pub const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: RequestId,
    method: []const u8,
    params: ?std.json.Value = null,
};

/// JSON-RPC 2.0 Response
pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?RequestId,
    result: ?std.json.Value = null,
    @"error": ?JsonRpcError = null,
};

/// JSON-RPC 2.0 Notification
pub const Notification = struct {
    jsonrpc: []const u8 = "2.0",
    method: []const u8,
    params: ?std.json.Value = null,
};

/// Request ID can be string, number, or null
pub const RequestId = union(enum) {
    string: []const u8,
    number: i64,
    null: void,
};

/// JSON-RPC Error object
pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// MCP-specific method names
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

/// MCP Tool definition
pub const Tool = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    inputSchema: std.json.Value,
};

/// MCP Tool call request
pub const ToolCall = struct {
    name: []const u8,
    arguments: ?std.json.Value = null,
};

/// MCP Tool call result
pub const ToolResult = struct {
    content: []const ToolContent,
    isError: ?bool = null,
};

/// Tool content types
pub const ToolContent = union(enum) {
    text: TextContent,
    image: ImageContent,
    resource: ResourceContent,
};

pub const TextContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

pub const ImageContent = struct {
    type: []const u8 = "image",
    data: []const u8,
    mimeType: []const u8,
};

pub const ResourceContent = struct {
    type: []const u8 = "resource",
    resource: Resource,
};

/// MCP Resource definition
pub const Resource = struct {
    uri: []const u8,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

/// MCP Initialize request parameters
pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: ClientInfo,
};

/// MCP Initialize result
pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: ServerInfo,
};

/// Client capabilities
pub const ClientCapabilities = struct {
    roots: ?RootsCapability = null,
    sampling: ?SamplingCapability = null,
};

/// Server capabilities
pub const ServerCapabilities = struct {
    tools: ?ToolsCapability = null,
    resources: ?ResourcesCapability = null,
};

pub const RootsCapability = struct {
    listChanged: ?bool = null,
};

pub const SamplingCapability = struct {};

pub const ToolsCapability = struct {
    listChanged: ?bool = null,
};

pub const ResourcesCapability = struct {
    subscribe: ?bool = null,
    listChanged: ?bool = null,
};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

/// Error codes
pub const ErrorCodes = struct {
    pub const PARSE_ERROR = -32700;
    pub const INVALID_REQUEST = -32600;
    pub const METHOD_NOT_FOUND = -32601;
    pub const INVALID_PARAMS = -32602;
    pub const INTERNAL_ERROR = -32603;

    // MCP-specific errors
    pub const INVALID_TOOL = -32000;
    pub const TOOL_EXECUTION_ERROR = -32001;
};

test "protocol types compile" {
    const testing = std.testing;

    const req = Request{
        .id = .{ .string = "test-id" },
        .method = Methods.INITIALIZE,
    };

    try testing.expectEqualStrings("2.0", req.jsonrpc);
    try testing.expectEqualStrings("initialize", req.method);
}