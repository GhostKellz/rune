//! High-performance text selection engine for MCP tools
//! Zero-copy selection extraction and manipulation

const std = @import("std");
const mem = std.mem;
const strings = @import("../strings.zig");
const buffer = @import("../buffer.zig");

//-----------------------------------------------------------------------------
// Text Position and Range
//-----------------------------------------------------------------------------

/// Position in text (line and column)
pub const Position = struct {
    line: usize,
    column: usize,

    pub fn init(line: usize, column: usize) Position {
        return .{ .line = line, .column = column };
    }

    pub fn lessThan(self: Position, other: Position) bool {
        return self.line < other.line or (self.line == other.line and self.column < other.column);
    }

    pub fn equal(self: Position, other: Position) bool {
        return self.line == other.line and self.column == other.column;
    }

    pub fn format(self: Position, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("({}, {})", .{ self.line, self.column });
    }
};

/// Range of text positions
pub const Range = struct {
    start: Position,
    end: Position,

    pub fn init(start: Position, end: Position) Range {
        return .{ .start = start, .end = end };
    }

    pub fn contains(self: Range, pos: Position) bool {
        return !pos.lessThan(self.start) and pos.lessThan(self.end);
    }

    pub fn isEmpty(self: Range) bool {
        return self.start.equal(self.end);
    }

    pub fn format(self: Range, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = fmt;
        _ = options;
        try writer.print("{} -> {}", .{ self.start, self.end });
    }
};

//-----------------------------------------------------------------------------
// Selection Types
//-----------------------------------------------------------------------------

/// Selection mode
pub const SelectionMode = enum {
    character, // Character-by-character selection
    word, // Word-based selection
    line, // Line-based selection
    block, // Rectangular block selection
};

/// Text selection with mode and anchor
pub const Selection = struct {
    range: Range,
    mode: SelectionMode,
    anchor: Position, // Where the selection started (for extending)

    pub fn init(start: Position, end: Position, mode: SelectionMode) Selection {
        return .{
            .range = Range.init(start, end),
            .mode = mode,
            .anchor = start,
        };
    }

    pub fn isEmpty(self: Selection) bool {
        return self.range.isEmpty();
    }

    pub fn contains(self: Selection, pos: Position) bool {
        return self.range.contains(pos);
    }
};

//-----------------------------------------------------------------------------
// Multi-Cursor Selection Manager
//-----------------------------------------------------------------------------

/// Manages multiple selections and cursors
pub const MultiSelection = struct {
    selections: std.ArrayList(Selection),
    primary_index: usize, // Index of primary selection
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .selections = std.ArrayList(Selection).init(allocator),
            .primary_index = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.selections.deinit();
    }

    /// Add a new selection
    pub fn addSelection(self: *Self, selection: Selection) !void {
        try self.selections.append(selection);
    }

    /// Remove selection at index
    pub fn removeSelection(self: *Self, index: usize) void {
        if (index < self.selections.items.len) {
            _ = self.selections.swapRemove(index);
            if (self.primary_index >= self.selections.items.len) {
                self.primary_index = self.selections.items.len -| 1;
            }
        }
    }

    /// Get primary selection
    pub fn primary(self: Self) ?Selection {
        if (self.primary_index < self.selections.items.len) {
            return self.selections.items[self.primary_index];
        }
        return null;
    }

    /// Set primary selection index
    pub fn setPrimary(self: *Self, index: usize) void {
        if (index < self.selections.items.len) {
            self.primary_index = index;
        }
    }

    /// Clear all selections
    pub fn clear(self: *Self) void {
        self.selections.clearRetainingCapacity();
        self.primary_index = 0;
    }

    /// Sort selections by position
    pub fn sort(self: *Self) void {
        std.sort.sort(Selection, self.selections.items, {}, struct {
            fn lessThan(_: void, a: Selection, b: Selection) bool {
                return a.range.start.lessThan(b.range.start);
            }
        }.lessThan);
    }
};

//-----------------------------------------------------------------------------
// Selection History
//-----------------------------------------------------------------------------

