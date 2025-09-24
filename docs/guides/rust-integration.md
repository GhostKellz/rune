# Rust Project Integration Guide

This guide shows you how to integrate Rune into your Rust projects using the FFI (Foreign Function Interface) layer. The FFI allows you to leverage Rune's high-performance MCP implementation from your Rust applications.

## Prerequisites

- **Rust 1.70+** with Cargo
- **Zig 0.16.0-dev+** for building Rune
- **C compiler** (gcc, clang, or msvc) for linking

## Quick Start

### 1. Build Rune FFI Library

First, clone and build the Rune FFI library:

```bash
git clone https://github.com/ghostkellz/rune.git
cd rune
zig build
```

This produces:
- `zig-out/lib/librune.a` - Static library
- `zig-out/include/rune.h` - C header file

### 2. Create Rust Project

```bash
cargo new my-mcp-app
cd my-mcp-app
```

### 3. Add Dependencies

Update `Cargo.toml`:

```toml
[package]
name = "my-mcp-app"
version = "0.1.0"
edition = "2021"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1.0", features = ["full"] }

[build-dependencies]
cc = "1.0"
```

### 4. Create Build Script

Create `build.rs`:

```rust
use std::env;
use std::path::PathBuf;

fn main() {
    // Tell cargo to look for shared libraries in the specified directory
    println!("cargo:rustc-link-search=/path/to/rune/zig-out/lib");

    // Tell cargo to tell rustc to link the rune library
    println!("cargo:rustc-link-lib=static=rune");

    // Link system libraries that Rune needs
    println!("cargo:rustc-link-lib=c");

    // On some systems, you might need additional libraries
    #[cfg(target_os = "linux")]
    {
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=pthread");
    }

    // Tell cargo to invalidate the built crate whenever the wrapper changes
    println!("cargo:rerun-if-changed=wrapper.h");

    // Generate bindings
    let bindings = bindgen::Builder::default()
        .header("/path/to/rune/zig-out/include/rune.h")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks))
        .generate()
        .expect("Unable to generate bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("Couldn't write bindings!");
}
```

Add bindgen to `Cargo.toml`:

```toml
[build-dependencies]
cc = "1.0"
bindgen = "0.68"
```

### 5. Create Rust Wrapper

Create `src/rune_ffi.rs`:

```rust
#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

use std::ffi::{CStr, CString};
use std::ptr;
use std::slice;

/// Safe Rust wrapper for Rune handle
pub struct RuneEngine {
    handle: *mut RuneHandle,
}

/// Tool execution result
#[derive(Debug)]
pub struct ToolResult {
    pub success: bool,
    pub data: Option<String>,
    pub error_message: Option<String>,
}

impl RuneEngine {
    /// Initialize a new Rune engine instance
    pub fn new() -> Result<Self, String> {
        unsafe {
            let handle = rune_init();
            if handle.is_null() {
                Err("Failed to initialize Rune engine".to_string())
            } else {
                Ok(RuneEngine { handle })
            }
        }
    }

    /// Get the Rune version
    pub fn version() -> (u32, u32, u32) {
        unsafe {
            let version = rune_get_version();
            (version.major, version.minor, version.patch)
        }
    }

    /// Register a tool with the engine
    pub fn register_tool(&mut self, name: &str, description: Option<&str>) -> Result<(), String> {
        let name_cstr = CString::new(name).map_err(|_| "Invalid tool name")?;
        let desc_cstr = description.map(|d| CString::new(d).unwrap());

        unsafe {
            let error_code = rune_register_tool(
                self.handle,
                name_cstr.as_ptr(),
                name.len(),
                desc_cstr.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
                description.map_or(0, |d| d.len()),
            );

            if error_code == RuneError_RUNE_SUCCESS {
                Ok(())
            } else {
                Err(format!("Failed to register tool: {:?}", error_code))
            }
        }
    }

    /// Get the number of registered tools
    pub fn tool_count(&self) -> usize {
        unsafe { rune_get_tool_count(self.handle) }
    }

    /// Execute a tool synchronously
    pub fn execute_tool(&self, name: &str, params: Option<&str>) -> Result<ToolResult, String> {
        let name_cstr = CString::new(name).map_err(|_| "Invalid tool name")?;
        let params_cstr = params.map(|p| CString::new(p).unwrap());

        unsafe {
            let result_handle = rune_execute_tool(
                self.handle,
                name_cstr.as_ptr(),
                name.len(),
                params_cstr.as_ref().map_or(ptr::null(), |c| c.as_ptr()),
                params.map_or(0, |p| p.len()),
            );

            if result_handle.is_null() {
                return Err("Tool execution failed".to_string());
            }

            // Cast to RuneResult
            let result = &*(result_handle as *const RuneResult);

            let tool_result = ToolResult {
                success: result.success,
                data: if !result.data.is_null() {
                    let data_slice = slice::from_raw_parts(result.data as *const u8, result.data_len);
                    Some(String::from_utf8_lossy(data_slice).to_string())
                } else {
                    None
                },
                error_message: if !result.error_message.is_null() {
                    let error_slice = slice::from_raw_parts(result.error_message as *const u8, result.error_len);
                    Some(String::from_utf8_lossy(error_slice).to_string())
                } else {
                    None
                },
            };

            // Clean up result
            rune_free_result(result_handle);

            Ok(tool_result)
        }
    }

    /// Execute a tool asynchronously (simplified example)
    pub async fn execute_tool_async(&self, name: &str, params: Option<&str>) -> Result<ToolResult, String> {
        // For now, we'll use tokio::task::spawn_blocking to run the sync version
        let name = name.to_string();
        let params = params.map(|p| p.to_string());

        tokio::task::spawn_blocking(move || {
            // Note: This is a simplified example. In a real implementation,
            // you'd want to use the actual async FFI functions
            // For now, we just call the sync version
            todo!("Implement actual async execution")
        }).await
        .map_err(|e| format!("Async execution failed: {}", e))?
    }
}

impl Drop for RuneEngine {
    fn drop(&mut self) {
        unsafe {
            rune_cleanup(self.handle);
        }
    }
}

// Thread safety: RuneEngine is Send + Sync if the underlying C library is thread-safe
unsafe impl Send for RuneEngine {}
unsafe impl Sync for RuneEngine {}
```

### 6. Create High-Level Rust API

Create `src/mcp.rs`:

```rust
use crate::rune_ffi::{RuneEngine, ToolResult};
use serde::{Deserialize, Serialize};
use serde_json;
use std::collections::HashMap;

/// High-level MCP server interface
pub struct McpServer {
    engine: RuneEngine,
    tools: HashMap<String, Box<dyn Fn(&str) -> Result<String, String> + Send + Sync>>,
}

/// Tool definition for registration
#[derive(Debug, Serialize, Deserialize)]
pub struct ToolDefinition {
    pub name: String,
    pub description: String,
    pub parameters: serde_json::Value,
}

/// MCP request structure
#[derive(Debug, Serialize, Deserialize)]
pub struct McpRequest {
    pub tool: String,
    pub parameters: serde_json::Value,
}

/// MCP response structure
#[derive(Debug, Serialize, Deserialize)]
pub struct McpResponse {
    pub success: bool,
    pub data: Option<serde_json::Value>,
    pub error: Option<String>,
}

impl McpServer {
    /// Create a new MCP server
    pub fn new() -> Result<Self, String> {
        Ok(McpServer {
            engine: RuneEngine::new()?,
            tools: HashMap::new(),
        })
    }

    /// Register a tool with a Rust closure
    pub fn register_tool<F>(&mut self, name: &str, description: &str, handler: F) -> Result<(), String>
    where
        F: Fn(&str) -> Result<String, String> + Send + Sync + 'static,
    {
        // Register with the Rune engine
        self.engine.register_tool(name, Some(description))?;

        // Store the Rust handler
        self.tools.insert(name.to_string(), Box::new(handler));

        Ok(())
    }

    /// Execute a tool by name
    pub fn execute_tool(&self, request: &McpRequest) -> Result<McpResponse, String> {
        // Convert parameters to JSON string
        let params_str = serde_json::to_string(&request.parameters)
            .map_err(|e| format!("Failed to serialize parameters: {}", e))?;

        // Execute via Rune engine
        let result = self.engine.execute_tool(&request.tool, Some(&params_str))?;

        if result.success {
            let data = if let Some(data_str) = result.data {
                serde_json::from_str(&data_str).ok()
            } else {
                None
            };

            Ok(McpResponse {
                success: true,
                data,
                error: None,
            })
        } else {
            Ok(McpResponse {
                success: false,
                data: None,
                error: result.error_message,
            })
        }
    }

    /// Get server information
    pub fn info(&self) -> HashMap<String, serde_json::Value> {
        let (major, minor, patch) = RuneEngine::version();
        let mut info = HashMap::new();

        info.insert("name".to_string(), serde_json::Value::String("Rune MCP Server".to_string()));
        info.insert("version".to_string(), serde_json::Value::String(format!("{}.{}.{}", major, minor, patch)));
        info.insert("tool_count".to_string(), serde_json::Value::Number(serde_json::Number::from(self.engine.tool_count())));

        info
    }

    /// List all registered tools
    pub fn list_tools(&self) -> Vec<ToolDefinition> {
        // This is a simplified implementation
        // In a real scenario, you'd query the engine for tool metadata
        self.tools.keys().map(|name| {
            ToolDefinition {
                name: name.clone(),
                description: format!("Tool: {}", name),
                parameters: serde_json::json!({}),
            }
        }).collect()
    }
}
```

