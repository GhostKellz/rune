# Quick Start Guide

Get up and running with Rune in just a few minutes! This guide will walk you through creating your first MCP server and client.

## Your First MCP Server

Let's create a simple file reading server that demonstrates core Rune concepts.

### 1. Project Setup

Create a new Zig project:

```bash
mkdir my-mcp-server
cd my-mcp-server
zig init
```

Add Rune dependency to `build.zig.zon`:

```zig
.{
    .name = "my-mcp-server",
    .version = "0.1.0",
    .dependencies = .{
        .rune = .{
            .url = "https://github.com/ghostkellz/rune/archive/refs/heads/main.tar.gz",
            .hash = "your_hash_here", // Run zig build to get the correct hash
        },
    },
}
```

Update `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rune_dep = b.dependency("rune", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-mcp-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rune", .module = rune_dep.module("rune") },
            },
        }),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run the server");
    run_step.dependOn(&run_cmd.step);
}
```

### 2. Implement Your First Tool

Replace `src/main.zig` with:

```zig
const std = @import("std");
const rune = @import("rune");

// Tool function: Read file contents
pub fn readFile(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Extract path parameter
    const path = switch (params) {
        .object => |obj| blk: {
            if (obj.get("path")) |path_value| {
                switch (path_value) {
                    .string => |s| break :blk s,
                    else => return error.InvalidPathParameter,
                }
            } else {
                return error.MissingPathParameter;
            }
        },
        else => return error.InvalidParameters,
    };

    // Security check - require file read permission
    try ctx.guard.require(.fs_read, rune.security.SecurityContext.fileRead(path, "read_file"));

    // Read the file
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{
                    .text = try std.fmt.allocPrint(ctx.alloc, "Error opening file: {}", .{err}),
                },
            }},
            .isError = true,
        };
    };
    defer file.close();

    const contents = file.readToEndAlloc(ctx.alloc, 1024 * 1024) catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{
                    .text = try std.fmt.allocPrint(ctx.alloc, "Error reading file: {}", .{err}),
                },
            }},
            .isError = true,
        };
    };

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = contents },
        }},
    };
}

// Tool function: Get current working directory
pub fn getCurrentDirectory(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    _ = params; // No parameters needed

    // Security check
    try ctx.guard.require(.system_info, .{
        .permission = .system_info,
        .justification = "Get current working directory",
        .tool_name = "get_cwd",
    });

    const cwd = std.fs.cwd().realpathAlloc(ctx.alloc, ".") catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{
                    .text = try std.fmt.allocPrint(ctx.alloc, "Error getting CWD: {}", .{err}),
                },
            }},
            .isError = true,
        };
    };

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = cwd },
        }},
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Create MCP server
    var server = try rune.Server.init(allocator, .{
        .transport = .stdio,
        .name = "file-reader-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Configure security policy (allow safe operations by default)
    server.security_guard.setPolicy(rune.security.PresetPolicies.safeDefaults());

    // Register tools
    try server.registerToolWithDesc(
        "read_file",
        "Read the contents of a file",
        readFile,
    );

    try server.registerToolWithDesc(
        "get_cwd",
        "Get the current working directory",
        getCurrentDirectory,
    );

    std.debug.print("MCP Server starting with {} tools...\n", .{server.tools.items.len});

    // Start the server
    try server.run();
}
```

### 3. Build and Test

```bash
# Build the server
zig build

# Test that it builds successfully
zig build run --help
```

### 4. Test with MCP Client

Create a test file:

```bash
echo "Hello from Rune!" > test.txt
```

Your server is now ready! It can be used with any MCP client.

## Your First MCP Client

Now let's create a simple client to interact with MCP servers.

### 1. Create Client Project

```bash
mkdir my-mcp-client
cd my-mcp-client
zig init
```

Set up the same `build.zig.zon` and `build.zig` as above, but change the executable name to "my-mcp-client".

### 2. Implement the Client

Replace `src/main.zig`:

