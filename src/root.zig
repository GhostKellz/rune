//! Rune - Premier Zig library for Model Context Protocol (MCP)
const std = @import("std");

// Export zsync for async operations
pub const zsync = @import("zsync");

// Core MCP types and structures
pub const protocol = @import("protocol.zig");
pub const json_rpc = @import("json_rpc.zig");
pub const transport = @import("transport.zig");
pub const schema = @import("schema.zig");
pub const security = @import("security.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");

// AI Provider integration
pub const ai = @import("ai.zig");

// Re-export main types
pub const Client = client.Client;
pub const Server = server.Server;
pub const ToolCtx = server.ToolCtx;

// MCP Protocol Messages
pub const JsonRpcMessage = protocol.JsonRpcMessage;
pub const Request = protocol.Request;
pub const Response = protocol.Response;
pub const Notification = protocol.Notification;

// Transport types
pub const Transport = transport.Transport;
pub const TransportType = transport.TransportType;

// Async types from zsync
pub const Io = zsync.Io;
pub const Future = zsync.Future;
pub const ExecutionModel = zsync.ExecutionModel;

test {
    std.testing.refAllDecls(@This());
}
