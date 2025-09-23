//! Rune FFI Interface - C ABI for Glyph (Rust MCP Server) integration
//! Provides high-performance tool execution with zero-copy operations where possible

const std = @import("std");
const root = @import("root.zig");

// Version information for compatibility checking
pub const RUNE_VERSION_MAJOR = 0;
pub const RUNE_VERSION_MINOR = 1;
pub const RUNE_VERSION_PATCH = 0;

// Error codes for FFI boundary
pub const RuneError = enum(c_int) {
    SUCCESS = 0,
    INVALID_ARGUMENT = -1,
    OUT_OF_MEMORY = -2,
    TOOL_NOT_FOUND = -3,
    EXECUTION_FAILED = -4,
    VERSION_MISMATCH = -5,
    THREAD_SAFETY_VIOLATION = -6,
    IO_ERROR = -7,
    PERMISSION_DENIED = -8,
    TIMEOUT = -9,
    UNKNOWN_ERROR = -99,
};

// Opaque handle types for C API
pub const RuneHandle = *anyopaque;
pub const RuneToolHandle = *anyopaque;
pub const RuneResultHandle = *anyopaque;

// Result structure for tool execution
pub const RuneResult = extern struct {
    success: bool,
    error_code: RuneError,
    data: ?[*]const u8,
    data_len: usize,
    error_message: ?[*]const u8,
    error_len: usize,
};

// Callback function types for async operations
pub const RuneCallback = ?*const fn (user_data: ?*anyopaque, result: *RuneResult) void;
pub const RuneProgressCallback = ?*const fn (user_data: ?*anyopaque, progress: f32, message: ?[*]const u8) void;

// Version info structure
pub const RuneVersion = extern struct {
    major: u32,
    minor: u32,
    patch: u32,
};

// Tool metadata structure
pub const RuneToolInfo = extern struct {
    name: ?[*]const u8,
    name_len: usize,
    description: ?[*]const u8,
    description_len: usize,
};

// Internal Rune context (not exposed to C)
const RuneContext = struct {
    gpa: std.heap.GeneralPurposeAllocator(.{}),
    allocator: std.mem.Allocator,
    server: root.Server,
    mutex: std.Thread.Mutex,
};

// Global context storage (thread-safe)
var global_context: ?*RuneContext = null;
var global_mutex: std.Thread.Mutex = .{};

//-----------------------------------------------------------------------------
// Core FFI Functions
//-----------------------------------------------------------------------------

/// Initialize Rune engine
/// Returns a handle to the Rune instance, or null on failure
export fn rune_init() ?*RuneHandle {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_context != null) {
        // Already initialized
        return @ptrCast(global_context.?);
    }

    // Create GPA allocator for Rune
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // Initialize MCP server
    var server = root.Server.init(allocator, .{}) catch |err| {
        std.log.err("Failed to initialize Rune server: {}", .{err});
        _ = gpa.deinit();
        return null;
    };

    // Create context
    const context = allocator.create(RuneContext) catch |err| {
        std.log.err("Failed to allocate Rune context: {}", .{err});
        server.deinit();
        _ = gpa.deinit();
        return null;
    };

    context.* = RuneContext{
        .gpa = gpa,
        .allocator = allocator,
        .server = server,
        .mutex = .{},
    };

    global_context = context;
    return @ptrCast(context);
}

/// Cleanup Rune engine
export fn rune_cleanup(handle: ?*RuneHandle) void {
    if (handle == null) return;

    global_mutex.lock();
    defer global_mutex.unlock();

    const context = @as(*RuneContext, @ptrCast(handle));
    if (global_context != context) return;

    // Deinit server
    context.server.deinit();

    // Deinit allocator (GPA)
    _ = context.gpa.deinit();

    // Free context
    std.heap.raw_c_allocator.destroy(context);
    global_context = null;
}

/// Get Rune version information
export fn rune_get_version() RuneVersion {
    return RuneVersion{
        .major = RUNE_VERSION_MAJOR,
        .minor = RUNE_VERSION_MINOR,
        .patch = RUNE_VERSION_PATCH,
    };
}

//-----------------------------------------------------------------------------
// Tool Management Functions
//-----------------------------------------------------------------------------

