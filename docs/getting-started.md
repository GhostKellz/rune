# Getting Started with Rune

Rune is a Zig library for building Model Context Protocol (MCP) clients and servers. This guide will help you get started quickly.

## Prerequisites

- Zig 0.16.0-dev.164+bc7955306 or later
- Basic understanding of the Model Context Protocol

## Installation

Add Rune to your project using Zig's package manager:

```sh
zig fetch --save https://github.com/ghostkellz/rune/archive/refs/heads/main.tar.gz
```

Then add it to your `build.zig`:

```zig
const rune = b.dependency("rune", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("rune", rune.module("rune"));
```

## Quick Start

### Creating an MCP Server

Here's a minimal MCP server that provides a simple file reading tool:

```zig
const std = @import("std");
const rune = @import("rune");

pub fn readFile(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Extract path from params (simplified example)
    const path = "/etc/hosts"; // In real code, parse from params

    // Optional consent check
    try ctx.guard.require("fs.read", .{});

    // Read file (simplified implementation)
    const contents = "# Example hosts file content";

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{
                .text = contents,
            },
        }},
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var srv = try rune.Server.init(allocator, .{ .transport = .stdio });
    defer srv.deinit();

    try srv.registerTool("read_file", readFile);
    try srv.run();
}
```

### Creating an MCP Client

Here's a basic MCP client that can connect to and communicate with an MCP server:

```zig
const std = @import("std");
const rune = @import("rune");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var client = try rune.Client.connectStdio(allocator);
    defer client.deinit();

    // Initialize the MCP session
    const client_info = rune.protocol.ClientInfo{
        .name = "my-client",
        .version = "1.0.0",
    };

    const init_result = try client.initialize(client_info);
    std.debug.print("Connected to: {s}\n", .{init_result.serverInfo.name});

    // List available tools
    const tools = try client.listTools();
    std.debug.print("Available tools: {d}\n", .{tools.len});

    // Call a tool
    const result = try client.invoke(.{
        .name = "read_file",
        .arguments = .{ .object = std.json.ObjectMap.init(allocator) },
    });

    for (result.content) |content| {
        switch (content) {
            .text => |text| std.debug.print("Result: {s}\n", .{text.text}),
            else => {},
        }
    }
}
```

## Core Concepts

### Transport Layer

Rune supports multiple transport mechanisms:

- **stdio**: Standard input/output (most common for MCP)
- **WebSocket**: Real-time bidirectional communication (planned)
- **HTTP/SSE**: Server-sent events for web integration (planned)

### Protocol Types

Key types you'll work with:

- `rune.Client`: MCP client for calling tools and resources
- `rune.Server`: MCP server for providing tools and resources
- `rune.ToolCtx`: Context provided to tool handlers
- `rune.protocol.ToolResult`: Result returned by tool handlers

### Security

Rune includes optional security features through the `ToolCtx.guard` interface:

```zig
pub fn myTool(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Require permission before accessing filesystem
    try ctx.guard.require("fs.read", .{});

    // ... tool implementation
}
```

## Next Steps

- Read the [API Reference](api-reference.md) for detailed information
- Check out the [examples](../examples/) directory for more complex use cases
- Explore the [MCP specification](https://spec.modelcontextprotocol.io/) for protocol details

## Current Status

⚠️ **Note**: Rune is currently in early development. The current implementation provides:

- ✅ Core protocol type definitions
- ✅ Basic client and server abstractions
- ✅ Transport layer framework
- ⚠️ Placeholder implementations for complex serialization
- ⚠️ Basic stdio transport (needs full JSON handling)

This provides a solid foundation for building MCP applications, with full implementations coming in future releases.