//! High-performance diagnostics engine for MCP tools
//! Fast error extraction, linting, and code analysis

const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const strings = @import("../strings.zig");
const file_ops = @import("file_ops.zig");

//-----------------------------------------------------------------------------
// Diagnostic Types
//-----------------------------------------------------------------------------

/// Severity level of diagnostic
pub const DiagnosticSeverity = enum {
    @"error",
    warning,
    info,
    hint,
};

/// Source of diagnostic
pub const DiagnosticSource = enum {
    compiler,
    linter,
    analyzer,
    security,
    performance,
};

/// Code diagnostic information
pub const Diagnostic = struct {
    message: []const u8,
    severity: DiagnosticSeverity,
    source: DiagnosticSource,
    file_path: []const u8,
    line: usize,
    column: usize,
    length: usize,
    code: ?[]const u8, // Diagnostic code (e.g., "E001", "unused-var")
    suggestions: std.ArrayList([]const u8), // Suggested fixes

    pub fn init(
        allocator: std.mem.Allocator,
        message: []const u8,
        severity: DiagnosticSeverity,
        source: DiagnosticSource,
        file_path: []const u8,
        line: usize,
        column: usize,
        length: usize,
    ) Diagnostic {
        return Diagnostic{
            .message = allocator.dupe(u8, message) catch unreachable,
            .severity = severity,
            .source = source,
            .file_path = allocator.dupe(u8, file_path) catch unreachable,
            .line = line,
            .column = column,
            .length = length,
            .code = null,
            .suggestions = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.file_path);
        if (self.code) |code| allocator.free(code);
        for (self.suggestions.items) |suggestion| {
            allocator.free(suggestion);
        }
        self.suggestions.deinit();
    }

    /// Add a suggestion
    pub fn addSuggestion(self: *Diagnostic, suggestion: []const u8, allocator: std.mem.Allocator) !void {
        const duped = try allocator.dupe(u8, suggestion);
        try self.suggestions.append(duped);
    }

    /// Set diagnostic code
    pub fn setCode(self: *Diagnostic, code: []const u8, allocator: std.mem.Allocator) !void {
        if (self.code) |old_code| allocator.free(old_code);
        self.code = try allocator.dupe(u8, code);
    }
};

//-----------------------------------------------------------------------------
// Error Pattern Matcher
//-----------------------------------------------------------------------------

