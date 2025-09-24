# Rune Usage Guide

**Rune** is a premier Zig library for the Model Context Protocol (MCP), providing type-safe, high-performance tools for building MCP servers and clients.

## Table of Contents

- [Quick Start](#quick-start)
- [Core Components](#core-components)
- [Building MCP Servers](#building-mcp-servers)
- [Building MCP Clients](#building-mcp-clients)
- [Transport Layers](#transport-layers)
- [Security & Permissions](#security--permissions)
- [Schema Validation](#schema-validation)
- [Rust FFI Integration](#rust-ffi-integration)
- [Examples](#examples)

## Quick Start

### Installation

Add Rune to your `build.zig.zon`:

```zig
.dependencies = .{
    .rune = .{
        .url = "https://github.com/ghostkellz/rune/archive/refs/heads/main.tar.gz",
        .hash = "your_hash_here",
    },
},
```

### Basic MCP Server

```zig
const std = @import("std");
const rune = @import("rune");

pub fn readFile(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Security check
    try ctx.guard.require(.fs_read, rune.security.SecurityContext.fileRead("example.txt", "read_file"));

    // Implementation
    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = "File contents here" },
        }},
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try rune.Server.init(allocator, .{ .transport = .stdio });
    defer server.deinit();

    try server.registerToolWithDesc("read_file", "Read a file from the filesystem", readFile);
    try server.run();
}
```

### Basic MCP Client

```zig
const std = @import("std");
const rune = @import("rune");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = try rune.Client.connectStdio(allocator);
    defer client.deinit();

    // Initialize the client
    const client_info = rune.protocol.ClientInfo{
        .name = "my-client",
        .version = "1.0.0",
    };
    try client.initialize(client_info);

    // List available tools
    const tools = try client.listTools();

    // Call a tool
    const result = try client.invoke(.{
        .name = "read_file",
        .arguments = .{ .object = args_map },
    });

    // Handle result
    for (result.content) |content| {
        switch (content) {
            .text => |text| std.debug.print("Result: {s}\\n", .{text.text}),
            else => {},
        }
    }
}
```

## Core Components

### 1. Protocol Types (`rune.protocol`)

Rune provides comprehensive MCP protocol types:

- `JsonRpcMessage` - Union of request, response, notification
- `Request`, `Response`, `Notification` - Core JSON-RPC 2.0 types
- `Tool`, `ToolCall`, `ToolResult` - MCP tool definitions
- `InitializeParams`, `InitializeResult` - Handshake types

### 2. JSON-RPC Handling (`rune.json_rpc`)

Type-safe JSON-RPC serialization and deserialization:

```zig
const message = try rune.json_rpc.parseMessage(allocator, json_text);
const json_str = try rune.json_rpc.stringifyRequest(allocator, request);
```

### 3. Transport Layer (`rune.transport`)

Multiple transport options:

```zig
// Standard I/O (most common for MCP)
.transport = .stdio

// WebSocket
.transport = .websocket

// HTTP Server-Sent Events
.transport = .http_sse
```

### 4. Schema Validation (`rune.schema`)

JSON Schema validation for tools:

```zig
var validator = rune.schema.Validator.init(allocator);
try validator.validate(schema, json_value);
```

### 5. Security Framework (`rune.security`)

Permission-based security with consent hooks:

```zig
// Set security policy
server.security_guard.setPolicy(rune.security.PresetPolicies.safeDefaults());

// In tool implementation
try ctx.guard.require(.fs_read, rune.security.SecurityContext.fileRead(path, "my_tool"));
```

## Building MCP Servers

### Tool Registration

```zig
// Simple tool registration
try server.registerTool("tool_name", toolHandler);

// With description
try server.registerToolWithDesc("tool_name", "Tool description", toolHandler);
```

### Tool Handler Signature

```zig
pub const ToolHandler = *const fn (ctx: *ToolCtx, params: std.json.Value) anyerror!protocol.ToolResult;

pub fn myTool(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Access allocator
    const allocator = ctx.alloc;

    // Security checks
    try ctx.guard.require(.fs_read, context);

    // File system access
    const file = try ctx.fs.openFile("example.txt", .{});
    defer file.close();

    // Return result
    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = "Success" },
        }},
    };
}
```

### Server Configuration

```zig
const config = rune.Server.Config{
    .transport = .stdio,  // or .websocket, .http_sse
    .name = "my-server",
    .version = "1.0.0",
};

var server = try rune.Server.init(allocator, config);

// Configure security
server.security_guard.setPolicy(rune.security.PresetPolicies.readOnly());
```

## Building MCP Clients

### Connection Types

```zig
// Standard I/O connection
var client = try rune.Client.connectStdio(allocator);

// WebSocket connection
var client = try rune.Client.connectWs(allocator, "ws://localhost:8080");

// HTTP/SSE connection
var client = try rune.Client.connectHttp(allocator, "http://localhost:8080");
```

### Client Operations

```zig
// Initialize
const client_info = rune.protocol.ClientInfo{
    .name = "my-client",
    .version = "1.0.0",
};
try client.initialize(client_info);

// List tools
const tools = try client.listTools();
for (tools) |tool| {
    std.debug.print("Tool: {s} - {s}\\n", .{ tool.name, tool.description orelse "No description" });
}

// Call a tool
var args = std.json.ObjectMap.init(allocator);
try args.put("path", .{ .string = "/etc/hosts" });

const result = try client.invoke(.{
    .name = "read_file",
    .arguments = .{ .object = args },
});
```

## Transport Layers

### Standard I/O (Default)

Perfect for CLI tools and subprocess communication:

```zig
var server = try rune.Server.init(allocator, .{ .transport = .stdio });
```

### WebSocket

For real-time, bidirectional communication:

```zig
var transport = try rune.transport.WebSocketTransport.init(allocator);
try transport.connect("ws://localhost:8080");
```

### HTTP Server-Sent Events

For HTTP-based streaming:

```zig
var transport = try rune.transport.HttpSseTransport.init(allocator);
try transport.connect("http://localhost:8080");
```

## Security & Permissions

### Permission Types

```zig
pub const Permission = enum {
    fs_read,        // File system read
    fs_write,       // File system write
    fs_execute,     // File execution
    network_http,   // HTTP requests
    network_ws,     // WebSocket connections
    process_spawn,  // Process creation
    env_read,       // Environment variable read
    env_write,      // Environment variable write
    system_info,    // System information access
};
```

### Security Policies

```zig
// Preset policies
server.security_guard.setPolicy(rune.security.PresetPolicies.permissive());  // Allow all
server.security_guard.setPolicy(rune.security.PresetPolicies.restrictive()); // Deny all
server.security_guard.setPolicy(rune.security.PresetPolicies.safeDefaults()); // Safe defaults
server.security_guard.setPolicy(rune.security.PresetPolicies.readOnly());     // Read-only

// Custom policy
var policy = rune.security.SecurityPolicy.init();
policy.allow(.fs_read);
policy.deny(.process_spawn);
policy.default_decision = .ask_user;
server.security_guard.setPolicy(policy);
```

### Consent Callbacks

```zig
fn userConsent(context: rune.security.PermissionContext) rune.security.PolicyDecision {
    std.debug.print("Tool '{s}' wants {s} access to: {s}\\n", .{
        context.tool_name orelse "unknown",
        context.permission.toString(),
        context.resource orelse "unknown resource",
    });

    // In a real implementation, you'd prompt the user
    return .allow; // or .deny
}

server.security_guard.setConsentCallback(userConsent);
```

### Audit Logging

```zig
// Get audit log
const log = server.security_guard.getAuditLog();
for (log) |entry| {
    std.debug.print("Permission {s} was {s}\\n", .{
        entry.permission.toString(),
        if (entry.granted) "granted" else "denied",
    });
}

// Clear audit log
server.security_guard.clearAuditLog();
```

## Schema Validation

### Basic Schema

```zig
var schema = rune.schema.Schema{
    .type = .object,
    .required = &[_][]const u8{"name"},
};

var validator = rune.schema.Validator.init(allocator);
try validator.validate(schema, json_value);
```

### Complex Schema

```zig
var properties = std.StringHashMap(rune.schema.Schema).init(allocator);
try properties.put("name", .{ .type = .string, .min_length = 1 });
try properties.put("age", .{ .type = .integer, .minimum = 0 });

const schema = rune.schema.Schema{
    .type = .object,
    .properties = properties,
    .required = &[_][]const u8{"name"},
};
```

### Parse from JSON Schema

```zig
const schema = try rune.schema.parseSchema(allocator, json_schema_value);
defer schema.deinit(allocator);
```

## Rust FFI Integration

Rune provides C-compatible FFI for Rust integration:

### Building the FFI Library

```bash
zig build
# Produces librune.a and rune.h
```

### Rust Integration

```toml
# Cargo.toml
[build-dependencies]
cc = "1.0"

[dependencies]
rune-ffi = { path = "path/to/rune" }
```

```rust
// Rust side
use std::ffi::{CString, CStr};

extern "C" {
    fn rune_init() -> *mut std::ffi::c_void;
    fn rune_cleanup(handle: *mut std::ffi::c_void);
    fn rune_execute_tool(
        handle: *mut std::ffi::c_void,
        name: *const i8,
        name_len: usize,
        params: *const i8,
        params_len: usize,
    ) -> *mut std::ffi::c_void;
}

fn main() {
    unsafe {
        let handle = rune_init();
        // Use the handle...
        rune_cleanup(handle);
    }
}
```

## Examples

### File Operations Tool

```zig
pub fn fileOperations(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    const obj = params.object;
    const operation = obj.get("operation").?.string;
    const path = obj.get("path").?.string;

    if (std.mem.eql(u8, operation, "read")) {
        try ctx.guard.require(.fs_read, rune.security.SecurityContext.fileRead(path, "file_ops"));

        const file = try ctx.fs.openFile(path, .{});
        defer file.close();

        const contents = try file.readToEndAlloc(ctx.alloc, 1024 * 1024);

        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{ .text = contents },
            }},
        };
    }

    return error.UnsupportedOperation;
}
```

### HTTP Request Tool

```zig
pub fn httpRequest(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    const obj = params.object;
    const url = obj.get("url").?.string;

    try ctx.guard.require(.network_http, rune.security.SecurityContext.httpRequest(url, "http_tool"));

    // Implementation would use std.http.Client
    // This is a simplified example

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = "HTTP response here" },
        }},
    };
}
```

### Multi-Transport Server

```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create servers for different transports
    var stdio_server = try rune.Server.init(allocator, .{ .transport = .stdio });
    defer stdio_server.deinit();

    var ws_server = try rune.Server.init(allocator, .{ .transport = .websocket });
    defer ws_server.deinit();

    // Register the same tools on both
    try stdio_server.registerTool("read_file", readFile);
    try ws_server.registerTool("read_file", readFile);

    // Run servers (in real scenario, you'd run them in separate threads)
    try stdio_server.run();
}
```

## Best Practices

1. **Always use security checks** in tool implementations
2. **Handle errors gracefully** and return meaningful error messages
3. **Use appropriate allocators** - tool context provides the right allocator
4. **Clean up resources** properly (files, network connections)
5. **Validate input parameters** before processing
6. **Use schema validation** for complex tool inputs
7. **Log security events** for audit purposes
8. **Test with different transport layers** to ensure compatibility

## Error Handling

```zig
pub fn robustTool(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Validate parameters
    const obj = params.object;
    const path = obj.get("path") orelse {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{ .text = "Missing 'path' parameter" },
            }},
            .isError = true,
        };
    };

    // Security check with proper error handling
    ctx.guard.require(.fs_read, context) catch |err| switch (err) {
        rune.security.SecurityError.PermissionDenied => {
            return rune.protocol.ToolResult{
                .content = &[_]rune.protocol.ToolContent{.{
                    .text = .{ .text = "Permission denied for file access" },
                }},
                .isError = true,
            };
        },
        else => return err,
    };

    // ... rest of implementation
}
```

This guide covers the essential aspects of using Rune for MCP development. For more examples and advanced usage, see the `examples/` directory in the repository.