/// Selection history for undo/redo operations
pub const SelectionHistory = struct {
    history: std.ArrayList(MultiSelection),
    current_index: usize,
    max_history: usize,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_history: usize) Self {
        return Self{
            .history = std.ArrayList(MultiSelection).init(allocator),
            .current_index = 0,
            .max_history = max_history,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.history.items) |*selection| {
            selection.deinit();
        }
        self.history.deinit();
    }

    /// Push current selection to history
    pub fn push(self: *Self, selection: MultiSelection) !void {
        // Remove future history if we're not at the end
        while (self.history.items.len > self.current_index + 1) {
            var old = self.history.pop();
            old.deinit();
        }

        // Clone the selection
        var cloned = MultiSelection.init(self.allocator);
        for (selection.selections.items) |sel| {
            try cloned.addSelection(sel);
        }
        cloned.primary_index = selection.primary_index;

        try self.history.append(cloned);

        // Enforce max history
        if (self.history.items.len > self.max_history) {
            var old = self.history.orderedRemove(0);
            old.deinit();
        } else {
            self.current_index = self.history.items.len - 1;
        }
    }

    /// Undo to previous selection
    pub fn undo(self: *Self) ?MultiSelection {
        if (self.current_index > 0) {
            self.current_index -= 1;
            return self.cloneSelection(self.history.items[self.current_index]);
        }
        return null;
    }

    /// Redo to next selection
    pub fn redo(self: *Self) ?MultiSelection {
        if (self.current_index + 1 < self.history.items.len) {
            self.current_index += 1;
            return self.cloneSelection(self.history.items[self.current_index]);
        }
        return null;
    }

    fn cloneSelection(self: Self, selection: MultiSelection) MultiSelection {
        var cloned = MultiSelection.init(self.allocator);
        for (selection.selections.items) |sel| {
            cloned.addSelection(sel) catch {};
        }
        cloned.primary_index = selection.primary_index;
        return cloned;
    }
};

//-----------------------------------------------------------------------------
// Zero-Copy Selection Extractor
//-----------------------------------------------------------------------------

/// Extracts text selections without copying when possible
pub const SelectionExtractor = struct {
    text: []const u8,
    line_index: strings.LineIndex,

    const Self = @This();

    pub fn init(text: []const u8, allocator: std.mem.Allocator) !Self {
        var line_index = strings.LineIndex.init(allocator);
        try line_index.build(text);

        return Self{
            .text = text,
            .line_index = line_index,
        };
    }

    pub fn deinit(self: *Self) void {
        self.line_index.deinit();
    }

    /// Extract text from a single selection (zero-copy when possible)
    pub fn extractSelection(self: Self, selection: Selection) ?[]const u8 {
        const start_offset = self.line_index.offsetFromPosition(selection.range.start.line, selection.range.start.column) orelse return null;
        const end_offset = self.line_index.offsetFromPosition(selection.range.end.line, selection.range.end.column) orelse return null;

        if (start_offset >= end_offset or end_offset > self.text.len) return null;

        return self.text[start_offset..end_offset];
    }

    /// Extract text from multiple selections
    pub fn extractMultiSelection(self: Self, multi_selection: MultiSelection, results: *std.ArrayList([]const u8)) !void {
        for (multi_selection.selections.items) |selection| {
            if (self.extractSelection(selection)) |text| {
                try results.append(text);
            }
        }
    }

    /// Get current selection (simulated - would integrate with editor)
    pub fn getCurrentSelection(self: Self) ?Selection {
        // TODO: Integrate with actual editor API
        // For now, return a placeholder
        _ = self;
        return null;
    }

    /// Get latest selection from history
    pub fn getLatestSelection(_: Self, history: SelectionHistory) ?Selection {
        if (history.history.items.len > 0) {
            const latest = history.history.items[history.current_index];
            return latest.primary();
        }
        return null;
    }
};

//-----------------------------------------------------------------------------
// Text Transformation Engine
//-----------------------------------------------------------------------------