/// Fast pattern-based error extraction
pub const ErrorPatternMatcher = struct {
    patterns: std.ArrayList(ErrorPattern),
    allocator: std.mem.Allocator,

    const Self = @This();

    const ErrorPattern = struct {
        regex: []const u8, // Simple pattern matching (can be enhanced with proper regex)
        severity: DiagnosticSeverity,
        source: DiagnosticSource,
        message_template: []const u8,
        code: ?[]const u8,

        pub fn deinit(self: *ErrorPattern, allocator: std.mem.Allocator) void {
            allocator.free(self.regex);
            allocator.free(self.message_template);
            if (self.code) |code| allocator.free(code);
        }
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        var self = Self{
            .patterns = std.ArrayList(ErrorPattern).init(allocator),
            .allocator = allocator,
        };

        // Initialize with common error patterns
        self.addCommonPatterns() catch {};
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.patterns.items) |*pattern| {
            pattern.deinit(self.allocator);
        }
        self.patterns.deinit();
    }

    /// Add a custom error pattern
    pub fn addPattern(
        self: *Self,
        regex: []const u8,
        severity: DiagnosticSeverity,
        source: DiagnosticSource,
        message_template: []const u8,
        code: ?[]const u8,
    ) !void {
        const pattern = ErrorPattern{
            .regex = try self.allocator.dupe(u8, regex),
            .severity = severity,
            .source = source,
            .message_template = try self.allocator.dupe(u8, message_template),
            .code = if (code) |c| try self.allocator.dupe(u8, c) else null,
        };
        try self.patterns.append(pattern);
    }

    /// Match patterns against text and extract diagnostics
    pub fn extractDiagnostics(
        self: Self,
        text: []const u8,
        file_path: []const u8,
        diagnostics: *std.ArrayList(Diagnostic),
    ) !void {
        var line_iter = mem.split(u8, text, "\n");
        var line_number: usize = 0;

        while (line_iter.next()) |line| {
            for (self.patterns.items) |pattern| {
                if (self.matchPattern(line, pattern.regex)) {
                    const diagnostic = Diagnostic.init(
                        self.allocator,
                        pattern.message_template,
                        pattern.severity,
                        pattern.source,
                        file_path,
                        line_number,
                        0, // TODO: Extract column from pattern
                        line.len,
                    );

                    if (pattern.code) |code| {
                        try diagnostic.setCode(code, self.allocator);
                    }

                    try diagnostics.append(diagnostic);
                }
            }
            line_number += 1;
        }
    }

    fn matchPattern(self: Self, line: []const u8, pattern: []const u8) bool {
        // Simple substring matching for now (can be enhanced with regex)
        _ = self;
        return mem.indexOf(u8, line, pattern) != null;
    }

    fn addCommonPatterns(self: *Self) !void {
        // Zig compiler errors
        try self.addPattern("error:", .@"error", .compiler, "Compilation error", "ZIG001");
        try self.addPattern("unused", .warning, .linter, "Unused variable or import", "ZIG002");
        try self.addPattern("expected", .@"error", .compiler, "Type mismatch or syntax error", "ZIG003");

        // Generic patterns
        try self.addPattern("TODO", .info, .analyzer, "TODO comment found", "GEN001");
        try self.addPattern("FIXME", .warning, .analyzer, "FIXME comment found", "GEN002");
        try self.addPattern("XXX", .info, .analyzer, "XXX comment found", "GEN003");
    }
};

//-----------------------------------------------------------------------------
// Syntax Validator
//-----------------------------------------------------------------------------

