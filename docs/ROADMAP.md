# Rune MCP Implementation Roadmap

## Current Status (October 1, 2025)

### ✅ Phase 1: Core Foundation - **COMPLETE**
- [x] **Async Runtime Integration** - zsync fully integrated
  - Server has configurable execution models (auto, blocking, thread_pool, green_threads)
  - Client has async-ready request/response handling
  - Runtime properly initialized and cleaned up
  
- [x] **JSON Serialization** - Complete implementation
  - Comprehensive `json_serialization.zig` module
  - Supports all Zig types: structs, arrays, primitives, enums, optionals, unions
  - All placeholder methods replaced with proper serialization
  
- [x] **MCP Protocol Implementation** - Core features working
  - Initialize/Initialized handshake
  - Tools registration and listing
  - Tool invocation with proper error handling
  - Request/Response message handling

### 🚀 Phase 2: Performance & Reliability - **NEXT UP**

#### 2.1 Transport Layer Optimization
**Goal**: Make transport async-aware for true non-blocking I/O

**Tasks**:
1. Update `src/transport.zig`:
   ```zig
   pub const Transport = struct {
       io: zsync.Io,  // Add async I/O
       
       // Make send/receive async
       pub fn send(self: *Self, message: protocol.Message) !void {
           var future = try self.io.write(serialized_data);
           try future.await();
       }
       
       pub fn receive(self: *Self) !?protocol.Message {
           var future = try self.io.read(buffer);
           const data = try future.await();
           return parseMessage(data);
       }
   }
   ```

2. Implement buffered I/O for better performance
3. Add timeout support using `zsync.timer`

**Impact**: Reduces latency, enables concurrent request handling

#### 2.2 Connection Pooling & Rate Limiting
**Goal**: Support multiple concurrent clients efficiently

**Components**:
```zig
// src/connection_pool.zig
pub const ConnectionPool = struct {
    max_connections: u32 = 100,
    active: std.ArrayList(*Client),
    idle: std.ArrayList(*Client),
    
    pub fn acquire(self: *Self) !*Client;
    pub fn release(self: *Self, client: *Client) void;
};

// src/rate_limiter.zig
pub const RateLimiter = struct {
    requests_per_second: u32 = 100,
    burst_size: u32 = 10,
    
    pub fn allowRequest(self: *Self) !bool;
    pub fn waitForSlot(self: *Self) !void;
};
```

**Impact**: Prevents resource exhaustion, improves stability

#### 2.3 Streaming Responses
**Goal**: Support large data transfers efficiently

**Implementation**:
```zig
pub fn streamToolResult(
    ctx: *ToolCtx,
    data_stream: zsync.Channel([]const u8),
) !void {
    while (try data_stream.receive()) |chunk| {
        // Send chunk to client
        try ctx.sendChunk(chunk);
    }
}
```

**Use Cases**:
- Large file operations
- AI model streaming responses
- Real-time log tailing

### 🤖 Phase 3: AI Provider Integration - **EXCITING PART!**

#### 3.1 Core AI Abstraction (`src/ai/provider.zig`)
**Status**: Designed, ready to implement

**Key Features**:
- Unified interface for all AI providers
- Streaming support via zsync channels
- Model listing and selection
- Token usage tracking

#### 3.2 Ollama Provider - **START HERE** (Simplest)
**Why First**: No authentication, local, easy to test

**Implementation Steps**:
1. Create `src/ai/providers/ollama.zig`
2. Implement HTTP client with `std.http.Client`
3. Add endpoints:
   - `/api/generate` - Text generation
   - `/api/chat` - Chat completion
   - `/api/tags` - List models
   - `/api/embeddings` - Generate embeddings

4. Register MCP tools:
   ```zig
   // tools/ai_ollama_generate
   {
     "name": "ai_ollama_generate",
     "description": "Generate text using local Ollama models",
     "inputSchema": {
       "type": "object",
       "properties": {
         "model": { "type": "string", "default": "llama3.1:8b" },
         "prompt": { "type": "string" },
         "system": { "type": "string" },
         "stream": { "type": "boolean", "default": false }
       }
     }
   }
   ```

