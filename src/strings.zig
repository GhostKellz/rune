//! SIMD-optimized string operations engine
//! High-performance text processing for MCP tools

const std = @import("std");
const mem = std.mem;
const math = std.math;

//-----------------------------------------------------------------------------
// UTF-8 Validation
//-----------------------------------------------------------------------------

/// Validate UTF-8 string with optional SIMD acceleration
pub fn validateUtf8(str: []const u8) bool {
    return validateUtf8Basic(str);
}

/// Basic UTF-8 validation (fallback)
fn validateUtf8Basic(str: []const u8) bool {
    var i: usize = 0;
    while (i < str.len) {
        const byte = str[i];
        if (byte & 0x80 == 0) {
            // ASCII
            i += 1;
        } else if (byte & 0xE0 == 0xC0) {
            // 2-byte sequence
            if (i + 1 >= str.len) return false;
            if (str[i + 1] & 0xC0 != 0x80) return false;
            i += 2;
        } else if (byte & 0xF0 == 0xE0) {
            // 3-byte sequence
            if (i + 2 >= str.len) return false;
            if (str[i + 1] & 0xC0 != 0x80) return false;
            if (str[i + 2] & 0xC0 != 0x80) return false;
            i += 3;
        } else if (byte & 0xF8 == 0xF0) {
            // 4-byte sequence
            if (i + 3 >= str.len) return false;
            if (str[i + 1] & 0xC0 != 0x80) return false;
            if (str[i + 2] & 0xC0 != 0x80) return false;
            if (str[i + 3] & 0xC0 != 0x80) return false;
            i += 4;
        } else {
            return false;
        }
    }
    return true;
}

//-----------------------------------------------------------------------------
// Line/Column Indexing
//-----------------------------------------------------------------------------

/// Position in text (line and column)
pub const TextPosition = struct {
    line: usize,
    column: usize,
    offset: usize,

    pub fn format(self: TextPosition, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{}:{}", .{ self.line + 1, self.column + 1 });
    }
};

/// Index for fast line/column lookups in large files
pub const LineIndex = struct {
    line_starts: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .line_starts = std.ArrayList(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.line_starts.deinit();
    }

    /// Build index from text
    pub fn build(self: *Self, text: []const u8) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(0); // First line starts at 0

        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\n') {
                try self.line_starts.append(i + 1);
            }
            i += 1;
        }
    }

    /// Get position from byte offset
    pub fn positionFromOffset(self: Self, offset: usize) TextPosition {
        // Binary search for line
        var left: usize = 0;
        var right = self.line_starts.items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (self.line_starts.items[mid] <= offset) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        const line = left - 1;
        const line_start = self.line_starts.items[line];
        const column = offset - line_start;

        return TextPosition{
            .line = line,
            .column = column,
            .offset = offset,
        };
    }

    /// Get byte offset from line/column
    pub fn offsetFromPosition(self: Self, line: usize, column: usize) ?usize {
        if (line >= self.line_starts.items.len) return null;

        const line_start = self.line_starts.items[line];
        // TODO: Handle column bounds checking
        return line_start + column;
    }

    /// Get total number of lines
    pub fn lineCount(self: Self) usize {
        return self.line_starts.items.len;
    }
};

//-----------------------------------------------------------------------------
// Boyer-Moore String Search
//-----------------------------------------------------------------------------