/// Fast syntax validation for various languages
pub const SyntaxValidator = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Validate syntax of a file
    pub fn validateFile(self: Self, file_path: []const u8, content: []const u8, diagnostics: *std.ArrayList(Diagnostic)) !void {
        const ext = fs.path.extension(file_path);

        if (mem.eql(u8, ext, ".zig")) {
            try self.validateZigSyntax(content, file_path, diagnostics);
        } else if (mem.eql(u8, ext, ".rs")) {
            try self.validateRustSyntax(content, file_path, diagnostics);
        } else if (mem.eql(u8, ext, ".js") or mem.eql(u8, ext, ".ts")) {
            try self.validateJsSyntax(content, file_path, diagnostics);
        } else if (mem.eql(u8, ext, ".json")) {
            try self.validateJsonSyntax(content, file_path, diagnostics);
        }
    }

    fn validateZigSyntax(self: Self, content: []const u8, file_path: []const u8, diagnostics: *std.ArrayList(Diagnostic)) !void {
        // Basic bracket matching
        var brace_depth: i32 = 0;
        var paren_depth: i32 = 0;
        var bracket_depth: i32 = 0;

        var line_number: usize = 0;
        var line_iter = mem.split(u8, content, "\n");

        while (line_iter.next()) |line| {
            for (line) |char| {
                switch (char) {
                    '{' => brace_depth += 1,
                    '}' => {
                        brace_depth -= 1;
                        if (brace_depth < 0) {
                            const diagnostic = Diagnostic.init(
                                self.allocator,
                                "Unmatched closing brace",
                                .@"error",
                                .analyzer,
                                file_path,
                                line_number,
                                0,
                                1,
                            );
                            try diagnostic.setCode("ZIG_BRACE", self.allocator);
                            try diagnostics.append(diagnostic);
                            brace_depth = 0; // Reset to avoid cascading errors
                        }
                    },
                    '(' => paren_depth += 1,
                    ')' => {
                        paren_depth -= 1;
                        if (paren_depth < 0) {
                            const diagnostic = Diagnostic.init(
                                self.allocator,
                                "Unmatched closing parenthesis",
                                .@"error",
                                .analyzer,
                                file_path,
                                line_number,
                                0,
                                1,
                            );
                            try diagnostic.setCode("ZIG_PAREN", self.allocator);
                            try diagnostics.append(diagnostic);
                            paren_depth = 0;
                        }
                    },
                    '[' => bracket_depth += 1,
                    ']' => {
                        bracket_depth -= 1;
                        if (bracket_depth < 0) {
                            const diagnostic = Diagnostic.init(
                                self.allocator,
                                "Unmatched closing bracket",
                                .@"error",
                                .analyzer,
                                file_path,
                                line_number,
                                0,
                                1,
                            );
                            try diagnostic.setCode("ZIG_BRACKET", self.allocator);
                            try diagnostics.append(diagnostic);
                            bracket_depth = 0;
                        }
                    },
                    else => {},
                }
            }
            line_number += 1;
        }

        // Check for unmatched opening brackets
        if (brace_depth > 0) {
            const diagnostic = Diagnostic.init(
                self.allocator,
                "Unmatched opening brace",
                .@"error",
                .analyzer,
                file_path,
                0,
                0,
                0,
            );
            try diagnostic.setCode("ZIG_BRACE_OPEN", self.allocator);
            try diagnostics.append(diagnostic);
        }

        if (paren_depth > 0) {
            const diagnostic = Diagnostic.init(
                self.allocator,
                "Unmatched opening parenthesis",
                .@"error",
                .analyzer,
                file_path,
                0,
                0,
                0,
            );
            try diagnostic.setCode("ZIG_PAREN_OPEN", self.allocator);
            try diagnostics.append(diagnostic);
        }

        if (bracket_depth > 0) {
            const diagnostic = Diagnostic.init(
                self.allocator,
                "Unmatched opening bracket",
                .@"error",
                .analyzer,
                file_path,
                0,
                0,
                0,
            );
            try diagnostic.setCode("ZIG_BRACKET_OPEN", self.allocator);
            try diagnostics.append(diagnostic);
        }
    }

    fn validateRustSyntax(self: Self, content: []const u8, file_path: []const u8, diagnostics: *std.ArrayList(Diagnostic)) !void {
        // Basic validation for Rust
        var brace_depth: i32 = 0;
        var line_number: usize = 0;
        var line_iter = mem.split(u8, content, "\n");

        while (line_iter.next()) |line| {
            for (line) |char| {
                switch (char) {
                    '{' => brace_depth += 1,
                    '}' => {
                        brace_depth -= 1;
                        if (brace_depth < 0) {
                            const diagnostic = Diagnostic.init(
                                self.allocator,
                                "Unmatched closing brace",
                                .@"error",
                                .analyzer,
                                file_path,
                                line_number,
                                0,
                                1,
                            );
                            try diagnostic.setCode("RUST_BRACE", self.allocator);
                            try diagnostics.append(diagnostic);
                            brace_depth = 0;
                        }
                    },
                    else => {},
                }
            }
            line_number += 1;
        }
    }

    fn validateJsSyntax(self: Self, content: []const u8, file_path: []const u8, diagnostics: *std.ArrayList(Diagnostic)) !void {
        // Basic validation for JavaScript/TypeScript
        var brace_depth: i32 = 0;
        var paren_depth: i32 = 0;
        var line_number: usize = 0;
        var line_iter = mem.split(u8, content, "\n");

        while (line_iter.next()) |line| {
            for (line) |char| {
                switch (char) {
                    '{' => brace_depth += 1,
                    '}' => {
                        brace_depth -= 1;
                        if (brace_depth < 0) {
                            const diagnostic = Diagnostic.init(
                                self.allocator,
                                "Unmatched closing brace",
                                .@"error",
                                .analyzer,
                                file_path,
                                line_number,
                                0,
                                1,
                            );
                            try diagnostic.setCode("JS_BRACE", self.allocator);
                            try diagnostics.append(diagnostic);
                            brace_depth = 0;
                        }
                    },
                    '(' => paren_depth += 1,
                    ')' => {
                        paren_depth -= 1;
                        if (paren_depth < 0) {
                            const diagnostic = Diagnostic.init(
                                self.allocator,
                                "Unmatched closing parenthesis",
                                .@"error",
                                .analyzer,
                                file_path,
                                line_number,
                                0,
                                1,
                            );
                            try diagnostic.setCode("JS_PAREN", self.allocator);
                            try diagnostics.append(diagnostic);
                            paren_depth = 0;
                        }
                    },
                    else => {},
                }
            }
            line_number += 1;
        }
    }

    fn validateJsonSyntax(self: Self, content: []const u8, file_path: []const u8, diagnostics: *std.ArrayList(Diagnostic)) !void {
        // Basic JSON validation
        var brace_depth: i32 = 0;
        var bracket_depth: i32 = 0;
        var in_string = false;
        var escaped = false;

        for (content) |char| {
            if (escaped) {
                escaped = false;
                continue;
            }

            if (char == '\\') {
                escaped = true;
                continue;
            }

            if (char == '"') {
                in_string = !in_string;
                continue;
            }

            if (in_string) continue;

            switch (char) {
                '{' => brace_depth += 1,
                '}' => {
                    brace_depth -= 1;
                    if (brace_depth < 0) {
                        const diagnostic = Diagnostic.init(
                            self.allocator,
                            "Unmatched closing brace in JSON",
                            .@"error",
                            .analyzer,
                            file_path,
                            0,
                            0,
                            1,
                        );
                        try diagnostic.setCode("JSON_BRACE", self.allocator);
                        try diagnostics.append(diagnostic);
                        brace_depth = 0;
                    }
                },
                '[' => bracket_depth += 1,
                ']' => {
                    bracket_depth -= 1;
                    if (bracket_depth < 0) {
                        const diagnostic = Diagnostic.init(
                            self.allocator,
                            "Unmatched closing bracket in JSON",
                            .@"error",
                            .analyzer,
                            file_path,
                            0,
                            0,
                            1,
                        );
                        try diagnostic.setCode("JSON_BRACKET", self.allocator);
                        try diagnostics.append(diagnostic);
                        bracket_depth = 0;
                    }
                },
                else => {},
            }
        }
    }
};

