const std = @import("std");
const json = std.json;

pub const JsonRpcVersion = "2.0";

pub const Request = struct {
    jsonrpc: []const u8 = JsonRpcVersion,
    id: RequestId,
    method: []const u8,
    params: ?json.Value = null,
};

pub const Response = struct {
    jsonrpc: []const u8 = JsonRpcVersion,
    id: RequestId,
    result: ?json.Value = null,
    @"error": ?Error = null,
};

pub const Notification = struct {
    jsonrpc: []const u8 = JsonRpcVersion,
    method: []const u8,
    params: ?json.Value = null,
};

pub const Error = struct {
    code: i32,
    message: []const u8,
    data: ?json.Value = null,
};

pub const RequestId = union(enum) {
    number: i64,
    string: []const u8,
    null: void,
};

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    server_error = -32000,
    _,
};

pub const InitializeParams = struct {
    protocolVersion: []const u8,
    capabilities: ClientCapabilities,
    clientInfo: ClientInfo,
};

pub const ClientCapabilities = struct {
    roots: ?struct {
        listChanged: ?bool = null,
    } = null,
    sampling: ?struct {} = null,
};

pub const ClientInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const ServerCapabilities = struct {
    tools: ?struct {} = null,
    prompts: ?struct {} = null,
    resources: ?struct {} = null,
    logging: ?struct {} = null,
};

pub const InitializeResult = struct {
    protocolVersion: []const u8,
    capabilities: ServerCapabilities,
    serverInfo: ServerInfo,
};

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    inputSchema: json.Value,
};

pub const CallToolParams = struct {
    name: []const u8,
    arguments: ?json.Value = null,
};

pub const CallToolResult = struct {
    content: []ToolContent,
    isError: ?bool = null,
};

pub const ToolContent = struct {
    type: []const u8,
    text: ?[]const u8 = null,
    data: ?[]const u8 = null,
    mimeType: ?[]const u8 = null,
};

pub const ListToolsResult = struct {
    tools: []Tool,
};

pub const LogLevel = enum {
    debug,
    info,
    warning,
    @"error",
    critical,
};

pub const LoggingMessageParams = struct {
    level: LogLevel,
    logger: ?[]const u8 = null,
    data: json.Value,
};
