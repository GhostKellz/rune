//! AI Provider Module
//! Unified interface for multiple AI providers

pub const provider = @import("ai/provider.zig");
pub const ollama = @import("ai/providers/ollama.zig");

// Re-export commonly used types
pub const AIProvider = provider.AIProvider;
pub const Message = provider.Message;
pub const Role = provider.Role;
pub const ModelConfig = provider.ModelConfig;
pub const Response = provider.Response;
pub const ModelInfo = provider.ModelInfo;
pub const Capabilities = provider.Capabilities;

pub const OllamaProvider = ollama.OllamaProvider;