//-----------------------------------------------------------------------------
// Performance Profiler
//-----------------------------------------------------------------------------

/// Code performance analysis
pub const PerformanceProfiler = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Analyze performance characteristics of code
    pub fn analyzePerformance(
        self: Self,
        content: []const u8,
        file_path: []const u8,
        diagnostics: *std.ArrayList(Diagnostic),
    ) !void {
        const ext = fs.path.extension(file_path);

        if (mem.eql(u8, ext, ".zig")) {
            try self.analyzeZigPerformance(content, file_path, diagnostics);
        }
    }

    fn analyzeZigPerformance(self: Self, content: []const u8, file_path: []const u8, diagnostics: *std.ArrayList(Diagnostic)) !void {
        var line_iter = mem.split(u8, content, "\n");
        var line_number: usize = 0;

        while (line_iter.next()) |line| {
            // Check for potential performance issues

            // Large allocations in loops
            if (mem.indexOf(u8, line, "for") != null and
                (mem.indexOf(u8, line, "alloc") != null or mem.indexOf(u8, line, "ArrayList") != null)) {
                const diagnostic = Diagnostic.init(
                    self.allocator,
                    "Potential allocation in loop - consider moving outside loop",
                    .warning,
                    .performance,
                    file_path,
                    line_number,
                    0,
                    line.len,
                );
                try diagnostic.setCode("PERF_ALLOC_LOOP", self.allocator);
                try diagnostics.append(diagnostic);
            }

            // Inefficient string concatenation
            if (mem.indexOf(u8, line, "++") != null and mem.indexOf(u8, line, "\"") != null) {
                const diagnostic = Diagnostic.init(
                    self.allocator,
                    "String concatenation with ++ is inefficient - consider ArrayList or std.fmt",
                    .info,
                    .performance,
                    file_path,
                    line_number,
                    0,
                    line.len,
                );
                try diagnostic.setCode("PERF_STR_CONCAT", self.allocator);
                try diagnostics.append(diagnostic);
            }

            line_number += 1;
        }
    }
};

