# Rust FFI Integration Guide

Rune provides seamless FFI bindings for Rust projects, enabling you to leverage existing Rust MCP servers and tools while building with Zig's performance and safety.

## Overview

The Rust FFI integration allows you to:

- Use Rune MCP clients from Rust applications
- Embed Zig-based MCP servers in Rust projects
- Bridge between Rust and Zig MCP ecosystems
- Leverage Zig's compile-time optimizations in Rust projects

## Installation

### Rust Side

Add to your `Cargo.toml`:

```toml
[dependencies]
rune-ffi = "0.1.0"  # Planned - not yet published
tokio = { version = "1.0", features = ["full"] }
serde_json = "1.0"
```

### Zig Side

Build the FFI library:

```sh
zig build-lib -O ReleaseFast -dynamic src/ffi.zig
```

## Basic Usage

### Using Rune Client from Rust

```rust
use rune_ffi::{RuneClient, RuneError};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), RuneError> {
    // Connect to MCP server
    let client = RuneClient::new("ws://localhost:7331").await?;

    // Initialize the session
    let init_result = client.initialize("rust-client", "1.0.0").await?;
    println!("Connected to: {}", init_result.server_name);

    // Call a tool
    let result = client.call_tool("read_file", json!({
        "path": "/etc/hosts"
    })).await?;

    println!("Tool result: {}", result);
    Ok(())
}
```

### Exposing Zig Server to Rust

```zig
// src/ffi.zig
const std = @import("std");
const rune = @import("rune");

var global_allocator = std.heap.GeneralPurposeAllocator(.{}){};
var global_server: ?*rune.Server = null;

export fn rune_create_server() ?*anyopaque {
    const allocator = global_allocator.allocator();

    const server = allocator.create(rune.Server) catch return null;
    server.* = rune.Server.init(allocator, .{
        .transport = .stdio,
        .name = "zig-server",
        .version = "1.0.0",
    }) catch return null;

    global_server = server;
    return @ptrCast(server);
}

export fn rune_register_tool(
    server: ?*anyopaque,
    name_ptr: [*:0]const u8,
    handler: *const fn(*rune.ToolCtx, std.json.Value) callconv(.C) anyerror!rune.protocol.ToolResult
) bool {
    const srv: *rune.Server = @ptrCast(@alignCast(server orelse return false));
    const name = std.mem.span(name_ptr);

    srv.registerTool(name, handler) catch return false;
    return true;
}

export fn rune_run_server(server: ?*anyopaque) bool {
    const srv: *rune.Server = @ptrCast(@alignCast(server orelse return false));
    srv.run() catch return false;
    return true;
}

export fn rune_destroy_server(server: ?*anyopaque) void {
    if (server) |srv_ptr| {
        const srv: *rune.Server = @ptrCast(@alignCast(srv_ptr));
        srv.deinit();
        global_allocator.allocator().destroy(srv);
    }
}
```

## Advanced Integration

### Custom Tool from Rust

```rust
use rune_ffi::*;
use std::ffi::CString;

// Define a tool in Rust that gets called from Zig
extern "C" fn rust_http_fetch(
    ctx: *mut ToolCtx,
    params: JsonValue
) -> ToolResult {
    // Implement HTTP fetching in Rust
    // This bridges Rust's HTTP ecosystem with Zig MCP
    todo!("Implement HTTP fetch")
}

fn main() {
    let server = unsafe { rune_create_server() };
    let tool_name = CString::new("http_fetch").unwrap();

    unsafe {
        rune_register_tool(server, tool_name.as_ptr(), rust_http_fetch);
        rune_run_server(server);
        rune_destroy_server(server);
    }
}
```

### Async Bridge

For async Rust code, you'll need a bridge:

```rust
use tokio::sync::mpsc;
use std::sync::Arc;

pub struct AsyncBridge {
    sender: mpsc::UnboundedSender<ToolRequest>,
}

impl AsyncBridge {
    pub fn new() -> (Self, mpsc::UnboundedReceiver<ToolRequest>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (Self { sender }, receiver)
    }

    pub fn call_async_tool(&self, request: ToolRequest) {
        self.sender.send(request).unwrap();
    }
}

// Bridge function that can be called from Zig
extern "C" fn async_tool_bridge(
    ctx: *mut ToolCtx,
    params: JsonValue
) -> ToolResult {
    // Convert to Rust types and send to async handler
    // Return a "pending" result, with actual result delivered via callback
    todo!("Implement async bridge")
}
```

