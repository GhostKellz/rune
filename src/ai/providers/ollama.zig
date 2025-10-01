//! Ollama Provider Implementation
//! Interfaces with local Ollama API for text generation, chat, and embeddings

const std = @import("std");
const ai_provider = @import("../provider.zig");
const zsync = @import("zsync");

pub const OllamaProvider = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    io: zsync.Io,
    http_client: std.http.Client,

    const Self = @This();

    pub const Config = struct {
        base_url: []const u8 = "http://localhost:11434",
    };

    /// Initialize Ollama provider
    pub fn init(allocator: std.mem.Allocator, config: Config, io: zsync.Io) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .base_url = try allocator.dupe(u8, config.base_url),
            .io = io,
            .http_client = std.http.Client{ .allocator = allocator },
        };
        return self;
    }

    /// Clean up resources
    pub fn deinit(self: *Self) void {
        self.http_client.deinit();
        self.allocator.free(self.base_url);
        self.allocator.destroy(self);
    }

    /// Convert to AIProvider interface
    pub fn provider(self: *Self) ai_provider.AIProvider {
        return .{
            .ptr = self,
            .vtable = &.{
                .generate = generate,
                .chat = chat,
                .streamChat = streamChat,
                .listModels = listModels,
                .embeddings = embeddings,
                .capabilities = capabilities,
                .deinit = deinitProvider,
            },
        };
    }

    // VTable implementations

    fn generate(ctx: *anyopaque, prompt: []const u8, config: ai_provider.ModelConfig) anyerror!ai_provider.Response {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Build request body
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit();

        var json_writer = std.json.writeStream(request_body.writer(), .{});
        try json_writer.beginObject();
        try json_writer.objectField("model");
        try json_writer.write(config.model);
        try json_writer.objectField("prompt");
        try json_writer.write(prompt);
        try json_writer.objectField("stream");
        try json_writer.write(false);

        if (config.temperature) |temp| {
            try json_writer.objectField("options");
            try json_writer.beginObject();
            try json_writer.objectField("temperature");
            try json_writer.write(temp);
            try json_writer.endObject();
        }

        try json_writer.endObject();

        // Make HTTP request
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/generate", .{self.base_url});
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Client.Request.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        try headers.append("content-type", "application/json");

        var req = try self.http_client.open(.POST, uri, headers, .{});
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request_body.items.len };
        try req.send(.{});
        try req.writeAll(request_body.items);
        try req.finish();
        try req.wait();

        // Read response
        var response_body = std.ArrayList(u8){};
        defer response_body.deinit();
        
        const max_size = 10 * 1024 * 1024; // 10MB max
        try req.reader().readAllArrayList(&response_body, max_size);

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            struct {
                model: []const u8,
                response: []const u8,
                done: bool,
                done_reason: ?[]const u8 = null,
                context: ?[]const i32 = null,
            },
            self.allocator,
            response_body.items,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        return ai_provider.Response{
            .content = try self.allocator.dupe(u8, parsed.value.response),
            .model = try self.allocator.dupe(u8, parsed.value.model),
            .finish_reason = if (parsed.value.done_reason) |reason| 
                try self.allocator.dupe(u8, reason) 
            else 
                null,
            .usage = null, // Ollama doesn't provide token counts in generate
        };
    }

    fn chat(ctx: *anyopaque, messages: []const ai_provider.Message, config: ai_provider.ModelConfig) anyerror!ai_provider.Response {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Build request body
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit();

        var json_writer = std.json.writeStream(request_body.writer(), .{});
        try json_writer.beginObject();
        
        try json_writer.objectField("model");
        try json_writer.write(config.model);
        
        try json_writer.objectField("messages");
        try json_writer.beginArray();
        for (messages) |msg| {
            try json_writer.beginObject();
            try json_writer.objectField("role");
            try json_writer.write(msg.role.toString());
            try json_writer.objectField("content");
            try json_writer.write(msg.content);
            try json_writer.endObject();
        }
        try json_writer.endArray();
        
        try json_writer.objectField("stream");
        try json_writer.write(false);

        if (config.temperature) |temp| {
            try json_writer.objectField("options");
            try json_writer.beginObject();
            try json_writer.objectField("temperature");
            try json_writer.write(temp);
            if (config.max_tokens) |max_tok| {
                try json_writer.objectField("num_predict");
                try json_writer.write(max_tok);
            }
            try json_writer.endObject();
        }

        try json_writer.endObject();

        // Make HTTP request
        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/chat", .{self.base_url});
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Client.Request.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        try headers.append("content-type", "application/json");

        var req = try self.http_client.open(.POST, uri, headers, .{});
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request_body.items.len };
        try req.send(.{});
        try req.writeAll(request_body.items);
        try req.finish();
        try req.wait();

        // Read response
        var response_body = std.ArrayList(u8){};
        defer response_body.deinit();
        
        const max_size = 10 * 1024 * 1024; // 10MB max
        try req.reader().readAllArrayList(&response_body, max_size);

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            struct {
                model: []const u8,
                message: struct {
                    role: []const u8,
                    content: []const u8,
                },
                done: bool,
                done_reason: ?[]const u8 = null,
                prompt_eval_count: ?u32 = null,
                eval_count: ?u32 = null,
            },
            self.allocator,
            response_body.items,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        return ai_provider.Response{
            .content = try self.allocator.dupe(u8, parsed.value.message.content),
            .model = try self.allocator.dupe(u8, parsed.value.model),
            .finish_reason = if (parsed.value.done_reason) |reason|
                try self.allocator.dupe(u8, reason)
            else
                null,
            .usage = if (parsed.value.prompt_eval_count != null and parsed.value.eval_count != null)
                ai_provider.Usage{
                    .prompt_tokens = parsed.value.prompt_eval_count.?,
                    .completion_tokens = parsed.value.eval_count.?,
                    .total_tokens = parsed.value.prompt_eval_count.? + parsed.value.eval_count.?,
                }
            else
                null,
        };
    }

    fn streamChat(
        ctx: *anyopaque,
        messages: []const ai_provider.Message,
        config: ai_provider.ModelConfig,
        callback: *const fn (ai_provider.StreamChunk) void,
    ) anyerror!void {
        _ = ctx;
        _ = messages;
        _ = config;
        _ = callback;
        // TODO: Implement streaming
        return error.NotImplementedYet;
    }

    fn listModels(ctx: *anyopaque) anyerror![]const ai_provider.ModelInfo {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/tags", .{self.base_url});
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Client.Request.Headers{ .allocator = self.allocator };
        defer headers.deinit();

        var req = try self.http_client.open(.GET, uri, headers, .{});
        defer req.deinit();

        try req.send(.{});
        try req.finish();
        try req.wait();

        // Read response
        var response_body = std.ArrayList(u8){};
        defer response_body.deinit();
        
        const max_size = 1 * 1024 * 1024; // 1MB max
        try req.reader().readAllArrayList(&response_body, max_size);

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            struct {
                models: []struct {
                    name: []const u8,
                    model: []const u8,
                    size: u64,
                    modified_at: []const u8,
                    details: struct {
                        parameter_size: []const u8,
                        quantization_level: ?[]const u8 = null,
                        family: ?[]const u8 = null,
                    },
                },
            },
            self.allocator,
            response_body.items,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        // Convert to ModelInfo array
        var models = try self.allocator.alloc(ai_provider.ModelInfo, parsed.value.models.len);
        for (parsed.value.models, 0..) |model, i| {
            models[i] = ai_provider.ModelInfo{
                .name = try self.allocator.dupe(u8, model.name),
                .size = model.size,
                .parameter_size = try self.allocator.dupe(u8, model.details.parameter_size),
                .quantization = if (model.details.quantization_level) |q|
                    try self.allocator.dupe(u8, q)
                else
                    null,
                .family = if (model.details.family) |f|
                    try self.allocator.dupe(u8, f)
                else
                    null,
                .modified_at = try self.allocator.dupe(u8, model.modified_at),
            };
        }

        return models;
    }

    fn embeddings(ctx: *anyopaque, text: []const u8, model: []const u8) anyerror![]const f32 {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Build request body
        var request_body = std.ArrayList(u8){};
        defer request_body.deinit();

        var json_writer = std.json.writeStream(request_body.writer(), .{});
        try json_writer.beginObject();
        try json_writer.objectField("model");
        try json_writer.write(model);
        try json_writer.objectField("input");
        try json_writer.write(text);
        try json_writer.endObject();

        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/embed", .{self.base_url});
        defer self.allocator.free(url);

        const uri = try std.Uri.parse(url);
        
        var headers = std.http.Client.Request.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        try headers.append("content-type", "application/json");

        var req = try self.http_client.open(.POST, uri, headers, .{});
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = request_body.items.len };
        try req.send(.{});
        try req.writeAll(request_body.items);
        try req.finish();
        try req.wait();

        // Read response
        var response_body = std.ArrayList(u8){};
        defer response_body.deinit();
        
        const max_size = 10 * 1024 * 1024; // 10MB max
        try req.reader().readAllArrayList(&response_body, max_size);

        // Parse JSON response
        const parsed = try std.json.parseFromSlice(
            struct {
                embeddings: [][]const f64,
            },
            self.allocator,
            response_body.items,
            .{ .allocate = .alloc_always },
        );
        defer parsed.deinit();

        // Convert f64 to f32
        if (parsed.value.embeddings.len > 0) {
            const embedding = parsed.value.embeddings[0];
            var result = try self.allocator.alloc(f32, embedding.len);
            for (embedding, 0..) |val, i| {
                result[i] = @floatCast(val);
            }
            return result;
        }

        return &[_]f32{};
    }

    fn capabilities(ctx: *anyopaque) ai_provider.Capabilities {
        _ = ctx;
        return ai_provider.Capabilities{
            .supports_streaming = true,
            .supports_vision = false, // Some models support it, but not all
            .supports_function_calling = false,
            .supports_embeddings = true,
            .max_context_length = 128000, // Depends on model
        };
    }

    fn deinitProvider(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }
};