**Testing**:
```bash
# Start Ollama
ollama serve

# Test from Rune
rune-cli tool call ai_ollama_generate '{
  "model": "llama3.1:8b",
  "prompt": "Explain async programming in Zig"
}'
```

**Timeline**: 2-3 days

#### 3.3 OAuth2 Authentication (`src/ai/oauth2.zig`)
**For**: Claude (Anthropic), ChatGPT (OpenAI), Copilot (GitHub)

**Flow**:
1. User runs: `rune auth google --provider=claude`
2. Rune starts local server on `localhost:8080`
3. Opens browser to Google OAuth consent screen
4. User authorizes
5. Google redirects to `http://localhost:8080/callback?code=...`
6. Rune exchanges code for tokens (PKCE)
7. Stores in `~/.config/rune/tokens.json` (encrypted)

**Security**:
- PKCE (Proof Key for Code Exchange) prevents interception
- Tokens encrypted at rest using OS keyring
- Short-lived access tokens, long-lived refresh tokens

**Timeline**: 3-4 days

#### 3.4 Claude Provider (`src/ai/providers/claude.zig`)
**API**: https://docs.anthropic.com/claude/reference

**Key Features**:
- Supports Claude 3.5 Sonnet (best model)
- Streaming responses via SSE
- Vision support (image analysis)
- Large context window (200K tokens)

**MCP Tool**:
```zig
// tools/ai_claude_chat
{
  "name": "ai_claude_chat",
  "description": "Chat with Claude AI (requires Google Sign-In)",
  "inputSchema": {
    "type": "object",
    "properties": {
      "messages": {
        "type": "array",
        "items": {
          "type": "object",
          "properties": {
            "role": { "enum": ["user", "assistant"] },
            "content": { "type": "string" }
          }
        }
      },
      "model": { "type": "string", "default": "claude-3-5-sonnet-20241022" },
      "temperature": { "type": "number", "default": 0.7 },
      "max_tokens": { "type": "integer", "default": 4096 },
      "stream": { "type": "boolean", "default": false }
    }
  }
}
```

**Timeline**: 2-3 days

#### 3.5 ChatGPT Provider (`src/ai/providers/chatgpt.zig`)
**API**: https://platform.openai.com/docs/api-reference

**Dual Auth Support**:
- Option 1: Direct OpenAI API key
- Option 2: Google Sign-In (via OpenAI partnership)

**Models**:
- GPT-4 Turbo
- GPT-4
- GPT-3.5 Turbo
- O1 (reasoning model)

**Timeline**: 2-3 days

#### 3.6 GitHub Copilot Provider (`src/ai/providers/copilot.zig`)
**API**: GitHub Copilot API (requires GitHub token)

**Features**:
- Code completions
- Code explanations
- Code review
- Test generation

**MCP Tool**:
```zig
// tools/ai_copilot_complete
{
  "name": "ai_copilot_complete",
  "description": "Get code completions from GitHub Copilot",
  "inputSchema": {
    "type": "object",
    "properties": {
      "prompt": { "type": "string" },
      "language": { "type": "string" },
      "context": { "type": "string" }
    }
  }
}
```

**Timeline**: 2-3 days

### 🔒 Phase 4: Security & Sandboxing

#### 4.1 Sandboxing (`src/sandbox.zig`)
**Goal**: Isolate tool execution for security

**Linux Implementation**:
```zig
pub const Sandbox = struct {
    pub fn enter(self: *Self) !void {
        // Drop capabilities
        try self.dropCapabilities();
        
        // Apply seccomp filter
        try self.applySeccomp();
        
        // Set resource limits
        try self.setResourceLimits();
    }
    
    fn applySeccomp(self: *Self) !void {
        // Allow only safe syscalls
        const allowed = [_]u32{
            SYS_read, SYS_write, SYS_close,
            SYS_mmap, SYS_munmap,
            SYS_exit_group,
        };
        // Block dangerous ones: execve, fork, socket, etc.
    }
};
```