//-----------------------------------------------------------------------------
// Security Scanner
//-----------------------------------------------------------------------------

/// Security vulnerability detection
pub const SecurityScanner = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// Scan for security vulnerabilities
    pub fn scanSecurity(
        self: Self,
        content: []const u8,
        file_path: []const u8,
        diagnostics: *std.ArrayList(Diagnostic),
    ) !void {
        var line_iter = mem.split(u8, content, "\n");
        var line_number: usize = 0;

        while (line_iter.next()) |line| {
            // Check for common security issues

            // Hardcoded secrets
            if (mem.indexOf(u8, line, "password") != null and mem.indexOf(u8, line, "\"") != null) {
                const diagnostic = Diagnostic.init(
                    self.allocator,
                    "Potential hardcoded password detected",
                    .@"error",
                    .security,
                    file_path,
                    line_number,
                    0,
                    line.len,
                );
                try diagnostic.setCode("SEC_HARDCODED_SECRET", self.allocator);
                try diagnostics.append(diagnostic);
            }

            // SQL injection potential
            if (mem.indexOf(u8, line, "SELECT") != null and mem.indexOf(u8, line, "+") != null) {
                const diagnostic = Diagnostic.init(
                    self.allocator,
                    "Potential SQL injection vulnerability - use parameterized queries",
                    .warning,
                    .security,
                    file_path,
                    line_number,
                    0,
                    line.len,
                );
                try diagnostic.setCode("SEC_SQL_INJECTION", self.allocator);
                try diagnostics.append(diagnostic);
            }

            // Unsafe memory operations
            if (mem.indexOf(u8, line, "@intToPtr") != null or mem.indexOf(u8, line, "undefined") != null) {
                const diagnostic = Diagnostic.init(
                    self.allocator,
                    "Unsafe memory operation detected",
                    .warning,
                    .security,
                    file_path,
                    line_number,
                    0,
                    line.len,
                );
                try diagnostic.setCode("SEC_UNSAFE_MEM", self.allocator);
                try diagnostics.append(diagnostic);
            }

            line_number += 1;
        }
    }
};

//-----------------------------------------------------------------------------
// Diagnostics Engine
//-----------------------------------------------------------------------------

