# Installation Guide

This guide covers how to install and set up Rune in your Zig project.

## Prerequisites

- **Zig 0.16.0-dev** or later
- **Git** for fetching dependencies

## Installation Methods

### Method 1: Using `zig fetch` (Recommended)

The easiest way to add Rune to your project is using Zig's built-in package manager:

```bash
zig fetch --save https://github.com/ghostkellz/rune/archive/refs/heads/main.tar.gz
```

This will automatically add Rune to your `build.zig.zon` file.

### Method 2: Manual `build.zig.zon` Configuration

Alternatively, you can manually add Rune to your `build.zig.zon`:

```zig
.{
    .name = "my-project",
    .version = "0.1.0",
    .dependencies = .{
        .rune = .{
            .url = "https://github.com/ghostkellz/rune/archive/refs/heads/main.tar.gz",
            .hash = "122089a8c2e0b65d0042d6e59c6e8c4f5c0d1a3b4e5f6789abcdef0123456789", // Replace with actual hash
        },
    },
}
```

Run `zig build` to fetch the dependency and get the correct hash if needed.

### Method 3: Git Submodule (Development)

For development or if you want to contribute to Rune:

```bash
git submodule add https://github.com/ghostkellz/rune.git deps/rune
```

Then reference it in your `build.zig.zon`:

```zig
.dependencies = .{
    .rune = .{ .path = "deps/rune" },
},
```

## Build Configuration

### Basic Setup

Add Rune to your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the rune dependency
    const rune_dep = b.dependency("rune", .{
        .target = target,
        .optimize = optimize,
    });

    // Your executable
    const exe = b.addExecutable(.{
        .name = "my-mcp-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rune", .module = rune_dep.module("rune") },
            },
        }),
    });

    b.installArtifact(exe);
}
```

### FFI Library Setup

If you need the FFI library for Rust integration:

```zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const rune_dep = b.dependency("rune", .{
        .target = target,
        .optimize = optimize,
    });

    // Create FFI library
    const ffi_lib = b.addStaticLibrary(.{
        .name = "rune_ffi",
        .root_module = b.createModule(.{
            .root_source_file = rune_dep.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    ffi_lib.linkLibC();
    b.installArtifact(ffi_lib);

    // Install header file
    const header_install = b.addInstallFile(rune_dep.path("include/rune.h"), "rune.h");
    b.getInstallStep().dependOn(&header_install.step);
}
```

## Verification

### Test Your Installation

Create a simple test file `src/main.zig`:

```zig
const std = @import("std");
const rune = @import("rune");

pub fn main() !void {
    std.debug.print("Rune library loaded successfully!\n", .{});

    // Test basic functionality
    const version = rune.protocol.Methods.INITIALIZE;
    std.debug.print("MCP Initialize method: {s}\n", .{version});
}
```

Build and run:

```bash
zig build run
```

You should see output confirming Rune is working.

### Run Tests

To run Rune's test suite:

```bash
zig build test
```

All tests should pass, confirming your setup is correct.

## Development Setup

### IDE Configuration

#### VS Code with Zig Extension

Add to your `.vscode/settings.json`:

```json
{
    "zig.buildOnSave": true,
    "zig.checkForUpdate": false,
    "files.associations": {
        "*.zig": "zig"
    }
}
```

#### ZLS (Zig Language Server)

Install ZLS for enhanced IDE support:

```bash
# Install ZLS
git clone https://github.com/zigtools/zls.git
cd zls
zig build -Doptimize=ReleaseSafe
```

Configure your editor to use ZLS for Zig files.

### Build Optimization

For production builds, use:

```bash
# Optimized for speed
zig build -Doptimize=ReleaseFast

# Optimized for size
zig build -Doptimize=ReleaseSmall

# Optimized for safety
zig build -Doptimize=ReleaseSafe
```

## Common Issues

### Hash Mismatch

If you get a hash mismatch error:

```bash
# Let Zig calculate the correct hash
zig build
# Copy the hash from the error message to your build.zig.zon
```

### Missing libc

For FFI functionality, you may need to link libc:

```zig
exe.linkLibC();
```

### Zig Version Compatibility

Rune requires Zig 0.16.0-dev or later. Check your version:

```bash
zig version
```

Update Zig if needed from [ziglang.org](https://ziglang.org/download/).

### Build Errors

Common build fixes:

1. **Clean build cache**: `rm -rf zig-cache zig-out`
2. **Update dependencies**: `zig build --fetch`
3. **Check module imports**: Ensure `rune` is correctly imported

## Next Steps

Once Rune is installed:

1. Read the [Quick Start Guide](quick-start.md)
2. Explore the [Architecture Overview](architecture.md)
3. Check out [Building MCP Servers](servers.md) or [Building MCP Clients](clients.md)
4. Review the [Examples](../examples/) for practical implementations

## Platform-Specific Notes

### Linux

No additional setup required. Rune works out of the box.

### macOS

Ensure you have Xcode command line tools:

```bash
xcode-select --install
```

### Windows

Use WSL2 or ensure you have the Windows SDK if building natively.

For cross-compilation support, Zig handles most platform differences automatically.