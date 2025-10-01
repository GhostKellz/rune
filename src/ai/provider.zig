//! AI Provider Abstraction Layer
//! Unified interface for Claude, ChatGPT, Copilot, and Ollama

const std = @import("std");

/// Role in a conversation
pub const Role = enum {
    system,
    user,
    assistant,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
        };
    }
};

/// Message in a conversation
pub const Message = struct {
    role: Role,
    content: []const u8,
    name: ?[]const u8 = null,
};

/// Model configuration
pub const ModelConfig = struct {
    model: []const u8,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    stream: bool = false,
    stop: ?[]const []const u8 = null,
};

/// Token usage information
pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// AI response
pub const Response = struct {
    content: []const u8,
    model: []const u8,
    finish_reason: ?[]const u8 = null,
    usage: ?Usage = null,
};

/// Streaming chunk
pub const StreamChunk = struct {
    delta: []const u8,
    finish_reason: ?[]const u8 = null,
};

/// Model information
pub const ModelInfo = struct {
    name: []const u8,
    size: u64,
    parameter_size: []const u8,
    quantization: ?[]const u8 = null,
    family: ?[]const u8 = null,
    modified_at: ?[]const u8 = null,
};

/// Provider capabilities
pub const Capabilities = struct {
    supports_streaming: bool = false,
    supports_vision: bool = false,
    supports_function_calling: bool = false,
    supports_embeddings: bool = false,
    max_context_length: u32 = 4096,
};

/// AI Provider interface (vtable pattern)
pub const AIProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Generate text from a prompt
        generate: *const fn (ctx: *anyopaque, prompt: []const u8, config: ModelConfig) anyerror!Response,

        /// Chat with conversation history
        chat: *const fn (ctx: *anyopaque, messages: []const Message, config: ModelConfig) anyerror!Response,

        /// Stream chat responses
        streamChat: ?*const fn (
            ctx: *anyopaque,
            messages: []const Message,
            config: ModelConfig,
            callback: *const fn (StreamChunk) void,
        ) anyerror!void = null,

        /// List available models
        listModels: *const fn (ctx: *anyopaque) anyerror![]const ModelInfo,

        /// Get embeddings for text
        embeddings: ?*const fn (ctx: *anyopaque, text: []const u8, model: []const u8) anyerror![]const f32 = null,

        /// Get provider capabilities
        capabilities: *const fn (ctx: *anyopaque) Capabilities,

        /// Clean up resources
        deinit: *const fn (ctx: *anyopaque) void,
    };

    /// Generate text from a prompt
    pub fn generate(self: AIProvider, prompt: []const u8, config: ModelConfig) !Response {
        return self.vtable.generate(self.ptr, prompt, config);
    }

    /// Chat with conversation history
    pub fn chat(self: AIProvider, messages: []const Message, config: ModelConfig) !Response {
        return self.vtable.chat(self.ptr, messages, config);
    }

    /// Stream chat responses (if supported)
    pub fn streamChat(
        self: AIProvider,
        messages: []const Message,
        config: ModelConfig,
        callback: *const fn (StreamChunk) void,
    ) !void {
        if (self.vtable.streamChat) |stream_fn| {
            return stream_fn(self.ptr, messages, config, callback);
        }
        return error.StreamingNotSupported;
    }

    /// List available models
    pub fn listModels(self: AIProvider) ![]const ModelInfo {
        return self.vtable.listModels(self.ptr);
    }

    /// Get embeddings (if supported)
    pub fn embeddings(self: AIProvider, text: []const u8, model: []const u8) ![]const f32 {
        if (self.vtable.embeddings) |embed_fn| {
            return embed_fn(self.ptr, text, model);
        }
        return error.EmbeddingsNotSupported;
    }

    /// Get provider capabilities
    pub fn capabilities(self: AIProvider) Capabilities {
        return self.vtable.capabilities(self.ptr);
    }

    /// Clean up resources
    pub fn deinit(self: AIProvider) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Provider type enum
pub const ProviderType = enum {
    ollama,
    claude,
    chatgpt,
    copilot,

    pub fn toString(self: ProviderType) []const u8 {
        return switch (self) {
            .ollama => "ollama",
            .claude => "claude",
            .chatgpt => "chatgpt",
            .copilot => "copilot",
        };
    }
};
