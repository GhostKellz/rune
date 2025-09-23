//! High-performance file operations for MCP tools
//! Memory-mapped reading, batch operations, and efficient file handling

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const time = std.time;
const buffer = @import("../buffer.zig");
const memory = @import("../memory.zig");

//-----------------------------------------------------------------------------
// File Metadata Caching
//-----------------------------------------------------------------------------

/// Cached file metadata
pub const FileMetadata = struct {
    path: []const u8,
    size: u64,
    mtime: i128,
    is_dir: bool,
    permissions: fs.File.Permissions,
    hash: ?u64, // Content hash for change detection

    pub fn deinit(self: *FileMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
};

/// File metadata cache with LRU eviction
pub const FileMetadataCache = struct {
    cache: std.StringHashMap(FileMetadata),
    lru: std.ArrayList([]const u8), // LRU order
    max_entries: usize,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) Self {
        return Self{
            .cache = std.StringHashMap(FileMetadata).init(allocator),
            .lru = std.ArrayList([]const u8).init(allocator),
            .max_entries = max_entries,
            .allocator = allocator,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
        }
        self.cache.deinit();
        self.lru.deinit();
    }

    /// Get cached metadata, or null if not cached or stale
    pub fn get(self: *Self, path: []const u8) ?FileMetadata {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.cache.getPtr(path) orelse return null;

        // Check if file has changed
        if (self.isStale(path, entry.mtime)) {
            // Remove stale entry
            self.cache.remove(path);
            if (std.mem.indexOf(u8, self.lru.items, path)) |idx| {
                _ = self.lru.swapRemove(idx);
            }
            return null;
        }

        // Move to front of LRU
        self.moveToFront(path);
        return entry.*;
    }

    /// Cache metadata
    pub fn put(self: *Self, metadata: FileMetadata) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const path_key = try self.allocator.dupe(u8, metadata.path);

        // Remove existing entry if present
        if (self.cache.fetchRemove(path_key)) |kv| {
            kv.value.deinit(self.allocator);
            if (std.mem.indexOf(u8, self.lru.items, path_key)) |idx| {
                _ = self.lru.swapRemove(idx);
            }
        }

        // Evict if at capacity
        if (self.cache.count() >= self.max_entries) {
            const lru_path = self.lru.pop();
            if (self.cache.fetchRemove(lru_path)) |kv| {
                kv.value.deinit(self.allocator);
            }
            self.allocator.free(lru_path);
        }

        // Add new entry
        try self.cache.put(path_key, metadata);
        try self.lru.append(path_key);
    }

    fn isStale(self: Self, path: []const u8, cached_mtime: i128) bool {
        const stat = fs.selfExePathAlloc(self.allocator, path) catch return true;
        defer self.allocator.free(stat);

        const file = fs.openFileAbsolute(path, .{}) catch return true;
        defer file.close();

        const mtime = file.stat() catch return true;
        return mtime.mtime != cached_mtime;
    }

    fn moveToFront(self: *Self, path: []const u8) void {
        if (std.mem.indexOf(u8, self.lru.items, path)) |idx| {
            const item = self.lru.orderedRemove(idx);
            self.lru.appendAssumeCapacity(item);
        }
    }
};

//-----------------------------------------------------------------------------
// Memory-Mapped File Reader
//-----------------------------------------------------------------------------

/// Enhanced memory-mapped file reader with caching
pub const MemoryMappedFileReader = struct {
    cache: FileMetadataCache,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .cache = FileMetadataCache.init(allocator, 1000), // Cache up to 1000 files
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
    }

    /// Read file using memory mapping for fast access
    pub fn readFileFast(self: *Self, path: []const u8) ![]const u8 {
        // Check cache first
        if (self.cache.get(path)) |metadata| {
            if (!metadata.is_dir) {
                var mmf = try buffer.MemoryMappedFile.open(self.allocator, path);
                defer mmf.close();
                return try self.allocator.dupe(u8, mmf.data());
            }
        }

        // Read and cache metadata
        var mmf = try buffer.MemoryMappedFile.open(self.allocator, path);
        defer mmf.close();

        const data = mmf.data();
        const duplicated = try self.allocator.dupe(u8, data);

        // Cache metadata
        const file = try fs.openFileAbsolute(path, .{});
        defer file.close();
        const stat = try file.stat();

        const metadata = FileMetadata{
            .path = try self.allocator.dupe(u8, path),
            .size = stat.size,
            .mtime = stat.mtime,
            .is_dir = false,
            .permissions = stat.mode,
            .hash = null, // TODO: Compute content hash
        };

        try self.cache.put(metadata);

        return duplicated;
    }

    /// Read multiple files in parallel
    pub fn readFilesBatch(self: *Self, paths: []const []const u8, results: *std.ArrayList([]const u8)) !void {
        // For now, read sequentially. TODO: Implement parallel reading
        for (paths) |path| {
            const content = try self.readFileFast(path);
            try results.append(content);
        }
    }
};

//-----------------------------------------------------------------------------
// Incremental File Saver
//-----------------------------------------------------------------------------

/// Incremental file saver with change tracking
pub const IncrementalFileSaver = struct {
    allocator: std.mem.Allocator,
    temp_dir: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const temp_dir = try fs.selfExePathAlloc(allocator, "/tmp/rune_backup");
        fs.makeDirAbsolute(temp_dir) catch {}; // Ignore if already exists

        return Self{
            .allocator = allocator,
            .temp_dir = temp_dir,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.temp_dir);
    }

    /// Save file with incremental backup
    pub fn saveIncremental(self: *Self, path: []const u8, content: []const u8) !void {
        // Create backup
        const backup_path = try self.createBackupPath(path);
        try self.backupFile(path, backup_path);

        // Write new content
        try self.writeFileAtomic(path, content);
    }

    /// Save multiple files atomically
    pub fn saveBatch(self: *Self, files: []const struct { path: []const u8, content: []const u8 }) !void {
        // Create backups first
        var backups = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (backups.items) |backup| self.allocator.free(backup);
            backups.deinit();
        }

        for (files) |file| {
            const backup_path = try self.createBackupPath(file.path);
            try backups.append(backup_path);
            try self.backupFile(file.path, backup_path);
        }

        // Write all files
        for (files) |file| {
            try self.writeFileAtomic(file.path, file.content);
        }
    }

    fn createBackupPath(self: Self, original_path: []const u8) ![]const u8 {
        const basename = fs.path.basename(original_path);
        const timestamp = time.timestamp();
        return std.fmt.allocPrint(self.allocator, "{s}/{s}.{d}.bak", .{
            self.temp_dir,
            basename,
            timestamp,
        });
    }

    fn backupFile(self: Self, src_path: []const u8, dst_path: []const u8) !void {
        _ = self; // Not used currently
        const src_file = try fs.openFileAbsolute(src_path, .{});
        defer src_file.close();

        const dst_file = try fs.createFileAbsolute(dst_path, .{});
        defer dst_file.close();

        try src_file.copyTo(dst_file);
    }

    fn writeFileAtomic(self: Self, path: []const u8, content: []const u8) !void {
        _ = self; // Not used currently
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
        defer self.allocator.free(temp_path);

        // Write to temp file
        const temp_file = try fs.createFileAbsolute(temp_path, .{});
        defer temp_file.close();
        try temp_file.writeAll(content);

        // Atomic rename
        try fs.renameAbsolute(temp_path, path);
    }
};

//-----------------------------------------------------------------------------
// File System Watcher
//-----------------------------------------------------------------------------

/// File system change watcher
pub const FileWatcher = struct {
    watched_paths: std.StringHashMap(*FileWatchCallback),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,
    running: bool,

    pub const FileWatchCallback = fn ([]const u8, FileChangeType) void;
    pub const FileChangeType = enum { created, modified, deleted, renamed };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .watched_paths = std.StringHashMap(*FileWatchCallback).init(allocator),
            .allocator = allocator,
            .mutex = .{},
            .running = false,
        };
    }

    pub fn deinit(self: *Self) void {
        self.watched_paths.deinit();
    }

    /// Watch a file or directory for changes
    pub fn watch(self: *Self, path: []const u8, callback: *FileWatchCallback) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const path_key = try self.allocator.dupe(u8, path);
        try self.watched_paths.put(path_key, callback);
    }

    /// Stop watching a path
    pub fn unwatch(self: *Self, path: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.watched_paths.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }
    }

    /// Poll for changes (simple implementation)
    pub fn pollChanges(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.watched_paths.iterator();
        while (iter.next()) |entry| {
            const path = entry.key_ptr.*;
            // TODO: Implement actual file change detection
            // For now, this is a placeholder
            _ = path;
        }
    }
};

//-----------------------------------------------------------------------------
// Batch File Processor
//-----------------------------------------------------------------------------

/// Process multiple files with parallel operations
pub const BatchFileProcessor = struct {
    allocator: std.mem.Allocator,
    thread_pool: std.Thread.Pool,
    results: std.ArrayList(BatchResult),

    pub const BatchResult = union(enum) {
        success: []const u8, // File content
        @"error": []const u8, // Error message
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !Self {
        var thread_pool = std.Thread.Pool.init(.{ .allocator = allocator });
        try thread_pool.init(.{ .allocator = allocator, .n_jobs = thread_count });

        return Self{
            .allocator = allocator,
            .thread_pool = thread_pool,
            .results = std.ArrayList(BatchResult).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.thread_pool.deinit();
        for (self.results.items) |result| {
            switch (result) {
                .success => |content| self.allocator.free(content),
                .@"error" => |err| self.allocator.free(err),
            }
        }
        self.results.deinit();
    }

    /// Process files in parallel
    pub fn processFiles(
        self: *Self,
        paths: []const []const u8,
        processor: fn ([]const u8) anyerror![]const u8,
    ) !void {
        // Reset results
        for (self.results.items) |result| {
            switch (result) {
                .success => |content| self.allocator.free(content),
                .@"error" => |err| self.allocator.free(err),
            }
        }
        self.results.clearRetainingCapacity();
        try self.results.ensureTotalCapacity(paths.len);

        // Submit jobs
        for (paths) |path| {
            try self.thread_pool.spawn(processFileJob, .{
                self, path, processor, self.results.items.len,
            });
            self.results.appendAssumeCapacity(.{ .@"error" = "" }); // Placeholder
        }

        // Wait for completion
        self.thread_pool.waitAndWork();
    }

    /// Get results
    pub fn getResults(self: Self) []BatchResult {
        return self.results.items;
    }

    fn processFileJob(
        processor: *Self,
        path: []const u8,
        file_processor: fn ([]const u8) anyerror![]const u8,
        result_index: usize,
    ) void {
        const result = processor.processSingleFile(path, file_processor);
        processor.results.items[result_index] = result;
    }

    fn processSingleFile(
        self: Self,
        path: []const u8,
        processor: fn ([]const u8) anyerror![]const u8,
    ) BatchResult {
        const content = self.readFileContent(path) catch |err| {
            const err_msg = std.fmt.allocPrint(self.allocator, "Failed to read file: {}", .{err}) catch "Unknown error";
            return .{ .@"error" = err_msg };
        };

        const processed = processor(content) catch |err| {
            self.allocator.free(content);
            const err_msg = std.fmt.allocPrint(self.allocator, "Failed to process file: {}", .{err}) catch "Unknown error";
            return .{ .@"error" = err_msg };
        };

        self.allocator.free(content);
        return .{ .success = processed };
    }

    fn readFileContent(self: Self, path: []const u8) ![]const u8 {
        const file = try fs.openFileAbsolute(path, .{});
        defer file.close();

        const size = try file.getEndPos();
        const content = try self.allocator.alloc(u8, size);
        _ = try file.readAll(content);
        return content;
    }
};

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------

test "FileMetadataCache basic functionality" {
    var cache = FileMetadataCache.init(std.testing.allocator, 10);
    defer cache.deinit();

    const test_path = "/tmp/test_file.txt";

    // Create test file
    const file = try fs.createFileAbsolute(test_path, .{});
    defer file.close();
    try file.writeAll("test content");

    const stat = try file.stat();

    const metadata = FileMetadata{
        .path = try std.testing.allocator.dupe(u8, test_path),
        .size = stat.size,
        .mtime = stat.mtime,
        .is_dir = false,
        .permissions = stat.mode,
        .hash = null,
    };

    try cache.put(metadata);
    const retrieved = cache.get(test_path);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(metadata.size, retrieved.?.size);

    // Cleanup
    fs.deleteFileAbsolute(test_path) catch {};
}

test "MemoryMappedFileReader basic functionality" {
    var reader = MemoryMappedFileReader.init(std.testing.allocator);
    defer reader.deinit();

    const test_path = "/tmp/test_mmf.txt";

    // Create test file
    const file = try fs.createFileAbsolute(test_path, .{});
    defer file.close();
    try file.writeAll("memory mapped content");

    const content = try reader.readFileFast(test_path);
    defer std.testing.allocator.free(content);

    try std.testing.expectEqualSlices(u8, "memory mapped content", content);

    // Cleanup
    fs.deleteFileAbsolute(test_path) catch {};
}

test "IncrementalFileSaver basic functionality" {
    var saver = try IncrementalFileSaver.init(std.testing.allocator);
    defer saver.deinit();

    const test_path = "/tmp/test_save.txt";

    // Initial content
    try saver.saveIncremental(test_path, "initial content");

    const file1 = try fs.openFileAbsolute(test_path, .{});
    defer file1.close();
    var buffer1: [100]u8 = undefined;
    const read1 = try file1.readAll(&buffer1);
    try std.testing.expectEqualSlices(u8, "initial content", buffer1[0..read1]);

    // Modified content
    try saver.saveIncremental(test_path, "modified content");

    const file2 = try fs.openFileAbsolute(test_path, .{});
    defer file2.close();
    var buffer2: [100]u8 = undefined;
    const read2 = try file2.readAll(&buffer2);
    try std.testing.expectEqualSlices(u8, "modified content", buffer2[0..read2]);

    // Cleanup
    fs.deleteFileAbsolute(test_path) catch {};
}
