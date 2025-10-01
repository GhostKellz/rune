const std = @import("std");
const builtin = @import("builtin");

const MB = 1024 * 1024;
const ITERATIONS = 1000;

pub const BenchmarkResult = struct {
    name: []const u8,
    iterations: u32,
    min_ns: u64,
    max_ns: u64,
    avg_ns: u64,
    median_ns: u64,
    ops_per_second: f64,
    throughput_mb_per_sec: ?f64 = null,
};

pub fn benchmark(comptime name: []const u8, iterations: u32, func: anytype) !BenchmarkResult {
    var times = try std.heap.page_allocator.alloc(u64, iterations);
    defer std.heap.page_allocator.free(times);

    // Warmup
    for (0..10) |_| {
        _ = try func();
    }

    // Actual benchmark
    for (0..iterations) |i| {
        const start = std.time.nanoTimestamp();
        _ = try func();
        const end = std.time.nanoTimestamp();
        times[i] = @intCast(end - start);
    }

    // Calculate statistics
    std.sort.pdq(u64, times, {}, std.sort.asc(u64));

    var sum: u64 = 0;
    var min: u64 = times[0];
    var max: u64 = times[0];

    for (times) |time| {
        sum += time;
        if (time < min) min = time;
        if (time > max) max = time;
    }

    const avg = sum / iterations;
    const median = times[iterations / 2];
    const ops_per_second = 1_000_000_000.0 / @as(f64, @floatFromInt(avg));

    return BenchmarkResult{
        .name = name,
        .iterations = iterations,
        .min_ns = min,
        .max_ns = max,
        .avg_ns = avg,
        .median_ns = median,
        .ops_per_second = ops_per_second,
    };
}

pub fn printResult(result: BenchmarkResult) void {
    std.debug.print("\n{s}:\n", .{result.name});
    std.debug.print("  Iterations: {}\n", .{result.iterations});
    std.debug.print("  Min: {} ns\n", .{result.min_ns});
    std.debug.print("  Max: {} ns\n", .{result.max_ns});
    std.debug.print("  Avg: {} ns\n", .{result.avg_ns});
    std.debug.print("  Median: {} ns\n", .{result.median_ns});
    std.debug.print("  Ops/sec: {d:.2}\n", .{result.ops_per_second});
    if (result.throughput_mb_per_sec) |throughput| {
        std.debug.print("  Throughput: {d:.2} MB/s\n", .{throughput});
    }
}

const FileOpsBenchmark = struct {
    allocator: std.mem.Allocator,
    temp_dir: std.fs.Dir,
    test_file_path: []const u8,

    pub fn init(allocator: std.mem.Allocator) !FileOpsBenchmark {
        const temp_dir = try std.fs.cwd().makeOpenPath("benchmark_temp", .{});
        const test_file_path = try std.fmt.allocPrint(allocator, "benchmark_temp/test_file_{}.txt", .{std.time.milliTimestamp()});

        return .{
            .allocator = allocator,
            .temp_dir = temp_dir,
            .test_file_path = test_file_path,
        };
    }

    pub fn deinit(self: *FileOpsBenchmark) void {
        std.fs.cwd().deleteTree("benchmark_temp") catch {};
        self.allocator.free(self.test_file_path);
        self.temp_dir.close();
    }

    pub fn benchmarkFileWrite(self: *FileOpsBenchmark) !void {
        const data = "Hello, World! This is a benchmark test.\n" ** 100;
        const file = try std.fs.cwd().createFile(self.test_file_path, .{});
        defer file.close();
        try file.writeAll(data);
    }

    pub fn benchmarkFileRead(self: *FileOpsBenchmark) !void {
        const file = try std.fs.cwd().openFile(self.test_file_path, .{});
        defer file.close();
        var buffer: [4096]u8 = undefined;
        _ = try file.read(&buffer);
    }

    pub fn benchmarkFileSeek(self: *FileOpsBenchmark) !void {
        const file = try std.fs.cwd().openFile(self.test_file_path, .{});
        defer file.close();
        try file.seekTo(0);
        try file.seekTo(1000);
        try file.seekTo(0);
    }
};

