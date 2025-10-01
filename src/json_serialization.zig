//! JSON serialization helpers for MCP protocol structures
const std = @import("std");
const protocol = @import("protocol.zig");

/// Serialize a struct to JSON Value
pub fn toJsonValue(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .Struct => try structToJson(allocator, value),
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .Slice => if (ptr_info.child == u8)
                std.json.Value{ .string = try allocator.dupe(u8, value) }
            else
                try arrayToJson(allocator, value),
            else => error.UnsupportedType,
        },
        .Array => |arr_info| if (arr_info.child == u8)
            std.json.Value{ .string = try allocator.dupe(u8, &value) }
        else
            try arrayToJson(allocator, &value),
        .Int, .ComptimeInt => std.json.Value{ .integer = @intCast(value) },
        .Float, .ComptimeFloat => std.json.Value{ .float = @floatCast(value) },
        .Bool => std.json.Value{ .bool = value },
        .Null => std.json.Value.null,
        .Optional => if (value) |v| try toJsonValue(allocator, v) else std.json.Value.null,
        .Enum => std.json.Value{ .string = try allocator.dupe(u8, @tagName(value)) },
        .Union => |union_info| {
            if (union_info.tag_type) |_| {
                // Tagged union - serialize active field
                inline for (union_info.fields) |field| {
                    if (std.mem.eql(u8, field.name, @tagName(value))) {
                        return try toJsonValue(allocator, @field(value, field.name));
                    }
                }
            }
            return error.UnsupportedType;
        },
        else => error.UnsupportedType,
    };
}

/// Deserialize JSON Value to a struct
pub fn fromJsonValue(comptime T: type, allocator: std.mem.Allocator, json_value: std.json.Value) !T {
    const type_info = @typeInfo(T);

    return switch (type_info) {
        .Struct => try jsonToStruct(T, allocator, json_value),
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .Slice => if (ptr_info.child == u8) blk: {
                if (json_value != .string) return error.TypeMismatch;
                break :blk try allocator.dupe(u8, json_value.string);
            } else try jsonToArray(ptr_info.child, allocator, json_value),
            else => error.UnsupportedType,
        },
        .Int => blk: {
            if (json_value == .integer) break :blk @intCast(json_value.integer);
            if (json_value == .float) break :blk @intFromFloat(json_value.float);
            return error.TypeMismatch;
        },
        .Float => blk: {
            if (json_value == .float) break :blk @floatCast(json_value.float);
            if (json_value == .integer) break :blk @floatFromInt(json_value.integer);
            return error.TypeMismatch;
        },
        .Bool => if (json_value == .bool) json_value.bool else error.TypeMismatch,
        .Optional => |opt_info| if (json_value == .null)
            null
        else
            try fromJsonValue(opt_info.child, allocator, json_value),
        .Enum => |enum_info| {
            if (json_value != .string) return error.TypeMismatch;
            inline for (enum_info.fields) |field| {
                if (std.mem.eql(u8, field.name, json_value.string)) {
                    return @field(T, field.name);
                }
            }
            return error.InvalidEnumValue;
        },
        else => error.UnsupportedType,
    };
}

fn structToJson(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    const type_info = @typeInfo(T);
    if (type_info != .Struct) return error.NotAStruct;

    var obj = std.json.ObjectMap.init(allocator);
    errdefer obj.deinit();

    inline for (type_info.Struct.fields) |field| {
        const field_value = @field(value, field.name);
        const field_json = try toJsonValue(allocator, field_value);
        try obj.put(try allocator.dupe(u8, field.name), field_json);
    }

    return std.json.Value{ .object = obj };
}

fn jsonToStruct(comptime T: type, allocator: std.mem.Allocator, json_value: std.json.Value) !T {
    if (json_value != .object) return error.ExpectedObject;
    const obj = json_value.object;

    var result: T = undefined;
    const type_info = @typeInfo(T);

    inline for (type_info.Struct.fields) |field| {
        if (obj.get(field.name)) |field_json| {
            @field(result, field.name) = try fromJsonValue(field.type, allocator, field_json);
        } else if (field.default_value) |default_opaque| {
            const default_value: *const field.type = @alignCast(@ptrCast(default_opaque));
            @field(result, field.name) = default_value.*;
        } else {
            return error.MissingRequiredField;
        }
    }

    return result;
}

fn arrayToJson(allocator: std.mem.Allocator, slice: anytype) !std.json.Value {
    var arr = std.json.Array.init(allocator);
    errdefer arr.deinit();

    for (slice) |item| {
        try arr.append(try toJsonValue(allocator, item));
    }

    return std.json.Value{ .array = arr };
}

fn jsonToArray(comptime T: type, allocator: std.mem.Allocator, json_value: std.json.Value) ![]T {
    if (json_value != .array) return error.ExpectedArray;
    const arr = json_value.array;

    var result = try allocator.alloc(T, arr.items.len);
    errdefer allocator.free(result);

    for (arr.items, 0..) |item, i| {
        result[i] = try fromJsonValue(T, allocator, item);
    }

    return result;
}

/// Free a JSON value and all its contained allocations
pub fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    switch (value) {
        .string, .number_string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            @constCast(&arr).deinit();
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

test "serialize basic types" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // String
    const str_json = try toJsonValue(allocator, "hello");
    defer freeJsonValue(allocator, str_json);
    try testing.expectEqualStrings("hello", str_json.string);

    // Integer
    const int_json = try toJsonValue(allocator, @as(i32, 42));
    try testing.expectEqual(@as(i64, 42), int_json.integer);

    // Boolean
    const bool_json = try toJsonValue(allocator, true);
    try testing.expect(bool_json.bool);
}

test "serialize struct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    const person = Person{ .name = "Alice", .age = 30 };
    const json = try toJsonValue(allocator, person);
    defer freeJsonValue(allocator, json);

    try testing.expect(json == .object);
    try testing.expectEqualStrings("Alice", json.object.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), json.object.get("age").?.integer);
}

test "deserialize struct" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const Person = struct {
        name: []const u8,
        age: u32,
    };

    var obj = std.json.ObjectMap.init(allocator);
    defer obj.deinit();
    try obj.put("name", std.json.Value{ .string = "Bob" });
    try obj.put("age", std.json.Value{ .integer = 25 });

    const json_value = std.json.Value{ .object = obj };
    const person = try fromJsonValue(Person, allocator, json_value);
    defer allocator.free(person.name);

    try testing.expectEqualStrings("Bob", person.name);
    try testing.expectEqual(@as(u32, 25), person.age);
}
