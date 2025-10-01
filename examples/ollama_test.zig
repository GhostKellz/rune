//! Example: Using Ollama Provider
//! This demonstrates how to use the Ollama provider with Rune

const std = @import("std");
const rune = @import("rune");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize async runtime
    const runtime_config = rune.zsync.Config{
        .execution_model = rune.zsync.ExecutionModel.detect(),
    };
    const runtime = try rune.zsync.Runtime.init(allocator, runtime_config);
    defer runtime.deinit();
    const io = runtime.getIo();

    // Create Ollama provider
    var ollama = try rune.ai.OllamaProvider.init(
        allocator,
        .{ .base_url = "http://localhost:11434" },
        io,
    );
    defer ollama.deinit();

    const provider = ollama.provider();

    std.debug.print("🚀 Rune + Ollama Integration Test\n", .{});
    std.debug.print("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // List available models
    std.debug.print("📋 Available Models:\n", .{});
    const models = try provider.listModels();
    defer {
        for (models) |model| {
            allocator.free(model.name);
            allocator.free(model.parameter_size);
            if (model.quantization) |q| allocator.free(q);
            if (model.family) |f| allocator.free(f);
            if (model.modified_at) |m| allocator.free(m);
        }
        allocator.free(models);
    }

    for (models, 0..) |model, i| {
        std.debug.print("  {d}. {s} ({s} parameters, {d} bytes)\n", .{
            i + 1,
            model.name,
            model.parameter_size,
            model.size,
        });
    }

    std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Test generate API
    std.debug.print("🤖 Testing Generate API with deepseek-coder-v2\n\n", .{});
    const generate_response = try provider.generate(
        "Write a function in Zig that adds two numbers",
        .{
            .model = "deepseek-coder-v2:latest",
            .temperature = 0.7,
        },
    );
    defer {
        allocator.free(generate_response.content);
        allocator.free(generate_response.model);
        if (generate_response.finish_reason) |r| allocator.free(r);
    }

    std.debug.print("Model: {s}\n", .{generate_response.model});
    std.debug.print("Response:\n{s}\n", .{generate_response.content});

    std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Test chat API
    std.debug.print("💬 Testing Chat API with llama3\n\n", .{});
    
    const messages = [_]rune.ai.Message{
        .{ .role = .system, .content = "You are a helpful Zig programming assistant." },
        .{ .role = .user, .content = "What are the key features of Zig?" },
    };

    const chat_response = try provider.chat(&messages, .{
        .model = "llama3:latest",
        .temperature = 0.8,
        .max_tokens = 500,
    });
    defer {
        allocator.free(chat_response.content);
        allocator.free(chat_response.model);
        if (chat_response.finish_reason) |r| allocator.free(r);
    }

    std.debug.print("Model: {s}\n", .{chat_response.model});
    std.debug.print("Response:\n{s}\n", .{chat_response.content});
    
    if (chat_response.usage) |usage| {
        std.debug.print("\n📊 Token Usage:\n", .{});
        std.debug.print("  Prompt: {d} tokens\n", .{usage.prompt_tokens});
        std.debug.print("  Completion: {d} tokens\n", .{usage.completion_tokens});
        std.debug.print("  Total: {d} tokens\n", .{usage.total_tokens});
    }

    std.debug.print("\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n", .{});

    // Show provider capabilities
    const caps = provider.capabilities();
    std.debug.print("✨ Provider Capabilities:\n", .{});
    std.debug.print("  Streaming: {}\n", .{caps.supports_streaming});
    std.debug.print("  Vision: {}\n", .{caps.supports_vision});
    std.debug.print("  Function Calling: {}\n", .{caps.supports_function_calling});
    std.debug.print("  Embeddings: {}\n", .{caps.supports_embeddings});
    std.debug.print("  Max Context: {d} tokens\n", .{caps.max_context_length});

    std.debug.print("\n✅ All tests passed!\n", .{});
}