const SelectionBenchmark = struct {
    allocator: std.mem.Allocator,
    data: []const u8,

    pub fn init(allocator: std.mem.Allocator) !SelectionBenchmark {
        const data = try allocator.alloc(u8, MB);
        for (data) |*byte| {
            byte.* = 'A';
        }
        return .{
            .allocator = allocator,
            .data = data,
        };
    }

    pub fn deinit(self: *SelectionBenchmark) void {
        self.allocator.free(self.data);
    }

    pub fn benchmarkSelection(self: *SelectionBenchmark) !void {
        var selected_ranges = std.ArrayList(struct { start: usize, end: usize }).init(self.allocator);
        defer selected_ranges.deinit();

        // Simulate text selection operations
        try selected_ranges.append(.{ .start = 0, .end = 100 });
        try selected_ranges.append(.{ .start = 500, .end = 1000 });
        try selected_ranges.append(.{ .start = 2000, .end = 3000 });

        // Simulate extraction
        for (selected_ranges.items) |range| {
            const slice = self.data[range.start..range.end];
            _ = slice;
        }
    }

    pub fn benchmarkSearch(self: *SelectionBenchmark) !void {
        const needle = "PATTERN";
        _ = std.mem.indexOf(u8, self.data, needle);
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== Rune Benchmarks ===\n", .{});
    std.debug.print("Platform: {s}\n", .{@tagName(builtin.os.tag)});
    std.debug.print("Architecture: {s}\n", .{@tagName(builtin.cpu.arch)});
    std.debug.print("\n", .{});

    // File operations benchmarks
    {
        var file_bench = try FileOpsBenchmark.init(allocator);
        defer file_bench.deinit();

        // Create test file first
        try file_bench.benchmarkFileWrite();

        const write_result = try benchmark("File Write (4KB)", ITERATIONS, struct {
            fn run() !void {
                var fb = try FileOpsBenchmark.init(allocator);
                defer fb.deinit();
                try fb.benchmarkFileWrite();
            }
        }.run);
        printResult(write_result);

        const read_result = try benchmark("File Read (4KB)", ITERATIONS, struct {
            fn run() !void {
                var fb = try FileOpsBenchmark.init(allocator);
                defer fb.deinit();
                try fb.benchmarkFileRead();
            }
        }.run);
        printResult(read_result);

        const seek_result = try benchmark("File Seek", ITERATIONS * 10, struct {
            fn run() !void {
                try file_bench.benchmarkFileSeek();
            }
        }.run);
        printResult(seek_result);
    }

    // Selection operations benchmarks
    {
        var selection_bench = try SelectionBenchmark.init(allocator);
        defer selection_bench.deinit();

        const selection_result = try benchmark("Text Selection (1MB)", ITERATIONS, struct {
            fn run() !void {
                try selection_bench.benchmarkSelection();
            }
        }.run);

        printResult(selection_result);

        const search_result = try benchmark("Text Search (1MB)", ITERATIONS, struct {
            fn run() !void {
                try selection_bench.benchmarkSearch();
            }
        }.run);
        printResult(search_result);
    }

    // Memory operations benchmarks
    {
        const alloc_result = try benchmark("Memory Allocation (1KB)", ITERATIONS * 10, struct {
            fn run() !void {
                const mem = try allocator.alloc(u8, 1024);
                defer allocator.free(mem);
                @memset(mem, 0);
            }
        }.run);
        printResult(alloc_result);

        const copy_result = try benchmark("Memory Copy (1MB)", ITERATIONS, struct {
            fn run() !void {
                const src = try allocator.alloc(u8, MB);
                defer allocator.free(src);
                const dst = try allocator.alloc(u8, MB);
                defer allocator.free(dst);
                @memcpy(dst, src);
            }
        }.run);
        printResult(copy_result);
    }

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
    std.debug.print("\nTarget Performance Goals:\n", .{});
    std.debug.print("  • File operations: >3× faster than pure Rust reference\n", .{});
    std.debug.print("  • Selection latency: <1 ms\n", .{});
}

test "benchmark framework" {
    const result = try benchmark("Test Benchmark", 10, struct {
        fn run() !void {
            std.time.sleep(1000); // 1 microsecond
        }
    }.run);

    try std.testing.expect(result.iterations == 10);
    try std.testing.expect(result.min_ns > 0);
    try std.testing.expect(result.max_ns >= result.min_ns);
    try std.testing.expect(result.avg_ns >= result.min_ns);
    try std.testing.expect(result.avg_ns <= result.max_ns);
}
