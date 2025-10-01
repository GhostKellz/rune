//! JSON Schema validation for MCP tools and resources
const std = @import("std");

pub const SchemaError = error{
    ValidationFailed,
    TypeMismatch,
    RequiredFieldMissing,
    InvalidFormat,
    OutOfBounds,
};

/// Basic JSON Schema types
pub const SchemaType = enum {
    object,
    array,
    string,
    number,
    integer,
    boolean,
    null_type,

    pub fn fromString(str: []const u8) ?SchemaType {
        if (std.mem.eql(u8, str, "object")) return .object;
        if (std.mem.eql(u8, str, "array")) return .array;
        if (std.mem.eql(u8, str, "string")) return .string;
        if (std.mem.eql(u8, str, "number")) return .number;
        if (std.mem.eql(u8, str, "integer")) return .integer;
        if (std.mem.eql(u8, str, "boolean")) return .boolean;
        if (std.mem.eql(u8, str, "null")) return .null_type;
        return null;
    }
};

/// Simple JSON Schema definition
pub const Schema = struct {
    type: ?SchemaType = null,
    required: ?[]const []const u8 = null,
    properties: ?std.StringHashMap(Schema) = null,
    items: ?*const Schema = null,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    pattern: ?[]const u8 = null,
    enum_values: ?[]const std.json.Value = null,

    pub fn init(allocator: std.mem.Allocator) Schema {
        _ = allocator;
        return Schema{};
    }

    pub fn deinit(self: *Schema, allocator: std.mem.Allocator) void {
        if (self.properties) |*props| {
            var it = props.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(allocator);
            }
            props.deinit();
        }
        if (self.required) |req| {
            for (req) |field| {
                allocator.free(field);
            }
            allocator.free(req);
        }
        if (self.enum_values) |enums| {
            allocator.free(enums);
        }
        if (self.pattern) |pattern| {
            allocator.free(pattern);
        }
    }
};

/// Schema validator
pub const Validator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Validator {
        return Validator{ .allocator = allocator };
    }

    pub fn validate(self: *Validator, schema: Schema, value: std.json.Value) SchemaError!void {
        // Type validation
        if (schema.type) |expected_type| {
            try self.validateType(expected_type, value);
        }

        // Type-specific validations
        switch (value) {
            .object => |obj| try self.validateObject(schema, obj),
            .array => |arr| try self.validateArray(schema, arr),
            .string => |str| try self.validateString(schema, str),
            .integer => |int| try self.validateNumber(schema, @floatFromInt(int)),
            .float => |float| try self.validateNumber(schema, float),
            .bool, .null => {}, // No additional validation needed
            else => {},
        }
    }

    fn validateType(self: *Validator, expected: SchemaType, value: std.json.Value) SchemaError!void {
        _ = self;
        const actual = switch (value) {
            .object => SchemaType.object,
            .array => SchemaType.array,
            .string => SchemaType.string,
            .integer => SchemaType.integer,
            .float => SchemaType.number,
            .bool => SchemaType.boolean,
            .null => SchemaType.null_type,
            else => return SchemaError.TypeMismatch,
        };

        // Allow integer to match number type
        if (expected == .number and actual == .integer) {
            return;
        }

        if (expected != actual) {
            return SchemaError.TypeMismatch;
        }
    }

    fn validateObject(self: *Validator, schema: Schema, obj: std.json.ObjectMap) SchemaError!void {
        // Check required fields
        if (schema.required) |required_fields| {
            for (required_fields) |field| {
                if (!obj.contains(field)) {
                    return SchemaError.RequiredFieldMissing;
                }
            }
        }

        // Validate properties
        if (schema.properties) |properties| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (properties.get(entry.key_ptr.*)) |prop_schema| {
                    try self.validate(prop_schema, entry.value_ptr.*);
                }
            }
        }
    }

    fn validateArray(self: *Validator, schema: Schema, arr: std.json.Array) SchemaError!void {
        // Validate array items
        if (schema.items) |item_schema| {
            for (arr.items) |item| {
                try self.validate(item_schema.*, item);
            }
        }
    }

    fn validateString(self: *Validator, schema: Schema, str: []const u8) SchemaError!void {
        _ = self;
        // Length validation
        if (schema.min_length) |min_len| {
            if (str.len < min_len) {
                return SchemaError.OutOfBounds;
            }
        }

        if (schema.max_length) |max_len| {
            if (str.len > max_len) {
                return SchemaError.OutOfBounds;
            }
        }

        // Pattern validation (simplified - would need regex library)
        if (schema.pattern) |_| {
            // TODO: Implement regex pattern matching
            // For now, just accept any string
        }
    }

    fn validateNumber(self: *Validator, schema: Schema, num: f64) SchemaError!void {
        _ = self;
        // Range validation
        if (schema.minimum) |min| {
            if (num < min) {
                return SchemaError.OutOfBounds;
            }
        }

        if (schema.maximum) |max| {
            if (num > max) {
                return SchemaError.OutOfBounds;
            }
        }
    }
};