/// High-level diagnostics coordinator
pub const DiagnosticsEngine = struct {
    pattern_matcher: ErrorPatternMatcher,
    syntax_validator: SyntaxValidator,
    performance_profiler: PerformanceProfiler,
    security_scanner: SecurityScanner,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .pattern_matcher = ErrorPatternMatcher.init(allocator),
            .syntax_validator = SyntaxValidator.init(allocator),
            .performance_profiler = PerformanceProfiler.init(allocator),
            .security_scanner = SecurityScanner.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pattern_matcher.deinit();
        // Other components don't need deinit
    }

    /// Run full diagnostics suite on a file
    pub fn analyzeFile(
        self: Self,
        file_path: []const u8,
        content: []const u8,
        diagnostics: *std.ArrayList(Diagnostic),
    ) !void {
        // Pattern-based error extraction
        try self.pattern_matcher.extractDiagnostics(content, file_path, diagnostics);

        // Syntax validation
        try self.syntax_validator.validateFile(file_path, content, diagnostics);

        // Performance analysis
        try self.performance_profiler.analyzePerformance(content, file_path, diagnostics);

        // Security scanning
        try self.security_scanner.scanSecurity(content, file_path, diagnostics);
    }

    /// Analyze multiple files
    pub fn analyzeFiles(
        self: Self,
        files: []const file_ops.FileMetadata,
        diagnostics: *std.ArrayList(Diagnostic),
    ) !void {
        for (files) |file| {
            if (file.is_dir) continue;

            const content = file_ops.readFileContent(file.path, self.allocator) catch continue;
            defer self.allocator.free(content);

            try self.analyzeFile(file.path, content, diagnostics);
        }
    }

    /// Get diagnostics summary
    pub fn getSummary(_: Self, diagnostics: []const Diagnostic) DiagnosticSummary {
        var summary = DiagnosticSummary{
            .total_errors = 0,
            .total_warnings = 0,
            .total_info = 0,
            .total_hints = 0,
            .by_source = std.EnumMap(DiagnosticSource, u32).initFill(0),
            .by_severity = std.EnumMap(DiagnosticSeverity, u32).initFill(0),
        };

        for (diagnostics) |diagnostic| {
            switch (diagnostic.severity) {
                .@"error" => summary.total_errors += 1,
                .warning => summary.total_warnings += 1,
                .info => summary.total_info += 1,
                .hint => summary.total_hints += 1,
            }

            summary.by_source.put(diagnostic.source, summary.by_source.get(diagnostic.source) orelse 0 + 1);
            summary.by_severity.put(diagnostic.severity, summary.by_severity.get(diagnostic.severity) orelse 0 + 1);
        }

        return summary;
    }
};

/// Summary of diagnostic results
pub const DiagnosticSummary = struct {
    total_errors: u32,
    total_warnings: u32,
    total_info: u32,
    total_hints: u32,
    by_source: std.EnumMap(DiagnosticSource, u32),
    by_severity: std.EnumMap(DiagnosticSeverity, u32),
};

//-----------------------------------------------------------------------------
// Tests
//-----------------------------------------------------------------------------

test "ErrorPatternMatcher basic functionality" {
    var matcher = ErrorPatternMatcher.init(std.testing.allocator);
    defer matcher.deinit();

    const test_content = "error: something went wrong\nunused variable x\nexpected type but found another";
    var diagnostics = std.ArrayList(Diagnostic).init(std.testing.allocator);
    defer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(std.testing.allocator);
        diagnostics.deinit();
    }

    try matcher.extractDiagnostics(test_content, "test.zig", &diagnostics);
    try std.testing.expect(diagnostics.items.len > 0);
}

test "SyntaxValidator bracket matching" {
    var validator = SyntaxValidator.init(std.testing.allocator);

    const valid_zig = "pub fn main() void {\n    const x = 42;\n}";
    var diagnostics = std.ArrayList(Diagnostic).init(std.testing.allocator);
    defer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(std.testing.allocator);
        diagnostics.deinit();
    }

    try validator.validateZigSyntax(valid_zig, "test.zig", &diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.items.len);

    const invalid_zig = "pub fn main() void {\n    const x = 42;\n"; // Missing closing brace
    try validator.validateZigSyntax(invalid_zig, "test.zig", &diagnostics);
    try std.testing.expect(diagnostics.items.len > 0);
}

test "DiagnosticsEngine integration" {
    var engine = DiagnosticsEngine.init(std.testing.allocator);
    defer engine.deinit();

    const test_code =
        \\pub fn main() void {
        \\    // TODO: implement this
        \\    const unused_var = 42;
        \\    var password = "secret123"; // Security issue
        \\}
    ;

    var diagnostics = std.ArrayList(Diagnostic).init(std.testing.allocator);
    defer {
        for (diagnostics.items) |*diagnostic| diagnostic.deinit(std.testing.allocator);
        diagnostics.deinit();
    }

    try engine.analyzeFile("test.zig", test_code, &diagnostics);

    // Should find multiple issues
    try std.testing.expect(diagnostics.items.len > 0);

    const summary = engine.getSummary(diagnostics.items);
    try std.testing.expect(summary.total_warnings > 0);
}