/// Register a tool with the Rune engine
/// Returns error code, 0 on success
export fn rune_register_tool(
    handle: ?*RuneHandle,
    name: ?[*]const u8,
    name_len: usize,
    description: ?[*]const u8,
    description_len: usize,
) RuneError {
    if (handle == null or name == null) return .INVALID_ARGUMENT;

    const context = @as(*RuneContext, @ptrCast(handle));
    context.mutex.lock();
    defer context.mutex.unlock();

    const tool_name = name.?[0..name_len];
    const tool_desc = if (description != null and description_len > 0)
        description.?[0..description_len]
    else
        null;

    // Create a generic tool handler that will be specialized at runtime
    const tool_handler = struct {
        fn toolHandler(ctx: *root.ToolCtx, params: std.json.Value) anyerror!root.protocol.ToolResult {
            _ = ctx;
            _ = params;
            // This will be replaced with actual tool implementations
            return root.protocol.ToolResult{
                .content = &[_]root.protocol.ToolContent{
                    .{ .text = .{ .text = "Tool not implemented yet" } },
                },
            };
        }
    }.toolHandler;

    if (tool_desc) |desc| {
        context.server.registerToolWithDesc(tool_name, desc, tool_handler) catch |err| {
            std.log.err("Failed to register tool: {}", .{err});
            return .EXECUTION_FAILED;
        };
    } else {
        context.server.registerTool(tool_name, tool_handler) catch |err| {
            std.log.err("Failed to register tool: {}", .{err});
            return .EXECUTION_FAILED;
        };
    }

    return .SUCCESS;
}

/// Get number of registered tools
export fn rune_get_tool_count(handle: ?*RuneHandle) usize {
    if (handle == null) return 0;

    const context = @as(*RuneContext, @ptrCast(handle));
    context.mutex.lock();
    defer context.mutex.unlock();

    return context.server.tools.items.len;
}

/// Get tool information by index
export fn rune_get_tool_info(
    handle: ?*RuneHandle,
    index: usize,
    out_info: ?*RuneToolInfo,
) RuneError {
    if (handle == null or out_info == null) return .INVALID_ARGUMENT;

    const context = @as(*RuneContext, @ptrCast(handle));
    context.mutex.lock();
    defer context.mutex.unlock();

    if (index >= context.server.tools.items.len) return .INVALID_ARGUMENT;

    const tool = &context.server.tools.items[index];
    out_info.?.* = RuneToolInfo{
        .name = tool.name.ptr,
        .name_len = tool.name.len,
        .description = if (tool.description) |desc| desc.ptr else null,
        .description_len = if (tool.description) |desc| desc.len else 0,
    };

    return .SUCCESS;
}

//-----------------------------------------------------------------------------
// Tool Execution Functions
//-----------------------------------------------------------------------------

/// Execute a tool synchronously
/// Returns a result handle that must be freed with rune_free_result
export fn rune_execute_tool(
    handle: ?*RuneHandle,
    name: ?[*]const u8,
    name_len: usize,
    params_json: ?[*]const u8,
    params_len: usize,
) ?*RuneResultHandle {
    if (handle == null or name == null) return null;

    const context = @as(*RuneContext, @ptrCast(handle));
    context.mutex.lock();
    defer context.mutex.unlock();

    const tool_name = name.?[0..name_len];
    const params_str = if (params_json != null and params_len > 0)
        params_json.?[0..params_len]
    else
        "{}";

    // Parse JSON parameters
    var parsed_params = std.json.parseFromSlice(std.json.Value, context.allocator, params_str, .{}) catch |err| {
        std.log.err("Failed to parse tool params: {}", .{err});
        return createErrorResult(context.allocator, .INVALID_ARGUMENT, "Invalid JSON parameters");
    };
    defer parsed_params.deinit();

    // Find and execute tool
    for (context.server.tools.items) |tool| {
        if (std.mem.eql(u8, tool.name, tool_name)) {
            var ctx = root.ToolCtx.init(context.allocator, .{ .null = {} });
            _ = tool.handler(&ctx, parsed_params.value) catch |err| {
                std.log.err("Tool execution failed: {}", .{err});
                return createErrorResult(context.allocator, .EXECUTION_FAILED, "Tool execution failed");
            };

            // For now, return a simple success message
            // TODO: Implement proper JSON serialization
            return createSuccessResult(context.allocator, "{\"success\": true}");
        }
    }

    return createErrorResult(context.allocator, .TOOL_NOT_FOUND, "Tool not found");
}