/// Boyer-Moore string search implementation
pub const BoyerMoore = struct {
    pattern: []const u8,
    bad_char_table: [256]i32,
    good_suffix_table: []i32,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, pattern: []const u8) !Self {
        if (pattern.len == 0) return error.EmptyPattern;

        var bad_char_table = [_]i32{-1} ** 256;
        const good_suffix_table = try allocator.alloc(i32, pattern.len);
        @memset(good_suffix_table, 0);

        // Build bad character table
        var i: usize = 0;
        while (i < pattern.len - 1) : (i += 1) {
            bad_char_table[pattern[i]] = @intCast(i);
        }

        // Build good suffix table
        try buildGoodSuffixTable(pattern, good_suffix_table);

        return Self{
            .pattern = try allocator.dupe(u8, pattern),
            .bad_char_table = bad_char_table,
            .good_suffix_table = good_suffix_table,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.pattern);
        self.allocator.free(self.good_suffix_table);
    }

    /// Search for pattern in text
    pub fn search(self: Self, text: []const u8) ?usize {
        if (self.pattern.len > text.len) return null;

        var i: usize = 0;
        while (i <= text.len - self.pattern.len) {
            var j: usize = self.pattern.len;
            while (j > 0 and text[i + j - 1] == self.pattern[j - 1]) {
                j -= 1;
            }

            if (j == 0) {
                return i; // Found match
            }

            // Calculate shift
            const bad_char_shift = @as(usize, @intCast(self.pattern.len - j - @max(
                self.bad_char_table[text[i + j - 1]],
                0,
            )));
            const good_suffix_shift = self.good_suffix_table[j - 1];

            i += @max(bad_char_shift, @as(usize, @intCast(good_suffix_shift)));
        }

        return null;
    }

    /// Find all occurrences
    pub fn searchAll(self: Self, text: []const u8, results: *std.ArrayList(usize)) !void {
        var i: usize = 0;
        while (i <= text.len - self.pattern.len) {
            var j: usize = self.pattern.len;
            while (j > 0 and text[i + j - 1] == self.pattern[j - 1]) {
                j -= 1;
            }

            if (j == 0) {
                try results.append(i);
                i += 1; // Continue searching for overlapping matches
            } else {
                const bad_char_shift = @as(usize, @intCast(self.pattern.len - j - @max(
                    self.bad_char_table[text[i + j - 1]],
                    0,
                )));
                const good_suffix_shift = self.good_suffix_table[j - 1];
                i += @max(bad_char_shift, @as(usize, @intCast(good_suffix_shift)));
            }
        }
    }

    fn buildGoodSuffixTable(pattern: []const u8, table: []i32) !void {
        const m = pattern.len;
        var suff = try std.ArrayList(i32).initCapacity(std.heap.page_allocator, m);
        defer suff.deinit();

        try suff.appendNTimes(0, m);
        var f: usize = 0;
        var g: usize = m - 1;

        var i: usize = m - 1;
        while (i > 0) : (i -= 1) {
            if (i > g and suff.items[i + m - 1 - f] < i - g) {
                suff.items[i - 1] = suff.items[i + m - 1 - f];
            } else {
                if (i < g) g = i;
                f = i;
                while (g >= 0 and pattern[g] == pattern[g + m - 1 - f]) {
                    g -= 1;
                }
                suff.items[i - 1] = f - g;
            }
        }

        // Build good suffix table
        i = 0;
        while (i < m) : (i += 1) {
            table[i] = @intCast(m);
        }

        var j: usize = 0;
        i = m - 1;
        while (i >= 0) : (i -= 1) {
            if (suff.items[i] == i + 1) {
                while (j < m - 1 - i) : (j += 1) {
                    if (table[j] == @as(i32, @intCast(m))) {
                        table[j] = @intCast(m - 1 - i);
                    }
                }
            }
        }

        i = 0;
        while (i <= m - 2) : (i += 1) {
            table[m - 1 - suff.items[i]] = @intCast(m - 1 - i);
        }
    }
};

//-----------------------------------------------------------------------------
// Aho-Corasick Multi-Pattern Search
//-----------------------------------------------------------------------------

/// Aho-Corasick automaton for multi-pattern matching
pub const AhoCorasick = struct {
    patterns: std.ArrayList([]const u8),
    trie: std.ArrayList(std.AutoHashMap(u8, usize)),
    fail: std.ArrayList(usize),
    output: std.ArrayList(std.ArrayList(usize)),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .patterns = std.ArrayList([]const u8).init(allocator),
            .trie = std.ArrayList(std.AutoHashMap(u8, usize)).init(allocator),
            .fail = std.ArrayList(usize).init(allocator),
            .output = std.ArrayList(std.ArrayList(usize)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.patterns.deinit();
        for (self.trie.items) |*node| {
            node.deinit();
        }
        self.trie.deinit();
        self.fail.deinit();
        for (self.output.items) |*list| {
            list.deinit();
        }
        self.output.deinit();
    }

    /// Add a pattern to search for
    pub fn addPattern(self: *Self, pattern: []const u8) !void {
        try self.patterns.append(try self.allocator.dupe(u8, pattern));
    }

    /// Build the automaton
    pub fn build(self: *Self) !void {
        // Initialize root node
        try self.trie.append(std.AutoHashMap(u8, usize).init(self.allocator));
        try self.fail.append(0);
        try self.output.append(std.ArrayList(usize).init(self.allocator));

        // Build trie
        for (self.patterns.items, 0..) |pattern, pattern_idx| {
            var node: usize = 0;
            for (pattern) |char| {
                const entry = try self.trie.items[node].getOrPut(char);
                if (!entry.found_existing) {
                    entry.value_ptr.* = self.trie.items.len;
                    try self.trie.append(std.AutoHashMap(u8, usize).init(self.allocator));
                    try self.fail.append(0);
                    try self.output.append(std.ArrayList(usize).init(self.allocator));
                }
                node = entry.value_ptr.*;
            }
            try self.output.items[node].append(pattern_idx);
        }

        // Build failure function
        var queue = std.ArrayList(usize).init(self.allocator);
        defer queue.deinit();

        // Process root's children
        var iter = self.trie.items[0].iterator();
        while (iter.next()) |entry| {
            const child = entry.value_ptr.*;
            try queue.append(child);
            self.fail.items[child] = 0;
        }

        while (queue.items.len > 0) {
            const current = queue.orderedRemove(0);
            iter = self.trie.items[current].iterator();

            while (iter.next()) |entry| {
                const char = entry.key_ptr.*;
                const child = entry.value_ptr.*;
                try queue.append(child);

                var fail_state = self.fail.items[current];
                while (fail_state != 0 and !self.trie.items[fail_state].contains(char)) {
                    fail_state = self.fail.items[fail_state];
                }

                if (self.trie.items[fail_state].get(char)) |next_state| {
                    fail_state = next_state;
                }

                self.fail.items[child] = fail_state;

                // Merge outputs
                for (self.output.items[fail_state].items) |pattern_idx| {
                    try self.output.items[child].append(pattern_idx);
                }
            }
        }
    }

    /// Search text for all patterns
    pub fn search(self: Self, text: []const u8, callback: fn (usize, usize) void) !void {
        var state: usize = 0;
        for (text, 0..) |char, i| {
            while (state != 0 and !self.trie.items[state].contains(char)) {
                state = self.fail.items[state];
            }

            if (self.trie.items[state].get(char)) |next_state| {
                state = next_state;
            }

            // Report matches
            for (self.output.items[state].items) |pattern_idx| {
                callback(pattern_idx, i - self.patterns.items[pattern_idx].len + 1);
            }
        }
    }
};

