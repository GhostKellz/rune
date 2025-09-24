# Zig Project Integration Guide

This guide shows you how to integrate Rune into your existing or new Zig projects for MCP server and client development.

## Quick Integration

### Add Rune to Existing Project

```bash
# In your project directory
zig fetch --save https://github.com/ghostkellz/rune/archive/refs/heads/main.tar.gz
```

This automatically adds Rune to your `build.zig.zon` file:

```zig
.{
    .name = "your-project",
    .version = "0.1.0",
    .dependencies = .{
        .rune = .{
            .url = "https://github.com/ghostkellz/rune/archive/refs/heads/main.tar.gz",
            .hash = "1220abc123...", // Auto-generated
        },
    },
}
```

### Update Your build.zig

Add Rune to your build configuration:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get Rune dependency
    const rune_dep = b.dependency("rune", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "your-app",
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
}
```

## Integration Patterns

### 1. MCP Server Integration

Transform your existing application into an MCP server:

```zig
// src/mcp_server.zig
const std = @import("std");
const rune = @import("rune");
const YourApp = @import("your_app.zig");

pub fn makeYourAppMcpCompatible() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize your existing app
    var app = try YourApp.init(allocator);
    defer app.deinit();

    // Create MCP server
    var server = try rune.Server.init(allocator, .{
        .transport = .stdio,
        .name = "your-app-mcp",
        .version = "1.0.0",
    });
    defer server.deinit();

    // Register your app's functionality as MCP tools
    try server.registerTool("process_data", wrapProcessData);
    try server.registerTool("get_status", wrapGetStatus);
    try server.registerTool("export_results", wrapExportResults);

    // Start MCP server
    try server.run();
}

// Wrap your existing functions as MCP tools
fn wrapProcessData(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    // Extract parameters from JSON
    const input_data = params.object.get("data").?.string;

    // Security check
    try ctx.guard.require(.fs_read, rune.security.SecurityContext.fileRead(input_data, "process_data"));

    // Call your existing function
    const result = YourApp.processData(ctx.alloc, input_data) catch |err| {
        return rune.protocol.ToolResult{
            .content = &[_]rune.protocol.ToolContent{.{
                .text = .{ .text = try std.fmt.allocPrint(ctx.alloc, "Processing failed: {}", .{err}) },
            }},
            .isError = true,
        };
    };

    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = result },
        }},
    };
}
```

### 2. MCP Client Integration

Add MCP client capabilities to your application:

```zig
// src/mcp_client.zig
const std = @import("std");
const rune = @import("rune");
const YourApp = @import("your_app.zig");

pub const McpIntegration = struct {
    client: rune.Client,
    app: *YourApp,

    pub fn init(allocator: std.mem.Allocator, app: *YourApp, server_endpoint: []const u8) !McpIntegration {
        // Connect to MCP server
        var client = if (std.mem.startsWith(u8, server_endpoint, "ws://"))
            try rune.Client.connectWs(allocator, server_endpoint)
        else
            try rune.Client.connectStdio(allocator);

        // Initialize client
        try client.initialize(.{
            .name = "your-app-client",
            .version = "1.0.0",
        });

        return McpIntegration{
            .client = client,
            .app = app,
        };
    }

    pub fn deinit(self: *McpIntegration) void {
        self.client.deinit();
    }

    // Add MCP capabilities to your existing methods
    pub fn enhancedDataProcessing(self: *McpIntegration, data: []const u8) ![]const u8 {
        // First try local processing
        const local_result = self.app.processData(data) catch {
            // Fallback to MCP server
            return try self.delegateToMcpServer("process_data", data);
        };

        return local_result;
    }

    fn delegateToMcpServer(self: *McpIntegration, tool_name: []const u8, data: []const u8) ![]const u8 {
        var args = std.json.ObjectMap.init(self.client.allocator);
        defer args.deinit();
        try args.put("data", .{ .string = data });

        const result = try self.client.invoke(.{
            .name = tool_name,
            .arguments = .{ .object = args },
        });

        // Extract text result
        for (result.content) |content| {
            switch (content) {
                .text => |text| return text.text,
                else => {},
            }
        }

        return error.NoTextResult;
    }
};
```

### 3. Hybrid Server/Client

Create applications that can both provide and consume MCP services:

```zig
const std = @import("std");
const rune = @import("rune");

