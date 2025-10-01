# AI Provider Architecture for Rune

## Vision
Make Rune a universal AI gateway that exposes multiple AI providers (Claude, ChatGPT, Copilot, Ollama) as MCP tools, allowing Zeke/zeke.nvim to seamlessly interact with any AI model through a unified interface.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Zeke / zeke.nvim                        │
│                    (MCP Client)                              │
└──────────────────────┬──────────────────────────────────────┘
                       │ MCP Protocol
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    Rune MCP Server                           │
│  ┌───────────────────────────────────────────────────────┐  │
│  │           AI Provider Abstraction Layer               │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐   │  │
│  │  │ Claude  │ │ChatGPT  │ │ Copilot │ │ Ollama  │   │  │
│  │  │Provider │ │Provider │ │Provider │ │Provider │   │  │
│  │  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘   │  │
│  └───────┼──────────┼──────────┼──────────┼────────────┘  │
│          │          │          │          │                │
│  ┌───────▼──────────▼──────────▼──────────▼────────────┐  │
│  │        OAuth2 / API Key Manager                      │  │
│  │  - Token Storage & Refresh                           │  │
│  │  - Google Sign-In (Claude/ChatGPT)                   │  │
│  │  - API Key Validation                                │  │
│  └──────────────────────────────────────────────────────┘  │
└──────────────────────┬──────────────────────────────────────┘
                       │ HTTPS
                       ▼
