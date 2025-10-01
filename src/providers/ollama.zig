const std = @import("std");
const base = @import("base.zig");
const http = std.http;
const json = std.json;

pub const OllamaProvider = struct {
    allocator: std.mem.Allocator,
    base_url: []const u8,
    client: http.Client,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !Self {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .client = http.Client{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
    }

    pub fn provider(self: *Self) base.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .name = name,
                .listModels = listModels,
                .complete = complete,
                .streamComplete = streamComplete,
                .healthCheck = healthCheck,
                .deinit = deinitProvider,
            },
        };
    }

    fn name(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "ollama";
    }

    fn listModels(ptr: *anyopaque, allocator: std.mem.Allocator) base.ProviderError![]base.Model {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        _ = allocator;

        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/tags", .{self.base_url});
        defer self.allocator.free(url);

        const uri = std.Uri.parse(url) catch return base.ProviderError.InvalidRequest;

        var headers = http.Headers{ .allocator = self.allocator };
        defer headers.deinit();

        var req = self.client.request(.GET, uri, headers, .{}) catch return base.ProviderError.NetworkError;
        defer req.deinit();

        req.start() catch return base.ProviderError.NetworkError;
        req.wait() catch return base.ProviderError.NetworkError;

        if (req.response.status != .ok) {
            return base.ProviderError.ServerError;
        }

        const body = req.reader().readAllAlloc(self.allocator, 1024 * 1024) catch return base.ProviderError.InvalidResponse;
        defer self.allocator.free(body);

        var models = std.ArrayList(base.Model).init(self.allocator);

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();

        const parsed = parser.parse(body) catch return base.ProviderError.InvalidResponse;
        const models_array = parsed.object.get("models").?.array;

        for (models_array.items) |model| {
            const model_obj = model.object;
            const model_name = model_obj.get("name").?.string;

            try models.append(.{
                .id = model_name,
                .name = model_name,
                .provider = "ollama",
                .context_window = 8192, // Default for most Ollama models
                .max_output_tokens = null,
                .supports_tools = false,
                .supports_vision = std.mem.indexOf(u8, model_name, "vision") != null or
                    std.mem.indexOf(u8, model_name, "llava") != null,
            });
        }

        return models.toOwnedSlice();
    }

    fn complete(ptr: *anyopaque, allocator: std.mem.Allocator, request: base.CompletionRequest) base.ProviderError!base.CompletionResponse {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));

        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/chat", .{self.base_url});
        defer self.allocator.free(url);

        const uri = std.Uri.parse(url) catch return base.ProviderError.InvalidRequest;

        var headers = http.Headers{ .allocator = self.allocator };
        defer headers.deinit();
        try headers.append("Content-Type", "application/json");

        const ollama_request = OllamaRequest{
            .model = request.model,
            .messages = try convertMessages(allocator, request.messages),
            .stream = false,
            .options = .{
                .temperature = request.temperature,
                .top_p = request.top_p,
                .num_predict = request.max_tokens,
            },
        };

        var body_buf = std.ArrayList(u8).init(self.allocator);
        defer body_buf.deinit();
        try json.stringify(ollama_request, .{}, body_buf.writer());

        var req = self.client.request(.POST, uri, headers, .{}) catch return base.ProviderError.NetworkError;
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body_buf.items.len };
        req.start() catch return base.ProviderError.NetworkError;
        req.writer().writeAll(body_buf.items) catch return base.ProviderError.NetworkError;
        req.finish() catch return base.ProviderError.NetworkError;
        req.wait() catch return base.ProviderError.NetworkError;

        if (req.response.status != .ok) {
            return base.ProviderError.ServerError;
        }

        const response_body = req.reader().readAllAlloc(self.allocator, 10 * 1024 * 1024) catch return base.ProviderError.InvalidResponse;
        defer self.allocator.free(response_body);

        var parser = json.Parser.init(self.allocator, .alloc_always);
        defer parser.deinit();

        const parsed = parser.parse(response_body) catch return base.ProviderError.InvalidResponse;
        const resp_obj = parsed.object;

        const message_obj = resp_obj.get("message").?.object;
        const content = message_obj.get("content").?.string;

        return .{
            .id = "ollama-response",
            .model = request.model,
            .choices = &[_]base.Choice{.{
                .index = 0,
                .message = .{
                    .role = .assistant,
                    .content = content,
                },
                .finish_reason = "stop",
            }},
            .created = std.time.timestamp(),
        };
    }

    fn streamComplete(ptr: *anyopaque, allocator: std.mem.Allocator, request: base.CompletionRequest) base.ProviderError!base.StreamIterator {
        _ = ptr;
        _ = allocator;
        _ = request;
        return base.ProviderError.InvalidRequest; // Not implemented yet
    }

    fn healthCheck(ptr: *anyopaque) base.ProviderError!void {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));

        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/version", .{self.base_url});
        defer self.allocator.free(url);

        const uri = std.Uri.parse(url) catch return base.ProviderError.InvalidRequest;

        var headers = http.Headers{ .allocator = self.allocator };
        defer headers.deinit();

        var req = self.client.request(.GET, uri, headers, .{}) catch return base.ProviderError.NetworkError;
        defer req.deinit();

        req.start() catch return base.ProviderError.NetworkError;
        req.wait() catch return base.ProviderError.NetworkError;

        if (req.response.status != .ok) {
            return base.ProviderError.ServerError;
        }
    }

    fn deinitProvider(ptr: *anyopaque) void {
        const self = @as(*Self, @ptrCast(@alignCast(ptr)));
        self.deinit();
    }

    const OllamaRequest = struct {
        model: []const u8,
        messages: []OllamaMessage,
        stream: bool,
        options: struct {
            temperature: ?f32 = null,
            top_p: ?f32 = null,
            num_predict: ?u32 = null,
        },
    };

    const OllamaMessage = struct {
        role: []const u8,
        content: []const u8,
    };

    fn convertMessages(allocator: std.mem.Allocator, messages: []base.Message) ![]OllamaMessage {
        var ollama_messages = std.ArrayList(OllamaMessage).init(allocator);

        for (messages) |msg| {
            const role_str = switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
            };

            try ollama_messages.append(.{
                .role = role_str,
                .content = msg.content,
            });
        }

        return ollama_messages.toOwnedSlice();
    }
};
