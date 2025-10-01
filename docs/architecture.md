# Rune Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Rune Ecosystem                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Zeke      │  │ Gemini CLI  │  │     Claude Code         │  │
│  │ (Zig pkg)   │  │ (MCP client)│  │    (MCP client)         │  │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘  │
│         │                 │                       │             │
│         │                 │                       │             │
│         │     ┌───────────┴─────────────┬─────────┘             │
│         │     │                         │                       │
│  ┌──────▼─────▼─────────────────────────▼─────────────────────┐  │
│  │                  Rune Core                                │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │  │
│  │  │ MCP Server  │  │ MCP Client  │  │   Providers     │   │  │
│  │  │  (stdio)    │  │  (TCP/WS)   │  │ (Ollama/OpenAI) │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │  │
│  │  │    Tools    │  │ File Ops    │  │    Benchmark    │   │  │
│  │  │  (search)   │  │ (R/W/Seek)  │  │  (perf test)    │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │  │
│  └─────────────────────────────────────────────────────────┘  │
│                              │                                 │
│  ┌───────────────────────────▼─────────────────────────────┐   │
│  │                     FFI Layer                           │   │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐  │   │
│  │  │ OMEN (Rust) │  │ C/C++ Apps  │  │  Other Langs    │  │   │
│  │  │   Gateway   │  │   (native)  │  │   (bindings)    │  │   │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. MCP Protocol Layer (`src/mcp/`)

**Purpose**: Implements Model Context Protocol for tool interoperability

```
mcp/
├── protocol.zig    # JSON-RPC 2.0 types and structures
├── server.zig      # MCP server implementation
└── client.zig      # MCP client implementation
```

**Key Design Decisions**:
- JSON-RPC 2.0 over stdio/TCP for maximum compatibility
- Async-first design with streaming support
- Zero-copy JSON parsing where possible
- Type-safe request/response handling

### 2. Provider Abstraction (`src/providers/`)

**Purpose**: Unified interface for AI model providers

```
providers/
├── base.zig        # Provider trait and common types
├── ollama.zig      # Ollama provider implementation
├── openai.zig      # OpenAI-compatible APIs
├── anthropic.zig   # Anthropic Claude API
└── azure.zig       # Azure OpenAI Service
```

**Key Design Decisions**:
- Trait-based polymorphism using Zig's comptime
- Streaming response support with iterator pattern
- Error type unification across providers
- Configurable retry and rate limiting

### 3. Tool System

**Purpose**: Extensible tool registry for MCP server

```zig
pub const ToolHandler = struct {
    tool: protocol.Tool,
    handler: *const fn (allocator: std.mem.Allocator, params: json.Value) anyerror!protocol.CallToolResult,
};
```

**Built-in Tools**:
- `file_read`: Read file contents with path validation
- `file_write`: Write file with backup and atomic operations
- `text_search`: SIMD-accelerated pattern matching
- `shell_exec`: Sandboxed command execution
- `web_fetch`: HTTP client with caching

### 4. FFI Layer (`src/ffi.zig`)

**Purpose**: C ABI for cross-language integration

```c
// C Header (include/rune.h)
typedef struct RuneClient RuneClient;
typedef struct RuneServer RuneServer;

RuneClient* rune_client_create(const char* url);
char* rune_client_call_tool(RuneClient* client, const char* tool, const char* params);
void rune_client_destroy(RuneClient* client);

RuneServer* rune_server_create(void);
int rune_server_register_tool(RuneServer* server, const char* name, ToolCallback callback);
int rune_server_run(RuneServer* server);
void rune_server_destroy(RuneServer* server);
```

## Data Flow

### MCP Server Operation

```
1. Client connects via stdio
2. Client sends "initialize" request
3. Server responds with capabilities
4. Client sends "tools/list" request
5. Server responds with available tools
6. Client sends "tools/call" request
7. Server executes tool and returns result
8. Optional: Server sends progress notifications
```

### Provider Integration

```
1. Application creates provider instance
2. Provider authenticates with AI service
3. Application sends completion request
4. Provider translates to service-specific format
5. Provider makes HTTP request to AI service
6. Provider streams response chunks back
7. Application processes streaming response
```

## Performance Characteristics

### Memory Usage
- **Zero-copy JSON**: Parser reuses input buffer where possible
- **Arena allocation**: Temporary allocations use arena for bulk cleanup
- **Pool allocation**: Connection pools reuse HTTP clients
- **Stack allocation**: Small objects prefer stack over heap

### Latency Targets
- **File operations**: <100μs for small files (<1MB)
- **Text selection**: <1ms for documents up to 10MB
- **MCP requests**: <10ms end-to-end (excluding AI provider)
- **Provider calls**: <100ms first token (network dependent)

### Throughput Goals
- **File I/O**: >3× pure Rust baseline
- **Text processing**: SIMD acceleration for search/replace
- **JSON parsing**: Near C-speed with simdjson techniques
- **HTTP requests**: Connection pooling and keep-alive

## Integration Patterns

### 1. Zig Package Integration

```zig
// build.zig.zon
.dependencies = .{
    .rune = .{
        .url = "https://github.com/ghostkellz/rune/archive/main.tar.gz",
        .hash = "...",
    },
}

// usage
const rune = @import("rune");
var server = try rune.mcp.Server.init(allocator, stdin, stdout);
```

### 2. MCP Client Integration

```bash
# Gemini CLI
gemini mcp add rune stdio "zig-out/bin/rune mcp-server"

# Claude Code
echo '{"mcpServers": {"rune": {"command": "zig-out/bin/rune", "args": ["mcp-server"]}}}' > .claude_config
```

### 3. Rust FFI Integration

```rust
// Cargo.toml
[dependencies]
rune-sys = { path = "../rune/bindings/rust" }

// build.rs
fn main() {
    println!("cargo:rustc-link-search=native=../rune/zig-out/lib");
    println!("cargo:rustc-link-lib=static=rune");
}

// usage
use rune_sys::*;
let client = unsafe { rune_client_create(c"ws://localhost:8080") };
```

## Security Model

### MCP Security
- **Tool validation**: Schema validation for all tool inputs
- **Sandboxing**: File operations restricted to allowed paths
- **Consent hooks**: Optional user confirmation for sensitive operations
- **Audit logging**: All tool invocations logged with timestamps

### Provider Security
- **API key management**: Keys stored in environment variables only
- **Rate limiting**: Built-in retry and backoff for API calls
- **Request validation**: Schema validation before sending to providers
- **Response sanitization**: Strip potentially harmful content

## Future Architecture

### Alpha Phase Additions

```
┌─────────────────────────────────────────────────────────────────┐
│                      Alpha Architecture                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                  SIMD Acceleration                          │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐     │ │
│  │  │Text Search  │  │ UTF-8 Ops   │  │  Hash Compute   │     │ │
│  │  │(AVX2/NEON)  │  │ Validation  │  │   (CRC/Blake3)  │     │ │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘     │ │
│  └─────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │               Parallel Processing                           │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐     │ │
│  │  │Work Stealing│  │ Lock-free   │  │   Workspace     │     │ │
│  │  │Thread Pool  │  │   Queues    │  │    Scanner      │     │ │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘     │ │
│  └─────────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │                 Caching & Storage                           │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐     │ │
│  │  │ LRU Cache   │  │Disk Backing │  │   Compression   │     │ │
│  │  │ (SIMD hash) │  │ w/Eviction  │  │   (LZ4/Zstd)    │     │ │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘     │ │
│  └─────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

This architecture balances performance, maintainability, and ecosystem integration while providing a clear path for future enhancements.