//! Zero-copy buffer management for high-performance text operations
//! Provides efficient data structures for streaming, large files, and string manipulation

const std = @import("std");
const mem = std.mem;
const math = std.math;

//-----------------------------------------------------------------------------
// Ring Buffer - Efficient streaming data buffer
//-----------------------------------------------------------------------------

/// Circular buffer for streaming data with zero-copy operations
pub const RingBuffer = struct {
    buffer: []u8,
    read_pos: usize,
    write_pos: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, buffer_capacity: usize) !Self {
        const buffer = try allocator.alloc(u8, buffer_capacity);
        return Self{
            .buffer = buffer,
            .read_pos = 0,
            .write_pos = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.buffer);
    }

    /// Get available space for writing
    pub fn availableWrite(self: Self) usize {
        if (self.write_pos >= self.read_pos) {
            return self.buffer.len - (self.write_pos - self.read_pos) - 1;
        } else {
            return self.read_pos - self.write_pos - 1;
        }
    }

    /// Get available data for reading
    pub fn availableRead(self: Self) usize {
        if (self.write_pos >= self.read_pos) {
            return self.write_pos - self.read_pos;
        } else {
            return self.buffer.len - (self.read_pos - self.write_pos);
        }
    }

    /// Write data to the buffer
    pub fn write(self: *Self, data: []const u8) usize {
        const available = self.availableWrite();
        const to_write = @min(data.len, available);

        if (to_write == 0) return 0;

        const first_chunk = @min(to_write, self.buffer.len - self.write_pos);
        @memcpy(self.buffer[self.write_pos..self.write_pos + first_chunk], data[0..first_chunk]);

        if (first_chunk < to_write) {
            const second_chunk = to_write - first_chunk;
            @memcpy(self.buffer[0..second_chunk], data[first_chunk..to_write]);
            self.write_pos = second_chunk;
        } else {
            self.write_pos = (self.write_pos + to_write) % self.buffer.len;
        }

        return to_write;
    }

    /// Read data from the buffer
    pub fn read(self: *Self, dest: []u8) usize {
        const available = self.availableRead();
        const to_read = @min(dest.len, available);

        if (to_read == 0) return 0;

        const first_chunk = @min(to_read, self.buffer.len - self.read_pos);
        @memcpy(dest[0..first_chunk], self.buffer[self.read_pos..self.read_pos + first_chunk]);

        if (first_chunk < to_read) {
            const second_chunk = to_read - first_chunk;
            @memcpy(dest[first_chunk..to_read], self.buffer[0..second_chunk]);
            self.read_pos = second_chunk;
        } else {
            self.read_pos = (self.read_pos + to_read) % self.buffer.len;
        }

        return to_read;
    }

    /// Peek at data without consuming it
    pub fn peek(self: Self, dest: []u8) usize {
        const available = self.availableRead();
        const to_peek = @min(dest.len, available);

        if (to_peek == 0) return 0;

        const read_pos = self.read_pos;
        const first_chunk = @min(to_peek, self.buffer.len - read_pos);
        @memcpy(dest[0..first_chunk], self.buffer[read_pos..read_pos + first_chunk]);

        if (first_chunk < to_peek) {
            const second_chunk = to_peek - first_chunk;
            @memcpy(dest[first_chunk..to_peek], self.buffer[0..second_chunk]);
        }

        return to_peek;
    }

    /// Skip data without reading
    pub fn skip(self: *Self, count: usize) usize {
        const available = self.availableRead();
        const to_skip = @min(count, available);
        self.read_pos = (self.read_pos + to_skip) % self.buffer.len;
        return to_skip;
    }

    /// Reset buffer to empty state
    pub fn reset(self: *Self) void {
        self.read_pos = 0;
        self.write_pos = 0;
    }

    /// Get buffer capacity
    pub fn capacity(self: Self) usize {
        return self.buffer.len;
    }
};

//-----------------------------------------------------------------------------
// Rope Data Structure - Efficient large text handling
//-----------------------------------------------------------------------------

/// Rope node for efficient text manipulation
pub const RopeNode = union(enum) {
    leaf: struct {
        data: []const u8,
        allocator: std.mem.Allocator,
    },
    branch: struct {
        left: *RopeNode,
        right: *RopeNode,
        weight: usize, // Weight of left subtree
    },

    pub fn deinit(self: *RopeNode, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .leaf => |*leaf| {
                allocator.free(leaf.data);
            },
            .branch => |*branch| {
                branch.left.deinit(allocator);
                branch.right.deinit(allocator);
                allocator.destroy(branch.left);
                allocator.destroy(branch.right);
            },
        }
    }

    pub fn len(self: RopeNode) usize {
        return switch (self) {
            .leaf => |leaf| leaf.data.len,
            .branch => |branch| branch.weight + branch.right.len(),
        };
    }
};