### 7. Create Application

Update `src/main.rs`:

```rust
mod rune_ffi;
mod mcp;

use mcp::{McpServer, McpRequest};
use serde_json::json;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("Initializing Rune MCP Server...");

    let mut server = McpServer::new()?;

    // Register some example tools
    server.register_tool(
        "echo",
        "Echo the input message",
        |params| {
            let parsed: serde_json::Value = serde_json::from_str(params)?;
            let message = parsed.get("message")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'message' parameter")?;

            Ok(format!("Echo: {}", message))
        },
    )?;

    server.register_tool(
        "reverse",
        "Reverse a string",
        |params| {
            let parsed: serde_json::Value = serde_json::from_str(params)?;
            let text = parsed.get("text")
                .and_then(|v| v.as_str())
                .ok_or("Missing 'text' parameter")?;

            Ok(text.chars().rev().collect())
        },
    )?;

    server.register_tool(
        "calculate",
        "Perform basic arithmetic",
        |params| {
            let parsed: serde_json::Value = serde_json::from_str(params)?;
            let a = parsed.get("a").and_then(|v| v.as_f64()).ok_or("Missing 'a' parameter")?;
            let b = parsed.get("b").and_then(|v| v.as_f64()).ok_or("Missing 'b' parameter")?;
            let op = parsed.get("operation").and_then(|v| v.as_str()).ok_or("Missing 'operation' parameter")?;

            let result = match op {
                "add" => a + b,
                "subtract" => a - b,
                "multiply" => a * b,
                "divide" => {
                    if b == 0.0 {
                        return Err("Division by zero".to_string());
                    }
                    a / b
                },
                _ => return Err(format!("Unknown operation: {}", op)),
            };

            Ok(result.to_string())
        },
    )?;

    println!("Server initialized with {} tools", server.list_tools().len());

    // Example usage
    println!("\nTesting tools...");

    // Test echo tool
    let echo_request = McpRequest {
        tool: "echo".to_string(),
        parameters: json!({"message": "Hello from Rust!"}),
    };
    let echo_response = server.execute_tool(&echo_request)?;
    println!("Echo result: {:?}", echo_response);

    // Test reverse tool
    let reverse_request = McpRequest {
        tool: "reverse".to_string(),
        parameters: json!({"text": "Rune"}),
    };
    let reverse_response = server.execute_tool(&reverse_request)?;
    println!("Reverse result: {:?}", reverse_response);

    // Test calculate tool
    let calc_request = McpRequest {
        tool: "calculate".to_string(),
        parameters: json!({"a": 10, "b": 5, "operation": "multiply"}),
    };
    let calc_response = server.execute_tool(&calc_request)?;
    println!("Calculate result: {:?}", calc_response);

    // Display server info
    println!("\nServer info: {:?}", server.info());
    println!("Available tools: {:?}", server.list_tools());

    Ok(())
}
```

