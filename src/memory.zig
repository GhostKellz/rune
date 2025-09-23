//! High-performance memory management for Rune
//! Provides specialized allocators optimized for MCP tool execution

const std = @import("std");
const builtin = @import("builtin");

//-----------------------------------------------------------------------------
// Memory Statistics and Tracking
//-----------------------------------------------------------------------------

/// Memory allocation statistics
pub const MemoryStats = struct {
    total_allocated: usize = 0,
    total_freed: usize = 0,
    current_usage: usize = 0,
    peak_usage: usize = 0,
    allocation_count: usize = 0,
    deallocation_count: usize = 0,
    arena_count: usize = 0,
    pool_count: usize = 0,

    pub fn addAllocation(self: *MemoryStats, size: usize) void {
        self.total_allocated += size;
        self.current_usage += size;
        self.allocation_count += 1;
        if (self.current_usage > self.peak_usage) {
            self.peak_usage = self.current_usage;
        }
    }

    pub fn addDeallocation(self: *MemoryStats, size: usize) void {
        self.total_freed += size;
        self.current_usage -= size;
        self.deallocation_count += 1;
    }

    pub fn reset(self: *MemoryStats) void {
        self.* = MemoryStats{};
    }

    pub fn format(self: MemoryStats, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("MemoryStats{{ allocated: {} bytes, freed: {} bytes, current: {} bytes, peak: {} bytes, allocs: {}, deallocs: {} }}",
            .{ self.total_allocated, self.total_freed, self.current_usage, self.peak_usage, self.allocation_count, self.deallocation_count });
    }
};

// Global memory statistics (thread-safe)
var global_stats: MemoryStats = .{};
var stats_mutex: std.Thread.Mutex = .{};

//-----------------------------------------------------------------------------
// Tracking Allocator - Wraps any allocator with statistics and leak detection
//-----------------------------------------------------------------------------

pub fn TrackingAllocator(comptime BackingAllocator: type) type {
    return struct {
        backing_allocator: BackingAllocator,
        stats: *MemoryStats,

        const Self = @This();

        pub fn init(backing_allocator: BackingAllocator, stats: *MemoryStats) Self {
            return Self{
                .backing_allocator = backing_allocator,
                .stats = stats,
            };
        }

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = alloc,
                    .resize = resize,
                    .free = free,
                },
            };
        }

        fn alloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const result = self.backing_allocator.vtable.alloc(
                @as(*anyopaque, @ptrCast(&self.backing_allocator)),
                len,
                ptr_align,
                ret_addr,
            );

            if (result) |_| {
                stats_mutex.lock();
                defer stats_mutex.unlock();
                self.stats.addAllocation(len);
            }

            return result;
        }

        fn resize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const old_len = buf.len;
            const success = self.backing_allocator.vtable.resize(
                @as(*anyopaque, @ptrCast(&self.backing_allocator)),
                buf,
                buf_align,
                new_len,
                ret_addr,
            );

            if (success) {
                stats_mutex.lock();
                defer stats_mutex.unlock();
                if (new_len > old_len) {
                    self.stats.addAllocation(new_len - old_len);
                } else {
                    self.stats.addDeallocation(old_len - new_len);
                }
            }

            return success;
        }

        fn free(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));

            stats_mutex.lock();
            defer stats_mutex.unlock();
            self.stats.addDeallocation(buf.len);

            self.backing_allocator.vtable.free(
                @as(*anyopaque, @ptrCast(&self.backing_allocator)),
                buf,
                buf_align,
                ret_addr,
            );
        }
    };
}

//-----------------------------------------------------------------------------
// Arena Allocator - Fast allocation for request-scoped data
//-----------------------------------------------------------------------------

/// High-performance arena allocator for temporary, request-scoped allocations
pub const ArenaAllocator = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init(backing_allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = backing_allocator,
            .arena = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    pub fn reset(self: *Self) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn getAllocator(self: *Self) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn queryCapacity(self: Self) usize {
        return self.arena.queryCapacity();
    }
};

//-----------------------------------------------------------------------------
// Object Pool - Efficient reuse of frequently allocated objects
//-----------------------------------------------------------------------------

/// Generic object pool for frequently used objects
pub fn ObjectPool(comptime T: type, comptime InitFn: fn (*T) void) type {
    return struct {
        allocator: std.mem.Allocator,
        available: std.ArrayList(*T),
        created_count: usize,
        mutex: std.Thread.Mutex,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return Self{
                .allocator = allocator,
                .available = std.ArrayList(*T).init(allocator),
                .created_count = 0,
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            for (self.available.items) |obj| {
                self.allocator.destroy(obj);
            }
            self.available.deinit();
        }

        pub fn acquire(self: *Self) !*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.available.items.len > 0) {
                return self.available.pop();
            }

            // Create new object
            const obj = try self.allocator.create(T);
            InitFn(obj);
            self.created_count += 1;
            return obj;
        }

        pub fn release(self: *Self, obj: *T) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Reset object state if needed
            InitFn(obj);

            // Add back to pool
            self.available.append(obj) catch {
                // If we can't add to pool, just destroy it
                self.allocator.destroy(obj);
            };
        }

        pub fn stats(self: *const Self) struct { created: usize, available: usize } {
            return .{
                .created = self.created_count,
                .available = self.available.items.len,
            };
        }
    };
}