/// Rope data structure for efficient large text manipulation
pub const Rope = struct {
    root: ?*RopeNode,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .root = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.root) |root| {
            root.deinit(self.allocator);
            self.allocator.destroy(root);
        }
    }

    /// Create rope from string
    pub fn fromString(allocator: std.mem.Allocator, str: []const u8) !Self {
        const data = try allocator.dupe(u8, str);
        const node = try allocator.create(RopeNode);
        node.* = RopeNode{ .leaf = .{ .data = data, .allocator = allocator } };

        return Self{
            .root = node,
            .allocator = allocator,
        };
    }

    /// Get total length
    pub fn len(self: Self) usize {
        return if (self.root) |root| root.len() else 0;
    }

    /// Concatenate two ropes
    pub fn concat(self: *Self, other: *Self) !void {
        if (self.root == null) {
            self.root = other.root;
            other.root = null;
            return;
        }

        if (other.root == null) return;

        const node = try self.allocator.create(RopeNode);
        node.* = RopeNode{ .branch = .{
            .left = self.root.?,
            .right = other.root.?,
            .weight = self.root.?.len(),
        } };

        self.root = node;
        other.root = null;
    }

    /// Extract substring (creates new rope)
    pub fn substring(self: Self, start: usize, end: usize) !Self {
        if (start >= end or start >= self.len()) {
            return Self.init(self.allocator);
        }

        const actual_end = @min(end, self.len());
        // TODO: Implement efficient substring extraction
        // For now, flatten and slice
        var result = try self.flatten();
        defer result.deinit();

        const substr = result.items[start..actual_end];
        return try Self.fromString(self.allocator, substr);
    }

    /// Flatten rope to contiguous string
    pub fn flatten(self: Self) !std.ArrayList(u8) {
        var result = std.ArrayList(u8).init(self.allocator);
        try self.flattenInto(&result);
        return result;
    }

    fn flattenInto(self: Self, result: *std.ArrayList(u8)) !void {
        if (self.root) |root| {
            try root.flattenInto(result);
        }
    }

    fn flattenIntoNode(node: *RopeNode, result: *std.ArrayList(u8)) !void {
        switch (node.*) {
            .leaf => |leaf| {
                try result.appendSlice(leaf.data);
            },
            .branch => |branch| {
                try Rope.flattenIntoNode(branch.left, result);
                try Rope.flattenIntoNode(branch.right, result);
            },
        }
    }
};

//-----------------------------------------------------------------------------
// Copy-on-Write String View
//-----------------------------------------------------------------------------

/// Copy-on-write string view for efficient string operations
pub const CowString = union(enum) {
    borrowed: []const u8,
    owned: std.ArrayList(u8),

    const Self = @This();

    pub fn fromBorrowed(str: []const u8) Self {
        return Self{ .borrowed = str };
    }

    pub fn fromOwned(allocator: std.mem.Allocator, str: []const u8) !Self {
        var owned = std.ArrayList(u8).init(allocator);
        try owned.appendSlice(str);
        return Self{ .owned = owned };
    }

    pub fn deinit(self: *Self) void {
        switch (self.*) {
            .borrowed => {},
            .owned => |*owned| owned.deinit(),
        }
    }

    pub fn slice(self: Self) []const u8 {
        return switch (self.*) {
            .borrowed => |str| str,
            .owned => |*owned| owned.items,
        };
    }

    pub fn len(self: Self) usize {
        return self.slice().len;
    }

    /// Ensure the string is owned (copy if borrowed)
    pub fn ensureOwned(self: *Self, allocator: std.mem.Allocator) !void {
        switch (self.*) {
            .borrowed => |str| {
                var owned = std.ArrayList(u8).init(allocator);
                try owned.appendSlice(str);
                self.* = Self{ .owned = owned };
            },
            .owned => {},
        }
    }

    /// Append to the string (makes it owned if not already)
    pub fn append(self: *Self, allocator: std.mem.Allocator, str: []const u8) !void {
        try self.ensureOwned(allocator);
        switch (self.*) {
            .owned => |*owned| try owned.appendSlice(str),
            .borrowed => unreachable,
        }
    }
};

//-----------------------------------------------------------------------------
// Memory-Mapped File Handler
//-----------------------------------------------------------------------------