**macOS/Windows**: Use OS-specific sandboxing APIs

**Timeline**: 3-4 days

### 📊 Phase 5: Testing & Optimization

#### 5.1 Test Suite
**Coverage Goals**: >80%

**Test Categories**:
1. **Unit Tests** - Each module
2. **Integration Tests** - Full MCP flows
3. **Performance Tests** - Benchmarks
4. **AI Provider Tests** - Mock responses

**Timeline**: 4-5 days

#### 5.2 Performance Optimization
**Targets**:
- JSON serialization: Use arena allocators
- Message parsing: Zero-copy when possible
- Memory pooling: Reuse allocations
- Connection caching: HTTP keep-alive

**Profiling**:
```bash
# Profile hot paths
zig build -Doptimize=ReleaseFast
perf record -g ./zig-out/bin/rune
perf report
```

**Timeline**: 3-4 days

### 📖 Phase 6: Documentation & Examples

#### 6.1 Getting Started Guide
- Installation
- Configuration
- First MCP server
- First AI integration

#### 6.2 API Reference
- All public APIs documented
- Code examples for each function
- Common patterns

#### 6.3 Zeke Integration Guide
- Setting up Rune with zeke.nvim
- Using AI providers in Neovim
- Custom tool creation

**Timeline**: 3-4 days

## Implementation Priority

### 🔥 **Immediate Next Steps** (This Week)
1. ✅ Client async integration (DONE)
2. → Transport layer async (1-2 days)
3. → Ollama provider (2-3 days)

### 🎯 **Week 2-3**: AI Foundation
1. OAuth2 authentication module
2. AI provider abstraction layer
3. Claude provider
4. ChatGPT provider

### 🚀 **Week 4**: Polish & Testing
1. GitHub Copilot provider
2. Sandboxing
3. Test suite
4. Performance optimization

### 📚 **Week 5**: Documentation & Launch
1. Documentation
2. Examples
3. Zeke integration guide
4. **Rune v1.0 Release!**

## Success Metrics

### Performance
- [ ] <10ms latency for local Ollama calls
- [ ] <100ms latency for remote AI API calls
- [ ] Handle 100+ concurrent clients
- [ ] <1MB memory overhead per client

### Reliability
- [ ] 99.9% uptime
- [ ] Graceful error handling
- [ ] Automatic token refresh
- [ ] Connection retry logic

### Developer Experience
- [ ] 5-minute quick start
- [ ] Clear error messages
- [ ] Comprehensive examples
- [ ] Active community

## Long-Term Vision

### Q1 2025
- **Rune v1.0**: Core MCP + AI providers
- **Zeke Alpha**: Neovim integration

### Q2 2025
- Rune v1.1: More AI providers (Gemini, Mistral)
- Plugin ecosystem
- Web dashboard

### Q3 2025
- Rune v2.0: Distributed MCP
- Multi-node coordination
- Cloud deployment

### Q4 2025
- Enterprise features
- Advanced analytics
- SaaS offering

## Questions & Decisions

### Architecture Decisions
- ✅ **Async Runtime**: zsync (chosen for colorblind async)
- ✅ **JSON Serialization**: Custom implementation (complete)
- ⏳ **HTTP Client**: std.http.Client vs custom
- ⏳ **Token Storage**: OS keyring vs encrypted file

### Open Questions
1. Should Rune support multiple AI providers simultaneously?
   - **Answer**: YES - that's the whole point!

2. How to handle API rate limits?
   - **Proposal**: Per-provider rate limiter with exponential backoff

3. Should we cache AI responses?
   - **Proposal**: Optional LRU cache with configurable TTL

4. How to monetize Rune?
   - **Proposal**: Open-source core, paid cloud hosting

## Getting Involved

### For Contributors
1. Check the todo list above
2. Pick a task
3. Open a PR
4. Join our Discord

### For Users
1. Star the repo
2. Try the examples
3. Report bugs
4. Share feedback

---

**Next Update**: When Ollama provider is complete
**Last Updated**: October 1, 2025