//-----------------------------------------------------------------------------
// NUMA-Aware Allocator (simplified for now)
//-----------------------------------------------------------------------------

/// NUMA-aware allocator (stub implementation - would need OS-specific code)
pub const NumaAllocator = struct {
    allocator: std.mem.Allocator,
    node_id: usize,

    const Self = @This();

    pub fn init(backing_allocator: std.mem.Allocator, node_id: usize) Self {
        // TODO: Implement actual NUMA awareness
        return Self{
            .allocator = backing_allocator,
            .node_id = node_id,
        };
    }

    pub fn getAllocator(self: *Self) std.mem.Allocator {
        return self.allocator;
    }
};

//-----------------------------------------------------------------------------
// Memory Manager - High-level memory management coordinator
//-----------------------------------------------------------------------------

/// Central memory manager coordinating all allocators
pub const MemoryManager = struct {
    backing_allocator: std.mem.Allocator,
    tracking_allocator: TrackingAllocator(std.mem.Allocator),
    arena: ArenaAllocator,
    stats: MemoryStats,

    const Self = @This();

    pub fn init(backing_allocator: std.mem.Allocator) Self {
        var stats = MemoryStats{};
        const tracking = TrackingAllocator(std.mem.Allocator).init(backing_allocator, &stats);

        return Self{
            .backing_allocator = backing_allocator,
            .tracking_allocator = tracking,
            .arena = ArenaAllocator.init(backing_allocator),
            .stats = stats,
        };
    }

    pub fn deinit(self: *Self) void {
        self.arena.deinit();
    }

    /// Get tracked allocator for general use
    pub fn getTrackedAllocator(self: *Self) std.mem.Allocator {
        return self.tracking_allocator.allocator();
    }

    /// Get arena allocator for temporary allocations
    pub fn getArenaAllocator(self: *Self) std.mem.Allocator {
        return self.arena.getAllocator();
    }

    /// Reset arena for next request
    pub fn resetArena(self: *Self) void {
        self.arena.reset();
    }

    /// Get current memory statistics
    pub fn getStats(self: *const Self) MemoryStats {
        return self.stats;
    }

    /// Check for memory leaks (simplified)
    pub fn checkLeaks(self: *const Self) bool {
        return self.stats.current_usage == 0;
    }
};

//-----------------------------------------------------------------------------
// Convenience Functions
//-----------------------------------------------------------------------------

/// Create a memory manager with default settings
pub fn createManager() MemoryManager {
    return MemoryManager.init(std.heap.page_allocator);
}

/// Get global memory statistics
pub fn getGlobalStats() MemoryStats {
    stats_mutex.lock();
    defer stats_mutex.unlock();
    return global_stats;
}

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------

test "ArenaAllocator basic functionality" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const allocator = arena.getAllocator();

    const buf1 = try allocator.alloc(u8, 100);
    const buf2 = try allocator.alloc(u8, 200);

    try std.testing.expect(buf1.len == 100);
    try std.testing.expect(buf2.len == 200);

    arena.reset();

    // After reset, we can still allocate but old buffers are invalid
    const buf3 = try allocator.alloc(u8, 50);
    try std.testing.expect(buf3.len == 50);
}

test "TrackingAllocator statistics" {
    var stats = MemoryStats{};
    var tracking = TrackingAllocator(std.mem.Allocator).init(std.testing.allocator, &stats);
    const allocator = tracking.allocator();

    const buf = try allocator.alloc(u8, 100);
    try std.testing.expectEqual(@as(usize, 100), stats.total_allocated);
    try std.testing.expectEqual(@as(usize, 100), stats.current_usage);
    try std.testing.expectEqual(@as(usize, 1), stats.allocation_count);

    allocator.free(buf);
    try std.testing.expectEqual(@as(usize, 100), stats.total_freed);
    try std.testing.expectEqual(@as(usize, 0), stats.current_usage);
    try std.testing.expectEqual(@as(usize, 1), stats.deallocation_count);
}

test "ObjectPool basic functionality" {
    const TestObject = struct {
        value: usize = 0,
        fn init(obj: *@This()) void {
            obj.value = 0;
        }
    };

    var pool = ObjectPool(TestObject, TestObject.init).init(std.testing.allocator);
    defer pool.deinit();

    const obj1 = try pool.acquire();
    obj1.value = 42;

    pool.release(obj1);

    const obj2 = try pool.acquire();
    try std.testing.expectEqual(@as(usize, 0), obj2.value); // Should be reset

    const pool_stats = pool.stats();
    try std.testing.expectEqual(@as(usize, 1), pool_stats.created);
    try std.testing.expectEqual(@as(usize, 1), pool_stats.available);
}