## Advanced Integration Patterns

### 1. Async Web Server with Rune

Using `axum` web framework:

```toml
# Add to Cargo.toml
[dependencies]
axum = "0.7"
tower = "0.4"
```

```rust
// src/web_server.rs
use axum::{
    extract::State,
    http::StatusCode,
    response::Json,
    routing::{get, post},
    Router,
};
use std::sync::Arc;
use tokio::sync::Mutex;
use crate::mcp::{McpServer, McpRequest, McpResponse};

pub async fn start_web_server() -> Result<(), Box<dyn std::error::Error>> {
    let server = Arc::new(Mutex::new(McpServer::new()?));

    // Register tools...
    {
        let mut server_guard = server.lock().await;
        server_guard.register_tool("web_echo", "Web echo tool", |params| {
            Ok(format!("Web response: {}", params))
        })?;
    }

    let app = Router::new()
        .route("/", get(root))
        .route("/tools", get(list_tools))
        .route("/execute", post(execute_tool))
        .with_state(server);

    let listener = tokio::net::TcpListener::bind("0.0.0.0:3000").await?;
    println!("Server running on http://0.0.0.0:3000");

    axum::serve(listener, app).await?;
    Ok(())
}

async fn root() -> &'static str {
    "Rune MCP Web Server"
}

async fn list_tools(
    State(server): State<Arc<Mutex<McpServer>>>,
) -> Json<serde_json::Value> {
    let server = server.lock().await;
    Json(serde_json::json!({
        "tools": server.list_tools(),
        "info": server.info()
    }))
}

async fn execute_tool(
    State(server): State<Arc<Mutex<McpServer>>>,
    Json(request): Json<McpRequest>,
) -> Result<Json<McpResponse>, StatusCode> {
    let server = server.lock().await;

    match server.execute_tool(&request) {
        Ok(response) => Ok(Json(response)),
        Err(_) => Err(StatusCode::INTERNAL_SERVER_ERROR),
    }
}
```

### 2. Plugin System

```rust
// src/plugin.rs
use libloading::{Library, Symbol};
use std::ffi::CStr;

pub struct PluginManager {
    server: McpServer,
    plugins: Vec<Library>,
}

impl PluginManager {
    pub fn new() -> Result<Self, String> {
        Ok(PluginManager {
            server: McpServer::new()?,
            plugins: Vec::new(),
        })
    }

    pub fn load_plugin(&mut self, path: &str) -> Result<(), String> {
        unsafe {
            let lib = Library::new(path)
                .map_err(|e| format!("Failed to load plugin: {}", e))?;

            // Get plugin initialization function
            let init_fn: Symbol<unsafe extern "C" fn() -> *const i8> = lib
                .get(b"plugin_init")
                .map_err(|e| format!("Plugin missing init function: {}", e))?;

            // Initialize plugin
            let plugin_name_ptr = init_fn();
            let plugin_name = CStr::from_ptr(plugin_name_ptr).to_str()
                .map_err(|e| format!("Invalid plugin name: {}", e))?;

            println!("Loaded plugin: {}", plugin_name);

            self.plugins.push(lib);
            Ok(())
        }
    }
}
```

### 3. Microservice Integration