┌─────────────────────────────────────────────────────────────┐
│     External AI Services                                     │
│  ┌────────────┐ ┌────────────┐ ┌────────────┐ ┌─────────┐ │
│  │ Claude API │ │ChatGPT API │ │Copilot API │ │ Ollama  │ │
│  │  (Anthropic│ │  (OpenAI)  │ │  (GitHub)  │ │ (Local) │ │
│  └────────────┘ └────────────┘ └────────────┘ └─────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Core Components

### 1. AI Provider Interface (`src/ai/provider.zig`)

```zig
pub const AIProvider = struct {
    pub const Message = struct {
        role: Role,
        content: []const u8,
        name: ?[]const u8 = null,
    };

    pub const Role = enum {
        system,
        user,
        assistant,
    };

    pub const ModelConfig = struct {
        model: []const u8,
        temperature: ?f32 = null,
        max_tokens: ?u32 = null,
        stream: bool = false,
    };

    pub const Response = struct {
        content: []const u8,
        model: []const u8,
        usage: ?Usage = null,
    };

    pub const Usage = struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    };

    pub const StreamChunk = struct {
        delta: []const u8,
        finish_reason: ?[]const u8 = null,
    };

    // Provider implementation interface
    pub const VTable = struct {
        chat: *const fn (ctx: *anyopaque, messages: []const Message, config: ModelConfig) anyerror!Response,
        streamChat: *const fn (ctx: *anyopaque, messages: []const Message, config: ModelConfig, callback: *const fn (StreamChunk) void) anyerror!void,
        listModels: *const fn (ctx: *anyopaque) anyerror![]const []const u8,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    vtable: *const VTable,
    ctx: *anyopaque,

    pub fn chat(self: *AIProvider, messages: []const Message, config: ModelConfig) !Response {
        return self.vtable.chat(self.ctx, messages, config);
    }

    pub fn streamChat(self: *AIProvider, messages: []const Message, config: ModelConfig, callback: *const fn (StreamChunk) void) !void {
        return self.vtable.streamChat(self.ctx, messages, config, callback);
    }
};
```

### 2. OAuth2 Manager (`src/ai/oauth2.zig`)

```zig
pub const OAuth2Manager = struct {
    allocator: std.mem.Allocator,
    token_store: TokenStore,
    
    pub const TokenStore = struct {
        access_token: ?[]const u8,
        refresh_token: ?[]const u8,
        expires_at: i64,
    };

    pub const Provider = enum {
        google,
        github,
    };

    /// Initialize OAuth2 flow with PKCE
    pub fn initiateFlow(self: *Self, provider: Provider, scopes: []const []const u8) ![]const u8;

    /// Handle OAuth2 callback
    pub fn handleCallback(self: *Self, code: []const u8, state: []const u8) !TokenStore;

    /// Refresh expired token
    pub fn refreshToken(self: *Self, provider: Provider) !TokenStore;

    /// Get valid access token (auto-refreshes if needed)
    pub fn getAccessToken(self: *Self, provider: Provider) ![]const u8;
};
```

### 3. Claude Provider (`src/ai/providers/claude.zig`)

```zig
pub const ClaudeProvider = struct {
    allocator: std.mem.Allocator,
    oauth2: *OAuth2Manager,
    base_url: []const u8 = "https://api.anthropic.com/v1",
    io: zsync.Io,

    pub fn init(allocator: std.mem.Allocator, oauth2: *OAuth2Manager, io: zsync.Io) !*ClaudeProvider;

    pub fn chat(self: *ClaudeProvider, messages: []const AIProvider.Message, config: AIProvider.ModelConfig) !AIProvider.Response {
        const token = try self.oauth2.getAccessToken(.google);
        
        // Build request
        const request_body = try self.buildRequest(messages, config);
        defer self.allocator.free(request_body);

        // Make async HTTPS request
        var client = try std.http.Client.init(self.allocator);
        defer client.deinit();

        const response = try client.post(
            try std.fmt.allocPrint(self.allocator, "{s}/messages", .{self.base_url}),
            .{
                .headers = &.{
                    .{ .name = "Authorization", .value = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{token}) },
                    .{ .name = "anthropic-version", .value = "2023-06-01" },
                    .{ .name = "content-type", .value = "application/json" },
                },
                .body = request_body,
            },
        );

        return self.parseResponse(response);
    }
};
```

### 4. Ollama Provider (`src/ai/providers/ollama.zig`)

```zig
pub const OllamaProvider = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8 = "http://localhost:11434",
    io: zsync.Io,

    pub fn init(allocator: std.mem.Allocator, base_url: ?[]const u8, io: zsync.Io) !*OllamaProvider;

    pub fn chat(self: *OllamaProvider, messages: []const AIProvider.Message, config: AIProvider.ModelConfig) !AIProvider.Response {
        // No auth needed for Ollama
        const request_body = try self.buildRequest(messages, config);
        defer self.allocator.free(request_body);

        var client = try std.http.Client.init(self.allocator);
        defer client.deinit();

        const response = try client.post(
            try std.fmt.allocPrint(self.allocator, "{s}/api/chat", .{self.base_url}),
            .{
                .headers = &.{
                    .{ .name = "content-type", .value = "application/json" },
                },
                .body = request_body,
            },
        );

        return self.parseResponse(response);
    }

    pub fn listModels(self: *OllamaProvider) ![]const []const u8 {
        var client = try std.http.Client.init(self.allocator);
        defer client.deinit();

        const response = try client.get(
            try std.fmt.allocPrint(self.allocator, "{s}/api/tags", .{self.base_url}),
            .{},
        );

        return self.parseModelList(response);
    }
};
```

### 5. MCP Tool Registration (`src/server.zig`)

```zig
pub fn registerAITools(self: *Server, ai_manager: *AIManager) !void {
    // Claude tool
    try self.registerToolWithDesc(
        "ai_claude_chat",
        "Chat with Claude AI via Google Sign-In",
        struct {
            fn handler(ctx: *ToolCtx, args: std.json.Value) !std.json.Value {
                const messages = try parseMessages(ctx.allocator, args);
                const config = try parseConfig(args);
                
                const response = try ai_manager.claude.chat(messages, config);
                return try json_ser.toJsonValue(ctx.allocator, response);
            }
        }.handler,
    );

    // ChatGPT tool
    try self.registerToolWithDesc(
        "ai_chatgpt_query",
        "Query ChatGPT via OpenAI API or Google Sign-In",
        chatgptHandler,
    );

    // Copilot tool
    try self.registerToolWithDesc(
        "ai_copilot_complete",
        "Get code completions from GitHub Copilot",
        copilotHandler,
    );

    // Ollama tool
    try self.registerToolWithDesc(
        "ai_ollama_generate",
        "Generate text using local Ollama models",
        ollamaHandler,
    );

    // List Ollama models
    try self.registerToolWithDesc(
        "ai_ollama_list_models",
        "List available Ollama models",
        ollamaListModelsHandler,
    );
}
```

## Authentication Flows

### Claude/ChatGPT via Google Sign-In

1. User initiates OAuth2 flow: `rune auth google --provider=claude`
2. Rune opens browser to Google OAuth consent screen
3. User authorizes, Google redirects to `http://localhost:8080/callback?code=...`
4. Rune exchanges code for access/refresh tokens
5. Tokens stored securely in `~/.config/rune/tokens.json`
6. Claude/ChatGPT API calls use Google access token

### GitHub Copilot

1. User provides GitHub token: `rune auth github --token=ghp_...`
2. Token validated against GitHub API
3. Stored in `~/.config/rune/tokens.json`
4. Copilot API calls use GitHub token

### Ollama (Local)

- No authentication needed
- Configurable base URL: `rune config set ollama.url http://localhost:11434`

## Configuration File (`~/.config/rune/config.toml`)

```toml
[ai.claude]
enabled = true
model = "claude-3-5-sonnet-20241022"
temperature = 0.7
max_tokens = 4096

[ai.chatgpt]
enabled = true
model = "gpt-4-turbo-preview"
api_key = "sk-..."  # Optional: use OpenAI API directly
use_google_auth = true  # Or use Google Sign-In

[ai.copilot]
enabled = true
github_token = "ghp_..."

[ai.ollama]
enabled = true
base_url = "http://localhost:11434"
default_model = "llama3.1:8b"
models = ["llama3.1:8b", "codellama:7b", "mistral:latest"]
```

## Usage Example in Zeke

```lua
-- zeke.nvim configuration
require('zeke').setup({
  rune = {
    ai_providers = {
      claude = {
        enabled = true,
        model = "claude-3-5-sonnet-20241022",
      },
      ollama = {
        enabled = true,
        model = "llama3.1:8b",
      },
    },
  },
})

-- Use Claude for code review
:ZekeAI claude "Review this function for potential bugs"

-- Use Ollama for local completions
:ZekeAI ollama "Complete this function"

-- Stream responses
:ZekeAI claude --stream "Explain this code"
```

## Performance Optimizations

### 1. Connection Pooling
- Reuse HTTP connections across requests
- Implement keep-alive for better latency

### 2. Request Batching
- Batch multiple requests to same provider
- Reduce API call overhead

### 3. Caching
- Cache model responses for identical prompts
- Implement LRU cache with configurable size

### 4. Streaming
- Use Server-Sent Events (SSE) for streaming responses
- Implement backpressure with zsync channels

### 5. Rate Limiting
- Respect API rate limits per provider
- Implement token bucket algorithm

## Security Considerations

1. **Token Storage**: Use OS keyring (libsecret on Linux, Keychain on macOS)
2. **PKCE Flow**: Prevent authorization code interception
3. **Sandboxing**: Run AI provider code in restricted sandbox
4. **Input Validation**: Sanitize all user inputs before sending to APIs
5. **TLS Verification**: Verify SSL certificates for all HTTPS requests

## Implementation Priority

### Phase 1: Foundation (This Sprint)
1. ✅ Complete async integration (zsync)
2. → Add connection pooling & rate limiting
3. → Implement streaming responses

### Phase 2: AI Core (Next Sprint)
1. Create AI provider abstraction layer
2. Implement OAuth2 authentication module
3. Build Ollama provider (easiest, no auth)

### Phase 3: Cloud AI (Following Sprint)
1. Implement Claude provider with Google OAuth
2. Implement ChatGPT provider
3. Implement GitHub Copilot provider

### Phase 4: Polish & Optimization
1. Add caching layer
2. Performance profiling and optimization
3. Comprehensive testing
4. Documentation

## Next Immediate Steps

Let me start with the foundation pieces that will unlock AI integration:
