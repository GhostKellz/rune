//! High-performance workspace operations for MCP tools
//! Fast enumeration, searching, and indexing across workspace files

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const file_ops = @import("file_ops.zig");
const strings = @import("../strings.zig");
const buffer = @import("../buffer.zig");

//-----------------------------------------------------------------------------
// File Metadata
//-----------------------------------------------------------------------------

/// Metadata for a workspace file
pub const FileMetadata = struct {
    path: []const u8,
    size: u64,
    mtime: i128,
    is_dir: bool,
    extension: []const u8,

    pub fn init(path: []const u8, stat: fs.File.Stat) FileMetadata {
        const ext = fs.path.extension(path);
        return FileMetadata{
            .path = path,
            .size = stat.size,
            .mtime = stat.mtime,
            .is_dir = false,
            .extension = ext,
        };
    }

    pub fn initDir(path: []const u8) FileMetadata {
        return FileMetadata{
            .path = path,
            .size = 0,
            .mtime = 0,
            .is_dir = true,
            .extension = "",
        };
    }

    pub fn deinit(self: *FileMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.extension.len > 0) {
            allocator.free(self.extension);
        }
    }
};

//-----------------------------------------------------------------------------
// Workspace Scanner
//-----------------------------------------------------------------------------

/// Fast workspace file enumeration
pub const WorkspaceScanner = struct {
    allocator: std.mem.Allocator,
    root_path: []const u8,
    exclude_patterns: std.ArrayList([]const u8),
    max_depth: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) Self {
        return Self{
            .allocator = allocator,
            .root_path = allocator.dupe(u8, root_path) catch unreachable,
            .exclude_patterns = std.ArrayList([]const u8).init(allocator),
            .max_depth = 10, // Default max depth
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.root_path);
        for (self.exclude_patterns.items) |pattern| {
            self.allocator.free(pattern);
        }
        self.exclude_patterns.deinit();
    }

    /// Add exclude pattern (glob-style)
    pub fn addExcludePattern(self: *Self, pattern: []const u8) !void {
        const duped = try self.allocator.dupe(u8, pattern);
        try self.exclude_patterns.append(duped);
    }

    /// Scan workspace and collect all files
    pub fn scanFiles(self: Self, results: *std.ArrayList(FileMetadata)) !void {
        var dir = try fs.openDirAbsolute(self.root_path, .{ .iterate = true });
        defer dir.close();

        try self.scanDirectory(dir, self.root_path, results, 0);
    }

    fn scanDirectory(self: Self, dir: fs.Dir, current_path: []const u8, results: *std.ArrayList(FileMetadata), depth: usize) !void {
        if (depth >= self.max_depth) return;

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            // Skip hidden files and excluded patterns
            if (entry.name[0] == '.' or self.isExcluded(entry.name)) continue;

            const full_path = try fs.path.join(self.allocator, &[_][]const u8{ current_path, entry.name });
            defer self.allocator.free(full_path);

            switch (entry.kind) {
                .file => {
                    const stat = try dir.statFile(entry.name);
                    const metadata = FileMetadata.init(try self.allocator.dupe(u8, full_path), stat);
                    try results.append(metadata);
                },
                .directory => {
                    var subdir = try dir.openDir(entry.name, .{ .iterate = true });
                    defer subdir.close();

                    try self.scanDirectory(subdir, full_path, results, depth + 1);
                },
                else => continue,
            }
        }
    }

    fn isExcluded(self: Self, name: []const u8) bool {
        for (self.exclude_patterns.items) |pattern| {
            if (std.mem.indexOf(u8, name, pattern) != null) return true;
        }
        return false;
    }
};

//-----------------------------------------------------------------------------
// Parallel File Searcher
//-----------------------------------------------------------------------------

/// High-performance parallel file searching
pub const ParallelFileSearcher = struct {
    allocator: std.mem.Allocator,
    thread_pool: *std.Thread.Pool,
    max_workers: usize,

    const Self = @This();
    const SearchResult = struct {
        file_path: []const u8,
        line_number: usize,
        column: usize,
        match_text: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, max_workers: usize) !Self {
        const pool = try allocator.create(std.Thread.Pool);
        try pool.init(.{ .allocator = allocator, .n_jobs = max_workers });

        return Self{
            .allocator = allocator,
            .thread_pool = pool,
            .max_workers = max_workers,
        };
    }

    pub fn deinit(self: *Self) void {
        self.thread_pool.deinit();
        self.allocator.destroy(self.thread_pool);
    }

    /// Search for pattern in files using Boyer-Moore algorithm
    pub fn searchFiles(
        self: Self,
        files: []const FileMetadata,
        pattern: []const u8,
        results: *std.ArrayList(SearchResult),
    ) !void {
        if (pattern.len == 0) return;

        // Prepare Boyer-Moore search
        var bm = strings.BoyerMoore.init(self.allocator, pattern) catch return;
        defer bm.deinit();

        // Create work items for parallel processing
        var work_items = std.ArrayList(WorkItem).init(self.allocator);
        defer work_items.deinit();

        for (files) |file| {
            if (file.is_dir) continue;

            const item = WorkItem{
                .file = file,
                .bm = &bm,
                .results = results,
                .allocator = self.allocator,
            };
            try work_items.append(item);
        }

        // Run parallel search
        for (work_items.items) |*item| {
            try self.thread_pool.spawn(WorkItem.searchFile, .{item});
        }

        // Wait for completion
        self.thread_pool.waitAndWork();
    }

    const WorkItem = struct {
        file: FileMetadata,
        bm: *const strings.BoyerMoore,
        results: *std.ArrayList(SearchResult),
        allocator: std.mem.Allocator,

        fn searchFile(self: *WorkItem) void {
            // Read file content
            const content = file_ops.readFileContent(self.file.path, self.allocator) catch return;
            defer self.allocator.free(content);

            // Search for pattern
            var line_start: usize = 0;
            var line_number: usize = 0;

            while (line_start < content.len) {
                const line_end = mem.indexOfScalar(u8, content[line_start..], '\n') orelse content.len - line_start;
                const line = content[line_start .. line_start + line_end];

                // Search within line
                var pos: usize = 0;
                while (self.bm.search(line[pos..])) |match_offset| {
                    const match_text = line[pos + match_offset .. pos + match_offset + self.bm.pattern.len];

                    const result = SearchResult{
                        .file_path = self.allocator.dupe(u8, self.file.path) catch continue,
                        .line_number = line_number,
                        .column = pos + match_offset,
                        .match_text = self.allocator.dupe(u8, match_text) catch continue,
                    };

                    self.results.append(result) catch {};

                    pos += match_offset + 1;
                    if (pos >= line.len) break;
                }

                line_start += line_end + 1;
                line_number += 1;
            }
        }
    };
};

//-----------------------------------------------------------------------------
// Symbol Index
//-----------------------------------------------------------------------------

/// Symbol information for code indexing
pub const SymbolInfo = struct {
    name: []const u8,
    kind: SymbolKind,
    file_path: []const u8,
    line: usize,
    column: usize,
    scope: ?[]const u8, // Containing scope (function, class, etc.)

    pub fn deinit(self: *SymbolInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.file_path);
        if (self.scope) |scope| allocator.free(scope);
    }
};

/// Type of symbol
pub const SymbolKind = enum {
    function,
    variable,
    class,
    method,
    field,
    constant,
    type,
    module,
    other,
};

/// Fast symbol indexing for workspace
pub const SymbolIndex = struct {
    symbols: std.StringHashMap(std.ArrayList(SymbolInfo)),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .symbols = std.StringHashMap(std.ArrayList(SymbolInfo)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.symbols.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*symbol| {
                symbol.deinit(self.allocator);
            }
            entry.value_ptr.deinit();
        }
        self.symbols.deinit();
    }

    /// Index symbols in a file
    pub fn indexFile(self: *Self, file_path: []const u8, content: []const u8) !void {
        const ext = fs.path.extension(file_path);

        // Choose indexer based on file type
        if (mem.eql(u8, ext, ".zig")) {
            try self.indexZigFile(file_path, content);
        } else if (mem.eql(u8, ext, ".rs")) {
            try self.indexRustFile(file_path, content);
        } else if (mem.eql(u8, ext, ".js") or mem.eql(u8, ext, ".ts")) {
            try self.indexJsFile(file_path, content);
        }
        // Add more languages as needed
    }

    /// Find symbols by name
    pub fn findSymbols(self: Self, name: []const u8) ?[]const SymbolInfo {
        return self.symbols.get(name);
    }

    /// Find symbols by kind
    pub fn findSymbolsByKind(self: Self, kind: SymbolKind, results: *std.ArrayList(SymbolInfo)) !void {
        var it = self.symbols.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |symbol| {
                if (symbol.kind == kind) {
                    try results.append(symbol);
                }
            }
        }
    }

    fn indexZigFile(self: *Self, file_path: []const u8, content: []const u8) !void {
        var line_iter = mem.split(u8, content, "\n");
        var line_number: usize = 0;

        while (line_iter.next()) |line| {
            // Simple Zig symbol extraction (can be enhanced with proper AST parsing)
            if (mem.indexOf(u8, line, "pub fn ") != null or mem.indexOf(u8, line, "fn ") != null) {
                const kind: SymbolKind = if (mem.indexOf(u8, line, "pub fn ") != null) .function else .function;
                const name = try self.extractSymbolName(line, "fn ");
                if (name.len > 0) {
                    const symbol = SymbolInfo{
                        .name = try self.allocator.dupe(u8, name),
                        .kind = kind,
                        .file_path = try self.allocator.dupe(u8, file_path),
                        .line = line_number,
                        .column = mem.indexOf(u8, line, name) orelse 0,
                        .scope = null,
                    };
                    try self.addSymbol(symbol);
                }
            } else if (mem.indexOf(u8, line, "const ") != null or mem.indexOf(u8, line, "var ") != null) {
                const kind: SymbolKind = if (mem.indexOf(u8, line, "const ") != null) .constant else .variable;
                const name = try self.extractSymbolName(line, if (kind == .constant) "const " else "var ");
                if (name.len > 0) {
                    const symbol = SymbolInfo{
                        .name = try self.allocator.dupe(u8, name),
                        .kind = kind,
                        .file_path = try self.allocator.dupe(u8, file_path),
                        .line = line_number,
                        .column = mem.indexOf(u8, line, name) orelse 0,
                        .scope = null,
                    };
                    try self.addSymbol(symbol);
                }
            }

            line_number += 1;
        }
    }

    fn indexRustFile(self: *Self, file_path: []const u8, content: []const u8) !void {
        var line_iter = mem.split(u8, content, "\n");
        var line_number: usize = 0;

        while (line_iter.next()) |line| {
            if (mem.indexOf(u8, line, "fn ") != null) {
                const name = try self.extractSymbolName(line, "fn ");
                if (name.len > 0) {
                    const symbol = SymbolInfo{
                        .name = try self.allocator.dupe(u8, name),
                        .kind = .function,
                        .file_path = try self.allocator.dupe(u8, file_path),
                        .line = line_number,
                        .column = mem.indexOf(u8, line, name) orelse 0,
                        .scope = null,
                    };
                    try self.addSymbol(symbol);
                }
            }

            line_number += 1;
        }
    }

    fn indexJsFile(self: *Self, file_path: []const u8, content: []const u8) !void {
        var line_iter = mem.split(u8, content, "\n");
        var line_number: usize = 0;

        while (line_iter.next()) |line| {
            if (mem.indexOf(u8, line, "function ") != null) {
                const name = try self.extractSymbolName(line, "function ");
                if (name.len > 0) {
                    const symbol = SymbolInfo{
                        .name = try self.allocator.dupe(u8, name),
                        .kind = .function,
                        .file_path = try self.allocator.dupe(u8, file_path),
                        .line = line_number,
                        .column = mem.indexOf(u8, line, name) orelse 0,
                        .scope = null,
                    };
                    try self.addSymbol(symbol);
                }
            }

            line_number += 1;
        }
    }

    fn extractSymbolName(line: []const u8, keyword: []const u8) ![]const u8 {
        const start = mem.indexOf(u8, line, keyword) orelse return "";
        const after_keyword = line[start + keyword.len ..];

        var name_end: usize = 0;
        while (name_end < after_keyword.len and
            (std.ascii.isAlphanumeric(after_keyword[name_end]) or after_keyword[name_end] == '_'))
        {
            name_end += 1;
        }

        return after_keyword[0..name_end];
    }

    fn addSymbol(self: *Self, symbol: SymbolInfo) !void {
        const gop = try self.symbols.getOrPut(symbol.name);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(SymbolInfo).init(self.allocator);
        }
        try gop.value_ptr.append(symbol);
    }
};

//-----------------------------------------------------------------------------
// Code Relationship Mapper
//-----------------------------------------------------------------------------

/// Maps relationships between code elements
pub const CodeRelationshipMapper = struct {
    relationships: std.StringHashMap(std.ArrayList(Relationship)),
    allocator: std.mem.Allocator,

    const Self = @This();

    const Relationship = struct {
        from_symbol: []const u8,
        to_symbol: []const u8,
        relationship_type: RelationshipType,
        file_path: []const u8,
        line: usize,

        pub fn deinit(self: *Relationship, allocator: std.mem.Allocator) void {
            allocator.free(self.from_symbol);
            allocator.free(self.to_symbol);
            allocator.free(self.file_path);
        }
    };

    const RelationshipType = enum {
        calls,
        inherits,
        implements,
        uses,
        imports,
        references,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .relationships = std.StringHashMap(std.ArrayList(Relationship)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.relationships.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*rel| {
                rel.deinit(self.allocator);
            }
            entry.value_ptr.deinit();
        }
        self.relationships.deinit();
    }

    /// Add a relationship between symbols
    pub fn addRelationship(
        self: *Self,
        from_symbol: []const u8,
        to_symbol: []const u8,
        rel_type: RelationshipType,
        file_path: []const u8,
        line: usize,
    ) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}->{s}", .{ from_symbol, to_symbol });
        defer self.allocator.free(key);

        const gop = try self.relationships.getOrPut(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.ArrayList(Relationship).init(self.allocator);
        }

        const relationship = Relationship{
            .from_symbol = try self.allocator.dupe(u8, from_symbol),
            .to_symbol = try self.allocator.dupe(u8, to_symbol),
            .relationship_type = rel_type,
            .file_path = try self.allocator.dupe(u8, file_path),
            .line = line,
        };

        try gop.value_ptr.append(relationship);
    }

    /// Find relationships for a symbol
    pub fn findRelationships(self: Self, symbol: []const u8) ?[]const Relationship {
        var results = std.ArrayList(Relationship).init(self.allocator);
        defer results.deinit();

        // Find relationships where symbol is the 'from'
        var from_key_buf: [256]u8 = undefined;
        const from_key = std.fmt.bufPrint(&from_key_buf, "{s}->", .{symbol}) catch return null;

        var it = self.relationships.iterator();
        while (it.next()) |entry| {
            if (mem.startsWith(u8, entry.key_ptr.*, from_key)) {
                for (entry.value_ptr.items) |rel| {
                    results.append(rel) catch {};
                }
            }
        }

        // Find relationships where symbol is the 'to'
        var to_key_buf: [256]u8 = undefined;
        const to_key = std.fmt.bufPrint(&to_key_buf, "->{s}", .{symbol}) catch return null;

        it = self.relationships.iterator();
        while (it.next()) |entry| {
            if (mem.endsWith(u8, entry.key_ptr.*, to_key)) {
                for (entry.value_ptr.items) |rel| {
                    results.append(rel) catch {};
                }
            }
        }

        return results.toOwnedSlice();
    }
};

//-----------------------------------------------------------------------------
// Workspace Manager
//-----------------------------------------------------------------------------