/// Parse a JSON Schema from a JSON value
pub fn parseSchema(allocator: std.mem.Allocator, json_schema: std.json.Value) !Schema {
    var schema = Schema.init(allocator);

    const obj = switch (json_schema) {
        .object => |o| o,
        else => return schema, // Invalid schema, return empty
    };

    // Parse type
    if (obj.get("type")) |type_val| {
        if (type_val == .string) {
            schema.type = SchemaType.fromString(type_val.string);
        }
    }

    // Parse required fields
    if (obj.get("required")) |required_val| {
        if (required_val == .array) {
            const required_array = required_val.array;
            var required_fields = try allocator.alloc([]const u8, required_array.items.len);
            for (required_array.items, 0..) |item, i| {
                if (item == .string) {
                    required_fields[i] = try allocator.dupe(u8, item.string);
                }
            }
            schema.required = required_fields;
        }
    }

    // Parse properties
    if (obj.get("properties")) |props_val| {
        if (props_val == .object) {
            var properties = std.StringHashMap(Schema).init(allocator);
            var it = props_val.object.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const prop_schema = try parseSchema(allocator, entry.value_ptr.*);
                try properties.put(key, prop_schema);
            }
            schema.properties = properties;
        }
    }

    // Parse numeric constraints
    if (obj.get("minimum")) |min_val| {
        if (min_val == .float) {
            schema.minimum = min_val.float;
        } else if (min_val == .integer) {
            schema.minimum = @floatFromInt(min_val.integer);
        }
    }

    if (obj.get("maximum")) |max_val| {
        if (max_val == .float) {
            schema.maximum = max_val.float;
        } else if (max_val == .integer) {
            schema.maximum = @floatFromInt(max_val.integer);
        }
    }

    // Parse string constraints
    if (obj.get("minLength")) |min_len_val| {
        if (min_len_val == .integer) {
            schema.min_length = @intCast(min_len_val.integer);
        }
    }

    if (obj.get("maxLength")) |max_len_val| {
        if (max_len_val == .integer) {
            schema.max_length = @intCast(max_len_val.integer);
        }
    }

    if (obj.get("pattern")) |pattern_val| {
        if (pattern_val == .string) {
            schema.pattern = try allocator.dupe(u8, pattern_val.string);
        }
    }

    return schema;
}

test "basic schema validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = Validator.init(allocator);

    // Test string validation
    const string_schema = Schema{ .type = .string, .min_length = 3, .max_length = 10 };
    const valid_string = std.json.Value{ .string = "hello" };
    const invalid_string = std.json.Value{ .string = "hi" }; // Too short

    try validator.validate(string_schema, valid_string);
    try testing.expectError(SchemaError.OutOfBounds, validator.validate(string_schema, invalid_string));

    // Test number validation
    const number_schema = Schema{ .type = .number, .minimum = 0, .maximum = 100 };
    const valid_number = std.json.Value{ .float = 50.0 };
    const invalid_number = std.json.Value{ .float = 150.0 }; // Too high

    try validator.validate(number_schema, valid_number);
    try testing.expectError(SchemaError.OutOfBounds, validator.validate(number_schema, invalid_number));
}

test "object schema validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var validator = Validator.init(allocator);

    // Create a simple object schema
    var properties = std.StringHashMap(Schema).init(allocator);
    defer properties.deinit();

    try properties.put("name", Schema{ .type = .string });
    try properties.put("age", Schema{ .type = .integer, .minimum = 0 });

    const required_fields = [_][]const u8{"name"};
    const object_schema = Schema{
        .type = .object,
        .properties = properties,
        .required = &required_fields,
    };

    // Test valid object
    var valid_obj = std.json.ObjectMap.init(allocator);
    defer valid_obj.deinit();
    try valid_obj.put("name", std.json.Value{ .string = "John" });
    try valid_obj.put("age", std.json.Value{ .integer = 30 });

    const valid_value = std.json.Value{ .object = valid_obj };
    try validator.validate(object_schema, valid_value);

    // Test invalid object (missing required field)
    var invalid_obj = std.json.ObjectMap.init(allocator);
    defer invalid_obj.deinit();
    try invalid_obj.put("age", std.json.Value{ .integer = 30 });

    const invalid_value = std.json.Value{ .object = invalid_obj };
    try testing.expectError(SchemaError.RequiredFieldMissing, validator.validate(object_schema, invalid_value));
}