```zig
const std = @import("std");
const rune = @import("rune");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    // Connect to MCP server via stdio
    var client = try rune.Client.connectStdio(allocator);
    defer client.deinit();

    std.debug.print("Connected to MCP server!\n", .{});

    // Initialize the client
    const client_info = rune.protocol.ClientInfo{
        .name = "file-reader-client",
        .version = "1.0.0",
    };

    try client.initialize(client_info);
    std.debug.print("Client initialized!\n", .{});

    // List available tools
    const tools = try client.listTools();
    std.debug.print("Available tools:\n", .{});
    for (tools) |tool| {
        std.debug.print("  - {s}: {s}\n", .{
            tool.name,
            tool.description orelse "No description",
        });
    }

    // Call the read_file tool
    var args = std.json.ObjectMap.init(allocator);
    defer args.deinit();
    try args.put("path", .{ .string = "test.txt" });

    const result = try client.invoke(.{
        .name = "read_file",
        .arguments = .{ .object = args },
    });

    std.debug.print("\nFile contents:\n", .{});
    for (result.content) |content| {
        switch (content) {
            .text => |text_content| {
                std.debug.print("{s}\n", .{text_content.text});
            },
            else => {},
        }
    }

    // Call the get_cwd tool
    const cwd_result = try client.invoke(.{
        .name = "get_cwd",
        .arguments = null,
    });

    std.debug.print("\nCurrent directory:\n", .{});
    for (cwd_result.content) |content| {
        switch (content) {
            .text => |text_content| {
                std.debug.print("{s}\n", .{text_content.text});
            },
            else => {},
        }
    }
}
```

### 3. Test the Complete Setup

```bash
# Build the client
zig build

# The client will connect to any MCP server
zig build run
```

## Key Concepts Learned

### 1. Tool Functions

Tools are functions that match this signature:

```zig
pub fn toolName(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult
```

- `ctx` provides allocator, security guard, and file system access
- `params` contains JSON parameters from the client
- Return a `ToolResult` with content or error information

### 2. Security Framework

```zig
// Check permissions before performing operations
try ctx.guard.require(.fs_read, context);
```

Rune's security framework prevents unauthorized operations and provides audit logging.

### 3. Transport Layers

```zig
// Different ways to connect
.transport = .stdio     // Standard input/output (most common)
.transport = .websocket // WebSocket for real-time communication
.transport = .http_sse  // HTTP Server-Sent Events
```

### 4. Error Handling

Tools should handle errors gracefully:

```zig
const file = std.fs.cwd().openFile(path, .{}) catch |err| {
    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = try std.fmt.allocPrint(ctx.alloc, "Error: {}", .{err}) },
        }},
        .isError = true,
    };
};
```

## Next Steps

Now that you have a working MCP server and client:

1. **Explore More Tools**: Add more tool functions to your server
2. **Learn Security**: Read the [Security Guide](security.md) to understand permissions
3. **Try Different Transports**: Experiment with WebSocket in the [Transport Guide](transports.md)
4. **Schema Validation**: Add input validation with the [Schema Guide](schemas.md)
5. **Rust Integration**: If you use Rust, check out the [FFI Guide](rust-ffi.md)

## Common Patterns

### Parameter Validation

```zig
pub fn myTool(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    const obj = params.object;

    const name = obj.get("name") orelse return error.MissingName;
    const count = obj.get("count") orelse return error.MissingCount;

    if (name != .string) return error.InvalidNameType;
    if (count != .integer) return error.InvalidCountType;

    // Tool implementation...
}
```

### Multiple Content Types

```zig
return rune.protocol.ToolResult{
    .content = &[_]rune.protocol.ToolContent{
        .{ .text = .{ .text = "Processing complete" } },
        .{ .image = .{
            .data = image_data,
            .mimeType = "image/png"
        } },
    },
};
```

### Async Operations

```zig
pub fn longRunningTool(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Start async operation
    // For now, Rune handles this synchronously
    // Future versions will support true async

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = "Operation completed" },
        }},
    };
}
```

You're now ready to build powerful MCP applications with Rune!