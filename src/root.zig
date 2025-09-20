//! Rune - Premier Zig library for Model Context Protocol (MCP)
const std = @import("std");

// Core MCP types and structures
pub const protocol = @import("protocol.zig");
pub const transport = @import("transport.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");

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

test {
    std.testing.refAllDecls(@This());
}