```rust
// src/microservice.rs
use std::collections::HashMap;
use tokio::net::TcpListener;
use tokio_tungstenite::{accept_async, WebSocketStream};
use futures_util::{SinkExt, StreamExt};

pub struct MicroserviceNode {
    server: McpServer,
    connections: HashMap<String, WebSocketStream<tokio::net::TcpStream>>,
}

impl MicroserviceNode {
    pub fn new() -> Result<Self, String> {
        Ok(MicroserviceNode {
            server: McpServer::new()?,
            connections: HashMap::new(),
        })
    }

    pub async fn start(&mut self, addr: &str) -> Result<(), Box<dyn std::error::Error>> {
        let listener = TcpListener::bind(addr).await?;
        println!("Microservice listening on: {}", addr);

        while let Ok((stream, _)) = listener.accept().await {
            let ws_stream = accept_async(stream).await?;
            tokio::spawn(self.handle_connection(ws_stream));
        }

        Ok(())
    }

    async fn handle_connection(&self, mut ws_stream: WebSocketStream<tokio::net::TcpStream>) {
        while let Some(msg) = ws_stream.next().await {
            match msg {
                Ok(msg) => {
                    if let Ok(text) = msg.to_text() {
                        if let Ok(request) = serde_json::from_str::<McpRequest>(text) {
                            match self.server.execute_tool(&request) {
                                Ok(response) => {
                                    let response_text = serde_json::to_string(&response).unwrap();
                                    let _ = ws_stream.send(tokio_tungstenite::tungstenite::Message::Text(response_text)).await;
                                }
                                Err(e) => {
                                    eprintln!("Tool execution error: {}", e);
                                }
                            }
                        }
                    }
                }
                Err(e) => {
                    eprintln!("WebSocket error: {}", e);
                    break;
                }
            }
        }
    }
}
```

## Build and Deployment

### Docker Integration

```dockerfile
# Dockerfile
FROM rust:1.70 as builder

# Install Zig
RUN curl -L https://ziglang.org/download/0.16.0-dev/zig-linux-x86_64-0.16.0-dev.tar.xz | tar -xJ
ENV PATH="/zig-linux-x86_64-0.16.0-dev:${PATH}"

# Build Rune
WORKDIR /rune
COPY rune/ .
RUN zig build

# Build Rust application
WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
COPY --from=builder /app/target/release/my-mcp-app /usr/local/bin/
CMD ["my-mcp-app"]
```

### Cross-compilation

```bash
# Build for different targets
cargo build --target x86_64-unknown-linux-gnu
cargo build --target aarch64-unknown-linux-gnu
cargo build --target x86_64-pc-windows-gnu
```

## Testing

```rust
// tests/integration_test.rs
use my_mcp_app::mcp::{McpServer, McpRequest};
use serde_json::json;

#[test]
fn test_rune_integration() {
    let mut server = McpServer::new().expect("Failed to create server");

    server.register_tool("test_tool", "Test tool", |params| {
        Ok(format!("Processed: {}", params))
    }).expect("Failed to register tool");

    let request = McpRequest {
        tool: "test_tool".to_string(),
        parameters: json!({"input": "test data"}),
    };

    let response = server.execute_tool(&request).expect("Tool execution failed");
    assert!(response.success);
}

#[tokio::test]
async fn test_async_execution() {
    // Test async tool execution
    // Implementation depends on your async wrapper
}
```

## Performance Considerations

- **Memory Management**: The FFI handles memory allocation/deallocation across the boundary
- **Error Handling**: Always check return codes and handle NULL pointers
- **Thread Safety**: Rune's FFI is thread-safe, but coordinate access appropriately
- **Performance**: FFI calls have overhead; batch operations when possible

## Troubleshooting

### Common Issues

1. **Linking errors**: Ensure librune.a is in the correct path
2. **Symbol not found**: Check that the Rune library was built correctly
3. **Memory issues**: Always free resources using the provided FFI functions
4. **Platform differences**: Some platforms may need additional linker flags

### Debug Configuration

```rust
// Enable debug logging
#[cfg(debug_assertions)]
fn debug_rune_call(name: &str, params: &str) {
    println!("Calling Rune tool: {} with params: {}", name, params);
}
```

This integration guide provides a solid foundation for using Rune from Rust applications, enabling you to leverage Rune's high-performance MCP implementation while maintaining Rust's safety and ecosystem benefits.