/// Execute a tool asynchronously with callback
export fn rune_execute_tool_async(
    handle: ?*RuneHandle,
    name: ?[*]const u8,
    name_len: usize,
    params_json: ?[*]const u8,
    params_len: usize,
    callback: RuneCallback,
    user_data: ?*anyopaque,
) RuneError {
    if (handle == null or name == null or callback == null) return .INVALID_ARGUMENT;

    // For now, execute synchronously and call callback immediately
    // TODO: Implement actual async execution with thread pool
    const result_handle = rune_execute_tool(handle, name, name_len, params_json, params_len);
    if (result_handle) |result_h| {
        const result = @as(*RuneResult, @ptrCast(result_h));
        callback.?(@as(?*anyopaque, @ptrCast(user_data)), result);
    }

    return .SUCCESS;
}

//-----------------------------------------------------------------------------
// Memory Management Functions
//-----------------------------------------------------------------------------

/// Free a result handle
export fn rune_free_result(handle: ?*RuneResultHandle) void {
    if (handle == null) return;

    const result = @as(*RuneResult, @ptrCast(handle));
    const allocator = std.heap.raw_c_allocator;

    // Free allocated strings
    if (result.data != null) {
        allocator.free(@as([*]const u8, @ptrCast(result.data.?))[0..result.data_len]);
    }
    if (result.error_message != null) {
        allocator.free(@as([*]const u8, @ptrCast(result.error_message.?))[0..result.error_len]);
    }

    // Free the result structure itself
    allocator.destroy(result);
}

/// Allocate memory (for Glyph to use when passing data to Rune)
export fn rune_alloc(size: usize) ?*anyopaque {
    const slice = std.heap.raw_c_allocator.alloc(u8, size) catch return null;
    return @ptrCast(slice.ptr);
}

/// Free memory allocated by rune_alloc
export fn rune_free(ptr: ?*anyopaque, size: usize) void {
    if (ptr == null) return;
    std.heap.raw_c_allocator.free(@as([*]u8, @ptrCast(ptr.?))[0..size]);
}

//-----------------------------------------------------------------------------
// Utility Functions
//-----------------------------------------------------------------------------

/// Get last error message (thread-local)
export fn rune_get_last_error() ?[*]const u8 {
    // TODO: Implement thread-local error storage
    return null;
}

//-----------------------------------------------------------------------------
// Internal Helper Functions
//-----------------------------------------------------------------------------

fn createSuccessResult(allocator: std.mem.Allocator, data: []const u8) ?*RuneResultHandle {
    const result = std.heap.raw_c_allocator.create(RuneResult) catch return null;
    const data_copy = allocator.dupe(u8, data) catch {
        std.heap.raw_c_allocator.destroy(result);
        return null;
    };

    result.* = RuneResult{
        .success = true,
        .error_code = .SUCCESS,
        .data = data_copy.ptr,
        .data_len = data_copy.len,
        .error_message = null,
        .error_len = 0,
    };

    return @ptrCast(result);
}

fn createErrorResult(allocator: std.mem.Allocator, err: RuneError, message: []const u8) ?*RuneResultHandle {
    const result = std.heap.raw_c_allocator.create(RuneResult) catch return null;
    const msg_copy = allocator.dupe(u8, message) catch {
        std.heap.raw_c_allocator.destroy(result);
        return null;
    };

    result.* = RuneResult{
        .success = false,
        .error_code = err,
        .data = null,
        .data_len = 0,
        .error_message = msg_copy.ptr,
        .error_len = msg_copy.len,
    };

    return @ptrCast(result);
}

//-----------------------------------------------------------------------------
// Test Functions (only available in debug builds)
//-----------------------------------------------------------------------------

test "FFI interface basic functionality" {
    // Test version
    const version = rune_get_version();
    try std.testing.expectEqual(@as(u32, 0), version.major);
    try std.testing.expectEqual(@as(u32, 1), version.minor);
    try std.testing.expectEqual(@as(u32, 0), version.patch);

    // Test initialization
    const handle = rune_init();
    try std.testing.expect(handle != null);

    // Test cleanup
    rune_cleanup(handle);
}