## Type Mappings

### Zig to Rust

| Zig Type | Rust Type | Notes |
|----------|-----------|-------|
| `[]const u8` | `&str` | String slices |
| `std.json.Value` | `serde_json::Value` | JSON values |
| `anyerror` | `Result<T, RuneError>` | Error handling |
| `?T` | `Option<T>` | Optional values |
| `*ToolCtx` | `*mut ToolCtx` | Mutable context pointer |

### Memory Management

- Zig allocator manages memory for Zig-created objects
- Rust manages memory for Rust-created objects
- Strings passed across FFI boundary must be copied or carefully managed
- Use reference counting for shared objects

## Error Handling

```rust
#[derive(Debug, thiserror::Error)]
pub enum RuneError {
    #[error("Connection failed: {0}")]
    ConnectionFailed(String),

    #[error("Tool execution failed: {0}")]
    ToolExecutionFailed(String),

    #[error("Serialization error: {0}")]
    SerializationError(String),

    #[error("FFI error: {0}")]
    FfiError(String),
}

impl From<serde_json::Error> for RuneError {
    fn from(err: serde_json::Error) -> Self {
        RuneError::SerializationError(err.to_string())
    }
}
```

## Performance Considerations

### Zero-Copy Where Possible

```zig
// Zig side - avoid unnecessary allocations
export fn rune_get_tool_result_text(result: *anyopaque) [*:0]const u8 {
    const tool_result: *rune.protocol.ToolResult = @ptrCast(@alignCast(result));
    // Return pointer to existing data rather than copying
    return tool_result.content[0].text.text.ptr;
}
```

```rust
// Rust side - use borrowed data when possible
pub fn get_result_text(result: &ToolResult) -> &str {
    unsafe {
        let ptr = rune_get_tool_result_text(result as *const _ as *mut _);
        CStr::from_ptr(ptr).to_str().unwrap()
    }
}
```

### Batch Operations

```rust
// Batch multiple tool calls for efficiency
pub async fn batch_call_tools(
    client: &RuneClient,
    calls: Vec<ToolCall>
) -> Result<Vec<ToolResult>, RuneError> {
    // Implementation would batch calls to reduce FFI overhead
    todo!()
}
```

## Build Integration

### CMake Integration

```cmake
# FindRune.cmake
find_library(RUNE_LIBRARY
    NAMES rune
    PATHS ${CMAKE_CURRENT_SOURCE_DIR}/lib
)

if(RUNE_LIBRARY)
    add_library(rune SHARED IMPORTED)
    set_target_properties(rune PROPERTIES
        IMPORTED_LOCATION ${RUNE_LIBRARY}
        INTERFACE_INCLUDE_DIRECTORIES ${CMAKE_CURRENT_SOURCE_DIR}/include
    )
endif()
```

### Cargo Build Script

```rust
// build.rs
use std::process::Command;

fn main() {
    // Build Zig library
    let output = Command::new("zig")
        .args(&["build-lib", "-O", "ReleaseFast", "-dynamic", "src/ffi.zig"])
        .current_dir("rune")
        .output()
        .expect("Failed to build Zig library");

    if !output.status.success() {
        panic!("Zig build failed: {}", String::from_utf8_lossy(&output.stderr));
    }

    // Link the library
    println!("cargo:rustc-link-search=native=rune/zig-out/lib");
    println!("cargo:rustc-link-lib=dylib=rune");
}
```

## Implementation Status

🚧 **Work in Progress**: The Rust FFI bindings are planned for a future release. The above examples show the intended API design.

Current status:
- ❌ **FFI Layer**: Not implemented
- ❌ **Rust Crate**: Not published
- ❌ **Type Bindings**: Design phase
- ❌ **Async Bridge**: Planned

Expected timeline:
- **v0.2.0**: Basic FFI layer
- **v0.3.0**: Full Rust integration
- **v0.4.0**: Async support and performance optimizations

For updates, watch the [GitHub repository](https://github.com/ghostkellz/rune) or follow the project's progress.