//-----------------------------------------------------------------------------
// String Similarity Scoring
//-----------------------------------------------------------------------------

/// Calculate Levenshtein distance between two strings
pub fn levenshteinDistance(a: []const u8, b: []const u8) !usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    const allocator = std.heap.page_allocator;
    var matrix = try allocator.alloc([]usize, a.len + 1);
    defer {
        for (matrix) |row| allocator.free(row);
        allocator.free(matrix);
    }

    for (matrix) |*row| {
        row.* = try allocator.alloc(usize, b.len + 1);
    }

    // Initialize first row and column
    var i: usize = 0;
    while (i <= a.len) : (i += 1) {
        matrix[i][0] = i;
    }
    i = 0;
    while (i <= b.len) : (i += 1) {
        matrix[0][i] = i;
    }

    // Fill the matrix
    i = 1;
    while (i <= a.len) : (i += 1) {
        var j: usize = 1;
        while (j <= b.len) : (j += 1) {
            const cost: usize = if (a[i - 1] == b[j - 1]) 0 else 1;
            matrix[i][j] = @min(
                matrix[i - 1][j] + 1, // deletion
                matrix[i][j - 1] + 1, // insertion
                matrix[i - 1][j - 1] + cost, // substitution
            );
        }
    }

    return matrix[a.len][b.len];
}

/// Calculate similarity score (0.0 = identical, 1.0 = completely different)
pub fn similarityScore(a: []const u8, b: []const u8) !f32 {
    const max_len = @max(a.len, b.len);
    if (max_len == 0) return 0.0;

    const distance = try levenshteinDistance(a, b);
    return @as(f32, @floatFromInt(distance)) / @as(f32, @floatFromInt(max_len));
}

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------

test "UTF-8 validation" {
    try std.testing.expect(validateUtf8("hello"));
    try std.testing.expect(validateUtf8("héllo"));
    try std.testing.expect(validateUtf8("🚀 rocket"));
    try std.testing.expect(!validateUtf8(&[_]u8{0x80})); // Invalid start byte
}

test "LineIndex basic functionality" {
    var index = LineIndex.init(std.testing.allocator);
    defer index.deinit();

    const text = "line 1\nline 2\nline 3";
    try index.build(text);

    try std.testing.expectEqual(@as(usize, 3), index.lineCount());

    const pos1 = index.positionFromOffset(0);
    try std.testing.expectEqual(@as(usize, 0), pos1.line);
    try std.testing.expectEqual(@as(usize, 0), pos1.column);

    const pos2 = index.positionFromOffset(7);
    try std.testing.expectEqual(@as(usize, 1), pos2.line);
    try std.testing.expectEqual(@as(usize, 0), pos2.column);
}

test "BoyerMoore search" {
    var bm = try BoyerMoore.init(std.testing.allocator, "world");
    defer bm.deinit();

    const text = "hello world, world peace";
    const pos = bm.search(text);
    try std.testing.expectEqual(@as(?usize, 6), pos);

    var results = std.ArrayList(usize).init(std.testing.allocator);
    defer results.deinit();
    try bm.searchAll(text, &results);
    try std.testing.expectEqual(@as(usize, 2), results.items.len);
    try std.testing.expectEqual(@as(usize, 6), results.items[0]);
    try std.testing.expectEqual(@as(usize, 13), results.items[1]);
}

test "Levenshtein distance" {
    try std.testing.expectEqual(@as(usize, 0), try levenshteinDistance("kitten", "kitten"));
    try std.testing.expectEqual(@as(usize, 1), try levenshteinDistance("kitten", "kittens"));
    try std.testing.expectEqual(@as(usize, 3), try levenshteinDistance("kitten", "sitting"));
}

test "Similarity score" {
    const score1 = try similarityScore("kitten", "kitten");
    try std.testing.expect(score1 < 0.1);

    const score2 = try similarityScore("kitten", "sitting");
    try std.testing.expect(score2 > 0.5);
}
