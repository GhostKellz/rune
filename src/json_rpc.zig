//! JSON-RPC 2.0 serialization and deserialization for MCP
const std = @import("std");
const protocol = @import("protocol.zig");

pub const JsonRpcError = error{
    ParseError,
    InvalidRequest,
    MethodNotFound,
    InvalidParams,
    InternalError,
    InvalidTool,
    ToolExecutionError,
};

pub fn parseMessage(allocator: std.mem.Allocator, json_text: []const u8) !protocol.JsonRpcMessage {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    if (root.get("method")) |_| {
        if (root.get("id")) |_| {
            return protocol.JsonRpcMessage{ .request = try parseRequest(allocator, root) };
        } else {
            return protocol.JsonRpcMessage{ .notification = try parseNotification(allocator, root) };
        }
    } else if (root.get("result") != null or root.get("error") != null) {
        return protocol.JsonRpcMessage{ .response = try parseResponse(allocator, root) };
    }

    return JsonRpcError.InvalidRequest;
}

fn parseRequest(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !protocol.Request {
    const id = try parseRequestId(obj.get("id") orelse return JsonRpcError.InvalidRequest);
    const method = try allocator.dupe(u8, (obj.get("method") orelse return JsonRpcError.InvalidRequest).string);

    return protocol.Request{
        .id = id,
        .method = method,
        .params = if (obj.get("params")) |p| try cloneJsonValue(allocator, p) else null,
    };
}

fn parseResponse(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !protocol.Response {
    const id = if (obj.get("id")) |id_val| try parseRequestId(id_val) else null;

    var response = protocol.Response{
        .id = id,
        .result = null,
        .@"error" = null,
    };

    if (obj.get("result")) |result| {
        response.result = try cloneJsonValue(allocator, result);
    }

    if (obj.get("error")) |err| {
        response.@"error" = try parseJsonRpcError(allocator, err.object);
    }

    return response;
}

fn parseNotification(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !protocol.Notification {
    const method = try allocator.dupe(u8, (obj.get("method") orelse return JsonRpcError.InvalidRequest).string);

    return protocol.Notification{
        .method = method,
        .params = if (obj.get("params")) |p| try cloneJsonValue(allocator, p) else null,
    };
}

fn parseRequestId(value: std.json.Value) !protocol.RequestId {
    return switch (value) {
        .string => |s| protocol.RequestId{ .string = s },
        .integer => |n| protocol.RequestId{ .number = n },
        .float => |f| protocol.RequestId{ .number = @intFromFloat(f) },
        .null => protocol.RequestId{ .null = {} },
        else => JsonRpcError.InvalidRequest,
    };
}

fn parseJsonRpcError(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !protocol.JsonRpcError {
    const code = @as(i32, @intCast((obj.get("code") orelse return JsonRpcError.InvalidRequest).integer));
    const message = try allocator.dupe(u8, (obj.get("message") orelse return JsonRpcError.InvalidRequest).string);

    return protocol.JsonRpcError{
        .code = code,
        .message = message,
        .data = if (obj.get("data")) |d| try cloneJsonValue(allocator, d) else null,
    };
}

fn appendJsonValue(allocator: std.mem.Allocator, buffer: *std.ArrayList(u8), value: std.json.Value) !void {
    switch (value) {
        .null => try buffer.appendSlice(allocator, "null"),
        .bool => |b| try buffer.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const num_str = try std.fmt.allocPrint(allocator, "{d}", .{i});
            defer allocator.free(num_str);
            try buffer.appendSlice(allocator, num_str);
        },
        .float => |f| {
            const num_str = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(num_str);
            try buffer.appendSlice(allocator, num_str);
        },
        .number_string => |s| try buffer.appendSlice(allocator, s),
        .string => |s| {
            try buffer.append(allocator, '"');
            // TODO: Properly escape JSON string
            try buffer.appendSlice(allocator, s);
            try buffer.append(allocator, '"');
        },
        .array => |arr| {
            try buffer.append(allocator, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try buffer.append(allocator, ',');
                try appendJsonValue(allocator, buffer, item);
            }
            try buffer.append(allocator, ']');
        },
        .object => |obj| {
            try buffer.append(allocator, '{');
            var it = obj.iterator();
            var first = true;
            while (it.next()) |entry| {
                if (!first) try buffer.append(allocator, ',');
                first = false;
                try buffer.append(allocator, '"');
                try buffer.appendSlice(allocator, entry.key_ptr.*);
                try buffer.appendSlice(allocator, "\":");
                try appendJsonValue(allocator, buffer, entry.value_ptr.*);
            }
            try buffer.append(allocator, '}');
        },
    }
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => std.json.Value{ .null = {} },
        .bool => |b| std.json.Value{ .bool = b },
        .integer => |i| std.json.Value{ .integer = i },
        .float => |f| std.json.Value{ .float = f },
        .number_string => |s| std.json.Value{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| std.json.Value{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var new_array = std.json.Array.init(allocator);
            for (arr.items) |item| {
                try new_array.append(try cloneJsonValue(allocator, item));
            }
            break :blk std.json.Value{ .array = new_array };
        },
        .object => |obj| blk: {
            var new_obj = std.json.ObjectMap.init(allocator);
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                try new_obj.put(key, try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk std.json.Value{ .object = new_obj };
        },
    };
}

pub fn stringifyRequest(allocator: std.mem.Allocator, request: protocol.Request) ![]u8 {
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    try buffer.appendSlice(allocator, ",\"id\":");
    switch (request.id) {
        .string => |s| {
            try buffer.append(allocator, '"');
            try buffer.appendSlice(allocator, s);
            try buffer.append(allocator, '"');
        },
        .number => |n| {
            const num_str = try std.fmt.allocPrint(allocator, "{d}", .{n});
            defer allocator.free(num_str);
            try buffer.appendSlice(allocator, num_str);
        },
        .null => {
            try buffer.appendSlice(allocator, "null");
        },
    }

    try buffer.appendSlice(allocator, ",\"method\":\"");
    try buffer.appendSlice(allocator, request.method);
    try buffer.append(allocator, '"');

    if (request.params) |params| {
        try buffer.appendSlice(allocator, ",\"params\":");
        try appendJsonValue(allocator, &buffer, params);
    }

    try buffer.append(allocator, '}');
    return try buffer.toOwnedSlice(allocator);
}

pub fn stringifyResponse(allocator: std.mem.Allocator, response: protocol.Response) ![]u8 {
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");

    if (response.id) |id| {
        try buffer.appendSlice(allocator, ",\"id\":");
        switch (id) {
            .string => |s| {
                try buffer.append(allocator, '"');
                try buffer.appendSlice(allocator, s);
                try buffer.append(allocator, '"');
            },
            .number => |n| {
                const num_str = try std.fmt.allocPrint(allocator, "{d}", .{n});
                defer allocator.free(num_str);
                try buffer.appendSlice(allocator, num_str);
            },
            .null => try buffer.appendSlice(allocator, "null"),
        }
    } else {
        try buffer.appendSlice(allocator, ",\"id\":null");
    }

    if (response.result) |result| {
        try buffer.appendSlice(allocator, ",\"result\":");
        try appendJsonValue(allocator, &buffer, result);
    }

    if (response.@"error") |err| {
        try buffer.appendSlice(allocator, ",\"error\":{");
        try buffer.appendSlice(allocator, "\"code\":");
        const code_str = try std.fmt.allocPrint(allocator, "{d}", .{err.code});
        defer allocator.free(code_str);
        try buffer.appendSlice(allocator, code_str);
        try buffer.appendSlice(allocator, ",\"message\":\"");
        try buffer.appendSlice(allocator, err.message);
        try buffer.append(allocator, '"');
        if (err.data) |data| {
            try buffer.appendSlice(allocator, ",\"data\":");
            try appendJsonValue(allocator, &buffer, data);
        }
        try buffer.append(allocator, '}');
    }

    try buffer.append(allocator, '}');
    return try buffer.toOwnedSlice(allocator);
}

pub fn stringifyNotification(allocator: std.mem.Allocator, notification: protocol.Notification) ![]u8 {
    var buffer = std.ArrayList(u8){};
    defer buffer.deinit(allocator);

    try buffer.appendSlice(allocator, "{\"jsonrpc\":\"2.0\"");
    try buffer.appendSlice(allocator, ",\"method\":\"");
    try buffer.appendSlice(allocator, notification.method);
    try buffer.append(allocator, '"');

    if (notification.params) |params| {
        try buffer.appendSlice(allocator, ",\"params\":");
        try appendJsonValue(allocator, &buffer, params);
    }

    try buffer.append(allocator, '}');
    return try buffer.toOwnedSlice(allocator);
}

test "parse and stringify request" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1.0"}}
    ;

    const message = try parseMessage(allocator, json_text);
    defer freeMessage(allocator, message);

    try testing.expect(message == .request);
    try testing.expectEqualStrings("initialize", message.request.method);
    try testing.expect(message.request.id.number == 1);

    const stringified = try stringifyRequest(allocator, message.request);
    defer allocator.free(stringified);

    const reparsed = try parseMessage(allocator, stringified);
    defer freeMessage(allocator, reparsed);

    try testing.expectEqualStrings(message.request.method, reparsed.request.method);
}

test "parse and stringify response" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"1.0"}}
    ;

    const message = try parseMessage(allocator, json_text);
    defer freeMessage(allocator, message);

    try testing.expect(message == .response);
    try testing.expect(message.response.id != null);
    try testing.expect(message.response.result != null);

    const stringified = try stringifyResponse(allocator, message.response);
    defer allocator.free(stringified);

    const reparsed = try parseMessage(allocator, stringified);
    defer freeMessage(allocator, reparsed);

    try testing.expect(reparsed == .response);
}

test "parse error response" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const json_text =
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}
    ;

    const message = try parseMessage(allocator, json_text);
    defer freeMessage(allocator, message);

    try testing.expect(message == .response);
    try testing.expect(message.response.@"error" != null);
    try testing.expect(message.response.@"error".?.code == -32601);
    try testing.expectEqualStrings("Method not found", message.response.@"error".?.message);
}

fn freeMessage(allocator: std.mem.Allocator, message: protocol.JsonRpcMessage) void {
    switch (message) {
        .request => |req| {
            allocator.free(req.method);
            if (req.params) |p| freeJsonValue(allocator, p);
        },
        .response => |res| {
            if (res.result) |r| freeJsonValue(allocator, r);
            if (res.@"error") |e| {
                allocator.free(e.message);
                if (e.data) |d| freeJsonValue(allocator, d);
            }
        },
        .notification => |notif| {
            allocator.free(notif.method);
            if (notif.params) |p| freeJsonValue(allocator, p);
        },
    }
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string, .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            @constCast(&obj).deinit();
        },
        else => {},
    }
}