/// High-level workspace operations coordinator
pub const WorkspaceManager = struct {
    scanner: WorkspaceScanner,
    searcher: ParallelFileSearcher,
    symbol_index: SymbolIndex,
    relationship_mapper: CodeRelationshipMapper,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8, max_workers: usize) !Self {
        return Self{
            .scanner = WorkspaceScanner.init(allocator, root_path),
            .searcher = try ParallelFileSearcher.init(allocator, max_workers),
            .symbol_index = SymbolIndex.init(allocator),
            .relationship_mapper = CodeRelationshipMapper.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.scanner.deinit();
        self.searcher.deinit();
        self.symbol_index.deinit();
        self.relationship_mapper.deinit();
    }

    /// Build complete workspace index
    pub fn buildIndex(self: *Self) !void {
        // Scan all files
        var files = std.ArrayList(FileMetadata).init(self.allocator);
        defer {
            for (files.items) |*file| file.deinit(self.allocator);
            files.deinit();
        }

        try self.scanner.scanFiles(&files);

        // Index symbols in each file
        for (files.items) |file| {
            if (file.is_dir) continue;

            const content = file_ops.readFileContent(file.path, self.allocator) catch continue;
            defer self.allocator.free(content);

            self.symbol_index.indexFile(file.path, content) catch {};
        }
    }

    /// Search workspace for text pattern
    pub fn searchWorkspace(self: *Self, pattern: []const u8, results: *std.ArrayList(ParallelFileSearcher.SearchResult)) !void {
        var files = std.ArrayList(FileMetadata).init(self.allocator);
        defer {
            for (files.items) |*file| file.deinit(self.allocator);
            files.deinit();
        }

        try self.scanner.scanFiles(&files);
        try self.searcher.searchFiles(files.items, pattern, results);
    }

    /// Find symbol definitions
    pub fn findSymbolDefinitions(self: Self, name: []const u8) ?[]const SymbolInfo {
        return self.symbol_index.findSymbols(name);
    }

    /// Get workspace statistics
    pub fn getWorkspaceStats(self: Self) !WorkspaceStats {
        var files = std.ArrayList(FileMetadata).init(self.allocator);
        defer {
            for (files.items) |*file| file.deinit(self.allocator);
            files.deinit();
        }

        try self.scanner.scanFiles(&files);

        var stats = WorkspaceStats{
            .total_files = 0,
            .total_dirs = 0,
            .total_size = 0,
            .file_types = std.StringHashMap(u32).init(self.allocator),
        };

        for (files.items) |file| {
            if (file.is_dir) {
                stats.total_dirs += 1;
            } else {
                stats.total_files += 1;
                stats.total_size += file.size;

                const ext = file.extension;
                const gop = try stats.file_types.getOrPut(ext);
                if (!gop.found_existing) {
                    gop.value_ptr.* = 0;
                }
                gop.value_ptr.* += 1;
            }
        }

        return stats;
    }
};

/// Workspace statistics
pub const WorkspaceStats = struct {
    total_files: u32,
    total_dirs: u32,
    total_size: u64,
    file_types: std.StringHashMap(u32),

    pub fn deinit(self: *WorkspaceStats) void {
        self.file_types.deinit();
    }
};

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------

test "WorkspaceScanner basic functionality" {
    var scanner = WorkspaceScanner.init(std.testing.allocator, "/tmp");
    defer scanner.deinit();

    try scanner.addExcludePattern(".git");

    var files = std.ArrayList(FileMetadata).init(std.testing.allocator);
    defer {
        for (files.items) |*file| file.deinit(std.testing.allocator);
        files.deinit();
    }

    // Note: This test may fail if /tmp is not accessible or empty
    scanner.scanFiles(&files) catch |err| {
        if (err != error.AccessDenied) return err;
    };
}

test "SymbolIndex basic functionality" {
    var index = SymbolIndex.init(std.testing.allocator);
    defer index.deinit();

    const zig_code =
        \\pub fn main() void {
        \\    const x = 42;
        \\    var y = "hello";
        \\}
        \\
        \\fn helper() void {
        \\}
    ;

    try index.indexFile("test.zig", zig_code);

    const main_symbols = index.findSymbols("main");
    try std.testing.expect(main_symbols != null);
    try std.testing.expectEqual(@as(usize, 1), main_symbols.?.len);
    try std.testing.expectEqual(SymbolKind.function, main_symbols.?[0].kind);
}

test "CodeRelationshipMapper basic functionality" {
    var mapper = CodeRelationshipMapper.init(std.testing.allocator);
    defer mapper.deinit();

    try mapper.addRelationship("main", "helper", .calls, "test.zig", 5);

    const relationships = mapper.findRelationships("main");
    try std.testing.expect(relationships != null);
    try std.testing.expectEqual(@as(usize, 1), relationships.?.len);
    try std.testing.expectEqualSlices(u8, "helper", relationships.?[0].to_symbol);
}