/// Memory-mapped file for efficient large file access
pub const MemoryMappedFile = struct {
    file: std.fs.File,
    mapped: []align(std.mem.page_size) u8,
    size: usize,

    const Self = @This();

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Self {
        _ = allocator; // Not used in this implementation

        const file = try std.fs.openFileAbsolute(path, .{ .read = true });
        const size = try file.getEndPos();

        const mapped = try std.os.mmap(
            null,
            size,
            std.os.PROT.READ,
            std.os.MAP.PRIVATE,
            file.handle,
            0,
        );

        return Self{
            .file = file,
            .mapped = mapped,
            .size = size,
        };
    }

    pub fn close(self: *Self) void {
        std.os.munmap(self.mapped);
        self.file.close();
    }

    pub fn data(self: Self) []const u8 {
        return self.mapped[0..self.size];
    }

    pub fn len(self: Self) usize {
        return self.size;
    }

    /// Get a view of a slice of the file
    pub fn slice(self: Self, start: usize, end: usize) []const u8 {
        const actual_end = @min(end, self.size);
        return self.mapped[start..actual_end];
    }
};

//-----------------------------------------------------------------------------
// Buffer Pool - Reuse buffers to reduce allocations
//-----------------------------------------------------------------------------

/// Pool of reusable buffers
pub const BufferPool = struct {
    allocator: std.mem.Allocator,
    buffers: std.ArrayList([]u8),
    buffer_size: usize,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, buffer_size: usize, initial_count: usize) !Self {
        var buffers = std.ArrayList([]u8).init(allocator);

        var i: usize = 0;
        while (i < initial_count) : (i += 1) {
            const buffer = try allocator.alloc(u8, buffer_size);
            try buffers.append(buffer);
        }

        return Self{
            .allocator = allocator,
            .buffers = buffers,
            .buffer_size = buffer_size,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.buffers.deinit();
    }

    /// Acquire a buffer from the pool
    pub fn acquire(self: *Self) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffers.items.len > 0) {
            return self.buffers.pop();
        }

        // Create new buffer if pool is empty
        return try self.allocator.alloc(u8, self.buffer_size);
    }

    /// Return a buffer to the pool
    pub fn release(self: *Self, buffer: []u8) void {
        // Only keep buffers of the expected size
        if (buffer.len != self.buffer_size) {
            self.allocator.free(buffer);
            return;
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        // Add back to pool, or free if pool is full
        if (self.buffers.items.len < 32) { // Max pool size
            self.buffers.append(buffer) catch {
                self.allocator.free(buffer);
            };
        } else {
            self.allocator.free(buffer);
        }
    }
};

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------

test "RingBuffer basic operations" {
    var ring = try RingBuffer.init(std.testing.allocator, 16);
    defer ring.deinit();

    // Test writing
    const written = ring.write("hello");
    try std.testing.expectEqual(@as(usize, 5), written);

    // Test reading
    var buf: [10]u8 = undefined;
    const read = ring.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), read);
    try std.testing.expectEqualSlices(u8, "hello", buf[0..5]);
}

test "RingBuffer wraparound" {
    var ring = try RingBuffer.init(std.testing.allocator, 8);
    defer ring.deinit();

    // Fill buffer
    _ = ring.write("1234567"); // Write 7 bytes (1 free)

    // Read 3 bytes
    var buf: [3]u8 = undefined;
    _ = ring.read(&buf);
    try std.testing.expectEqualSlices(u8, "123", &buf);

    // Write more to test wraparound
    _ = ring.write("89a"); // Should wrap around

    // Read remaining
    var buf2: [10]u8 = undefined;
    const read2 = ring.read(&buf2);
    try std.testing.expectEqual(@as(usize, 7), read2);
    try std.testing.expectEqualSlices(u8, "456789a", buf2[0..7]);
}

test "CowString operations" {
    // Test borrowed string
    var cow1 = CowString.fromBorrowed("hello");
    try std.testing.expectEqualSlices(u8, "hello", cow1.slice());

    // Test owned string
    var cow2 = try CowString.fromOwned(std.testing.allocator, "world");
    defer cow2.deinit();
    try std.testing.expectEqualSlices(u8, "world", cow2.slice());

    // Test append (makes owned)
    try cow1.append(std.testing.allocator, " world");
    defer cow1.deinit();
    try std.testing.expectEqualSlices(u8, "hello world", cow1.slice());
}

test "BufferPool basic functionality" {
    var pool = try BufferPool.init(std.testing.allocator, 1024, 2);
    defer pool.deinit();

    // Acquire buffers
    const buf1 = try pool.acquire();
    const buf2 = try pool.acquire();

    try std.testing.expectEqual(@as(usize, 1024), buf1.len);
    try std.testing.expectEqual(@as(usize, 1024), buf2.len);

    // Release buffers
    pool.release(buf1);
    pool.release(buf2);
}