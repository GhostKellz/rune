const std = @import("std");

pub const Message = struct {
    role: Role,
    content: []const u8,
    name: ?[]const u8 = null,
    tool_calls: ?[]ToolCall = null,
    tool_call_id: ?[]const u8 = null,
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const ToolCall = struct {
    id: []const u8,
    type: []const u8,
    function: struct {
        name: []const u8,
        arguments: []const u8,
    },
};

pub const CompletionRequest = struct {
    model: []const u8,
    messages: []Message,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    stream: bool = false,
    tools: ?[]Tool = null,
    tool_choice: ?ToolChoice = null,
};

pub const CompletionResponse = struct {
    id: []const u8,
    model: []const u8,
    choices: []Choice,
    usage: ?Usage = null,
    created: i64,
};

pub const Choice = struct {
    index: u32,
    message: Message,
    finish_reason: ?[]const u8 = null,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

pub const Tool = struct {
    type: []const u8 = "function",
    function: ToolFunction,
};

pub const ToolFunction = struct {
    name: []const u8,
    description: []const u8,
    parameters: std.json.Value,
};

pub const ToolChoice = union(enum) {
    auto: void,
    none: void,
    required: void,
    specific: struct {
        type: []const u8,
        function: struct {
            name: []const u8,
        },
    },
};

pub const StreamChunk = struct {
    id: []const u8,
    model: []const u8,
    choices: []StreamChoice,
    created: i64,
};

pub const StreamChoice = struct {
    index: u32,
    delta: MessageDelta,
    finish_reason: ?[]const u8 = null,
};

pub const MessageDelta = struct {
    role: ?Role = null,
    content: ?[]const u8 = null,
    tool_calls: ?[]ToolCallDelta = null,
};

pub const ToolCallDelta = struct {
    index: u32,
    id: ?[]const u8 = null,
    type: ?[]const u8 = null,
    function: ?struct {
        name: ?[]const u8 = null,
        arguments: ?[]const u8 = null,
    } = null,
};

pub const ProviderError = error{
    AuthenticationFailed,
    RateLimitExceeded,
    InvalidRequest,
    NetworkError,
    ServerError,
    ModelNotFound,
    ContextLengthExceeded,
    InvalidResponse,
};

pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        listModels: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) ProviderError![]Model,
        complete: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: CompletionRequest) ProviderError!CompletionResponse,
        streamComplete: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: CompletionRequest) ProviderError!StreamIterator,
        healthCheck: *const fn (ptr: *anyopaque) ProviderError!void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn name(self: Provider) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn listModels(self: Provider, allocator: std.mem.Allocator) ![]Model {
        return self.vtable.listModels(self.ptr, allocator);
    }

    pub fn complete(self: Provider, allocator: std.mem.Allocator, request: CompletionRequest) !CompletionResponse {
        return self.vtable.complete(self.ptr, allocator, request);
    }

    pub fn streamComplete(self: Provider, allocator: std.mem.Allocator, request: CompletionRequest) !StreamIterator {
        return self.vtable.streamComplete(self.ptr, allocator, request);
    }

    pub fn healthCheck(self: Provider) !void {
        return self.vtable.healthCheck(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const Model = struct {
    id: []const u8,
    name: []const u8,
    provider: []const u8,
    context_window: u32,
    max_output_tokens: ?u32 = null,
    supports_tools: bool = false,
    supports_vision: bool = false,
};

pub const StreamIterator = struct {
    ptr: *anyopaque,
    vtable: *const StreamVTable,

    const StreamVTable = struct {
        next: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) ?StreamChunk,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn next(self: StreamIterator, allocator: std.mem.Allocator) ?StreamChunk {
        return self.vtable.next(self.ptr, allocator);
    }

    pub fn deinit(self: StreamIterator) void {
        self.vtable.deinit(self.ptr);
    }
};