pub const HybridMcpApp = struct {
    allocator: std.mem.Allocator,
    server: rune.Server,
    clients: std.ArrayList(rune.Client),

    pub fn init(allocator: std.mem.Allocator) !HybridMcpApp {
        var server = try rune.Server.init(allocator, .{
            .transport = .websocket, // Use WebSocket for network access
            .name = "hybrid-app",
            .version = "1.0.0",
        });

        // Register local tools
        try server.registerTool("local_compute", localComputeTool);
        try server.registerTool("data_analysis", dataAnalysisTool);

        return HybridMcpApp{
            .allocator = allocator,
            .server = server,
            .clients = std.ArrayList(rune.Client).init(allocator),
        };
    }

    pub fn connectToRemoteService(self: *HybridMcpApp, service_url: []const u8) !void {
        var client = try rune.Client.connectWs(self.allocator, service_url);
        try client.initialize(.{
            .name = "hybrid-app-client",
            .version = "1.0.0",
        });
        try self.clients.append(client);
    }

    pub fn orchestrateWorkflow(self: *HybridMcpApp, workflow_params: []const u8) ![]const u8 {
        // Step 1: Use local tool
        var args = std.json.ObjectMap.init(self.allocator);
        defer args.deinit();
        try args.put("input", .{ .string = workflow_params });

        // This would call our local tool (simplified example)
        // const local_result = try self.server.callTool("local_compute", args);

        // Step 2: Use remote service
        if (self.clients.items.len > 0) {
            const remote_result = try self.clients.items[0].invoke(.{
                .name = "remote_processing",
                .arguments = .{ .object = args },
            });

            // Process and return combined results
            for (remote_result.content) |content| {
                switch (content) {
                    .text => |text| return text.text,
                    else => {},
                }
            }
        }

        return "Workflow completed";
    }
};
```

## Advanced Integration Patterns

### 1. Plugin System with MCP

Create a plugin system where plugins are MCP servers:

```zig
pub const PluginManager = struct {
    clients: std.HashMap([]const u8, rune.Client),

    pub fn loadPlugin(self: *PluginManager, plugin_name: []const u8, plugin_path: []const u8) !void {
        // Start plugin as subprocess
        const plugin_process = std.process.Child.init(&[_][]const u8{plugin_path}, self.allocator);
        plugin_process.stdin_behavior = .Pipe;
        plugin_process.stdout_behavior = .Pipe;
        try plugin_process.spawn();

        // Connect to plugin via stdio
        var client = try rune.Client.connectStdio(self.allocator);
        try client.initialize(.{
            .name = "host-app",
            .version = "1.0.0",
        });

        try self.clients.put(plugin_name, client);
    }

    pub fn callPlugin(self: *PluginManager, plugin_name: []const u8, tool_name: []const u8, args: std.json.Value) !rune.protocol.ToolResult {
        const client = self.clients.get(plugin_name) orelse return error.PluginNotFound;
        return try client.invoke(.{
            .name = tool_name,
            .arguments = args,
        });
    }
};
```

### 2. Microservice Communication

Use MCP for microservice communication:

```zig
pub const MicroserviceRegistry = struct {
    services: std.HashMap([]const u8, ServiceConnection),

    const ServiceConnection = struct {
        client: rune.Client,
        health_check_timer: std.time.Timer,
    };

    pub fn registerService(self: *MicroserviceRegistry, service_name: []const u8, endpoint: []const u8) !void {
        var client = try rune.Client.connectWs(self.allocator, endpoint);
        try client.initialize(.{
            .name = "microservice-gateway",
            .version = "1.0.0",
        });

        try self.services.put(service_name, .{
            .client = client,
            .health_check_timer = try std.time.Timer.start(),
        });
    }

    pub fn callService(self: *MicroserviceRegistry, service_name: []const u8, operation: []const u8, data: std.json.Value) !rune.protocol.ToolResult {
        const service = self.services.get(service_name) orelse return error.ServiceNotFound;

        return try service.client.invoke(.{
            .name = operation,
            .arguments = data,
        });
    }
};
```

## Build Configurations

### Development Build

```zig
// build.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rune_dep = b.dependency("rune", .{
        .target = target,
        .optimize = optimize,
    });

    // Development executable with debug info
    const exe = b.addExecutable(.{
        .name = "your-app-dev",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .Debug, // Always debug in dev
            .imports = &.{
                .{ .name = "rune", .module = rune_dep.module("rune") },
            },
        }),
    });

    // Enable more verbose error traces
    exe.root_module.error_tracing = true;

    b.installArtifact(exe);

    // Test step
    const test_step = b.step("test", "Run tests");
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rune", .module = rune_dep.module("rune") },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}
```

### Production Build

```zig
// production-build.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const rune_dep = b.dependency("rune", .{
        .target = target,
        .optimize = .ReleaseFast, // Optimize for speed
    });

    const exe = b.addExecutable(.{
        .name = "your-app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "rune", .module = rune_dep.module("rune") },
            },
        }),
    });

    // Strip debug info for smaller binary
    exe.root_module.strip = true;

    b.installArtifact(exe);
}
```

### Cross-compilation

```zig
// Build for multiple targets
pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
    };

    for (targets) |target_query| {
        const target = b.resolveTargetQuery(target_query);

        const rune_dep = b.dependency("rune", .{
            .target = target,
            .optimize = optimize,
        });

        const exe = b.addExecutable(.{
            .name = b.fmt("your-app-{s}-{s}", .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) }),
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
    }
}
```

## Testing Integration

### Unit Tests with Rune

```zig
// src/tests.zig
const std = @import("std");
const testing = std.testing;
const rune = @import("rune");