/// Fast text transformations on selections
pub const TextTransformer = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Transform text in selections
    pub fn transformSelections(
        self: Self,
        text: []const u8,
        selections: []Selection,
        transform_fn: fn ([]const u8, std.mem.Allocator) anyerror![]u8,
    ) !std.ArrayList(u8) {
        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        var last_end: usize = 0;

        // Sort selections by position
        const sorted_selections = try self.allocator.dupe(Selection, selections);
        defer self.allocator.free(sorted_selections);

        std.sort.sort(Selection, sorted_selections, {}, struct {
            fn lessThan(_: void, a: Selection, b: Selection) bool {
                return a.range.start.lessThan(b.range.start);
            }
        }.lessThan);

        for (sorted_selections) |selection| {
            const start_offset = self.offsetFromPosition(text, selection.range.start) orelse continue;
            const end_offset = self.offsetFromPosition(text, selection.range.end) orelse continue;

            // Add text before selection
            try result.appendSlice(text[last_end..start_offset]);

            // Transform selected text
            const selected_text = text[start_offset..end_offset];
            const transformed = try transform_fn(selected_text, self.allocator);
            defer self.allocator.free(transformed);

            try result.appendSlice(transformed);
            last_end = end_offset;
        }

        // Add remaining text
        try result.appendSlice(text[last_end..]);

        return result;
    }

    /// Apply transformation to single selection
    pub fn transformSelection(
        self: Self,
        text: []const u8,
        selection: Selection,
        transform_fn: fn ([]const u8, std.mem.Allocator) anyerror![]u8,
    ) ![]u8 {
        const start_offset = self.offsetFromPosition(text, selection.range.start) orelse return error.InvalidPosition;
        const end_offset = self.offsetFromPosition(text, selection.range.end) orelse return error.InvalidPosition;

        const before = text[0..start_offset];
        const selected = text[start_offset..end_offset];
        const after = text[end_offset..];

        const transformed = try transform_fn(selected, self.allocator);
        defer self.allocator.free(transformed);

        var result = std.ArrayList(u8).init(self.allocator);
        defer result.deinit();

        try result.appendSlice(before);
        try result.appendSlice(transformed);
        try result.appendSlice(after);

        return result.toOwnedSlice();
    }

    fn offsetFromPosition(self: Self, text: []const u8, pos: Position) ?usize {
        var line_index = strings.LineIndex.init(self.allocator);
        defer line_index.deinit();

        line_index.build(text) catch return null;
        return line_index.offsetFromPosition(pos.line, pos.column);
    }
};

//-----------------------------------------------------------------------------
// Visual Selection Modes
//-----------------------------------------------------------------------------

/// Handle different visual selection modes
pub const VisualSelection = struct {
    /// Convert character selection to word boundaries
    pub fn expandToWord(text: []const u8, selection: Selection) Selection {
        const start_offset = offsetFromPosition(text, selection.range.start) orelse return selection;
        const end_offset = offsetFromPosition(text, selection.range.end) orelse return selection;

        const word_start = findWordStart(text, start_offset);
        const word_end = findWordEnd(text, end_offset);

        const start_pos = positionFromOffset(text, word_start) orelse selection.range.start;
        const end_pos = positionFromOffset(text, word_end) orelse selection.range.end;

        return Selection.init(start_pos, end_pos, .word);
    }

    /// Convert character selection to line boundaries
    pub fn expandToLine(_: []const u8, selection: Selection) Selection {
        const start_pos = Position.init(selection.range.start.line, 0);
        const end_pos = Position.init(selection.range.end.line + 1, 0); // End of line

        return Selection.init(start_pos, end_pos, .line);
    }

    /// Create block selection from two positions
    pub fn createBlock(start: Position, end: Position) Selection {
        // Ensure start is top-left, end is bottom-right
        const top = @min(start.line, end.line);
        const bottom = @max(start.line, end.line);
        const left = @min(start.column, end.column);
        const right = @max(start.column, end.column);

        const block_start = Position.init(top, left);
        const block_end = Position.init(bottom, right);

        return Selection.init(block_start, block_end, .block);
    }

    fn findWordStart(text: []const u8, offset: usize) usize {
        var i = offset;
        while (i > 0 and isWordChar(text[i - 1])) {
            i -= 1;
        }
        return i;
    }

    fn findWordEnd(text: []const u8, offset: usize) usize {
        var i = offset;
        while (i < text.len and isWordChar(text[i])) {
            i += 1;
        }
        return i;
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    fn offsetFromPosition(text: []const u8, pos: Position) ?usize {
        var line_index = strings.LineIndex.init(std.heap.page_allocator);
        defer line_index.deinit();

        line_index.build(text) catch return null;
        return line_index.offsetFromPosition(pos.line, pos.column);
    }

    fn positionFromOffset(text: []const u8, offset: usize) ?Position {
        var line_index = strings.LineIndex.init(std.heap.page_allocator);
        defer line_index.deinit();

        line_index.build(text) catch return null;
        return line_index.positionFromOffset(offset);
    }
};

//-----------------------------------------------------------------------------
// Multi-Cursor Operations
//-----------------------------------------------------------------------------

/// Operations on multiple cursors/selections
pub const MultiCursorOps = struct {
    /// Add cursor above current position
    pub fn addCursorAbove(selections: *MultiSelection, count: usize) void {
        const primary = selections.primary() orelse return;

        for (0..count) |_| {
            const new_line = primary.range.start.line -| 1;
            const new_pos = Position.init(new_line, primary.range.start.column);
            const new_selection = Selection.init(new_pos, new_pos, primary.mode);
            selections.addSelection(new_selection) catch {};
        }
    }

    /// Add cursor below current position
    pub fn addCursorBelow(selections: *MultiSelection, count: usize) void {
        const primary = selections.primary() orelse return;

        for (0..count) |_| {
            const new_line = primary.range.start.line + 1;
            const new_pos = Position.init(new_line, primary.range.start.column);
            const new_selection = Selection.init(new_pos, new_pos, primary.mode);
            selections.addSelection(new_selection) catch {};
        }
    }

    /// Align cursors to same column
    pub fn alignCursors(selections: *MultiSelection) void {
        const primary = selections.primary() orelse return;
        const target_column = primary.range.start.column;

        for (selections.selections.items) |*selection| {
            selection.range.start.column = target_column;
            selection.range.end.column = target_column;
        }
    }

    /// Remove duplicate cursors
    pub fn removeDuplicateCursors(selections: *MultiSelection) void {
        var i: usize = 0;
        while (i < selections.selections.items.len) {
            var j: usize = i + 1;
            while (j < selections.selections.items.len) {
                if (selections.selections.items[i].range.start.equal(selections.selections.items[j].range.start)) {
                    _ = selections.selections.swapRemove(j);
                } else {
                    j += 1;
                }
            }
            i += 1;
        }
    }
};

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------

test "Position operations" {
    const pos1 = Position.init(1, 5);
    const pos2 = Position.init(2, 3);
    const pos3 = Position.init(1, 10);

    try std.testing.expect(pos1.lessThan(pos2));
    try std.testing.expect(!pos2.lessThan(pos1));
    try std.testing.expect(pos1.lessThan(pos3));
    try std.testing.expect(pos1.equal(pos1));
}

test "Range operations" {
    const range = Range.init(Position.init(1, 5), Position.init(1, 10));
    const pos_inside = Position.init(1, 7);
    const pos_outside = Position.init(2, 5);

    try std.testing.expect(range.contains(pos_inside));
    try std.testing.expect(!range.contains(pos_outside));
    try std.testing.expect(!range.isEmpty());
}

test "Selection operations" {
    const selection = Selection.init(Position.init(1, 5), Position.init(1, 10), .character);
    const pos_inside = Position.init(1, 7);
    const pos_outside = Position.init(2, 5);

    try std.testing.expect(selection.contains(pos_inside));
    try std.testing.expect(!selection.contains(pos_outside));
    try std.testing.expect(!selection.isEmpty());
}

test "MultiSelection basic functionality" {
    var multi = MultiSelection.init(std.testing.allocator);
    defer multi.deinit();

    const sel1 = Selection.init(Position.init(1, 0), Position.init(1, 5), .character);
    const sel2 = Selection.init(Position.init(2, 0), Position.init(2, 3), .character);

    try multi.addSelection(sel1);
    try multi.addSelection(sel2);

    try std.testing.expectEqual(@as(usize, 2), multi.selections.items.len);
    try std.testing.expect(multi.primary() != null);
}

test "SelectionExtractor basic functionality" {
    const text = "line 1\nline 2\nline 3";
    var extractor = try SelectionExtractor.init(text, std.testing.allocator);
    defer extractor.deinit();

    const selection = Selection.init(Position.init(1, 0), Position.init(1, 6), .character);
    const extracted = extractor.extractSelection(selection);

    try std.testing.expect(extracted != null);
    try std.testing.expectEqualSlices(u8, "line 2", extracted.?);
}

test "VisualSelection word expansion" {
    const text = "hello world test";
    const selection = Selection.init(Position.init(0, 6), Position.init(0, 8), .character);
    const word_selection = VisualSelection.expandToWord(text, selection);

    try std.testing.expectEqual(SelectionMode.word, word_selection.mode);
    // Should expand to "world"
    try std.testing.expectEqual(@as(usize, 6), word_selection.range.start.column);
    try std.testing.expectEqual(@as(usize, 11), word_selection.range.end.column);
}