test "mcp server integration" {
    var server = try rune.Server.init(testing.allocator, .{
        .transport = .stdio,
        .name = "test-server",
        .version = "1.0.0",
    });
    defer server.deinit();

    try server.registerTool("test_tool", testTool);
    try testing.expect(server.tools.items.len == 1);
}

fn testTool(ctx: *rune.ToolCtx, params: std.json.Value) !rune.protocol.ToolResult {
    _ = params;
    return rune.protocol.ToolResult{
        .content = &[_]rune.protocol.ToolContent{.{
            .text = .{ .text = "test result" },
        }},
    };
}

test "mcp client integration" {
    // Test with mock transport
    var client = try rune.Client.connectStdio(testing.allocator);
    defer client.deinit();

    // Test client initialization
    try client.initialize(.{
        .name = "test-client",
        .version = "1.0.0",
    });
}
```

### Integration Tests

```zig
// tests/integration_test.zig
const std = @import("std");
const testing = std.testing;
const rune = @import("rune");

test "full mcp workflow" {
    // This would test a complete server/client interaction
    // For now, we test the components separately

    // 1. Start server in background thread
    // 2. Connect client
    // 3. Execute tool calls
    // 4. Verify results
    // 5. Cleanup

    try testing.expect(true); // Placeholder
}
```

## Performance Optimization

### Memory Pool Allocation

```zig
const std = @import("std");
const rune = @import("rune");

pub const OptimizedMcpServer = struct {
    server: rune.Server,
    pool_allocator: std.heap.ArenaAllocator,

    pub fn init(base_allocator: std.mem.Allocator) !OptimizedMcpServer {
        var pool = std.heap.ArenaAllocator.init(base_allocator);

        var server = try rune.Server.init(pool.allocator(), .{
            .transport = .stdio,
            .name = "optimized-server",
            .version = "1.0.0",
        });

        return OptimizedMcpServer{
            .server = server,
            .pool_allocator = pool,
        };
    }

    pub fn deinit(self: *OptimizedMcpServer) void {
        self.server.deinit();
        self.pool_allocator.deinit();
    }

    // Reset pool between requests to avoid memory buildup
    pub fn resetPool(self: *OptimizedMcpServer) void {
        _ = self.pool_allocator.reset(.retain_capacity);
    }
};
```

## Troubleshooting

### Common Issues

1. **Build errors**: Ensure Zig version compatibility (0.16.0-dev+)
2. **Hash mismatches**: Run `zig build` to get the correct hash
3. **Module not found**: Check import name matches dependency name
4. **Memory leaks**: Use appropriate allocator patterns

### Debug Configuration

```zig
// Enable debug logging
pub fn build(b: *std.Build) void {
    // ... other config ...

    const exe_options = b.addOptions();
    exe_options.addOption(bool, "enable_debug_logging", true);
    exe.root_module.addOptions("config", exe_options);
}
```

Then in your code:

```zig
const config = @import("config");

pub fn debugLog(comptime fmt: []const u8, args: anytype) void {
    if (config.enable_debug_logging) {
        std.log.debug(fmt, args);
    }
}
```

This guide covers the essential patterns for integrating Rune into your Zig projects, from simple tool wrapping to complex microservice architectures.