# Rune Documentation

Welcome to the Rune documentation! Rune is a premier Zig library for the Model Context Protocol (MCP), providing type-safe, high-performance tools for building MCP servers and clients.

## Documentation Structure

### Getting Started
- [Installation Guide](guides/installation.md) - How to install and set up Rune
- [Quick Start](guides/quick-start.md) - Get up and running in minutes
- [Architecture Overview](guides/architecture.md) - Understanding Rune's design

### Guides
- [Building MCP Servers](guides/servers.md) - Complete server development guide
- [Building MCP Clients](guides/clients.md) - Client development and integration
- [Transport Layers](guides/transports.md) - stdio, WebSocket, and HTTP/SSE
- [Security & Permissions](guides/security.md) - Permission system and consent framework
- [Schema Validation](guides/schemas.md) - JSON Schema validation for tools
- [Rust Integration](guides/rust-ffi.md) - Using Rune from Rust applications

### API Reference
- [Core Types](api/core-types.md) - Protocol and JSON-RPC types
- [Server API](api/server.md) - Server class and tool registration
- [Client API](api/client.md) - Client class and operations
- [Transport API](api/transport.md) - Transport layer interfaces
- [Security API](api/security.md) - Security framework APIs
- [Schema API](api/schema.md) - Schema validation APIs
- [FFI API](api/ffi.md) - C/Rust FFI interface

### Examples
- [Simple Server](examples/simple-server.md) - Basic MCP server example
- [Advanced Server](examples/advanced-server.md) - Server with security and validation
- [Client Examples](examples/client-usage.md) - Various client usage patterns
- [Rust Integration](examples/rust-integration.md) - Using Rune from Rust
- [Multi-Transport](examples/multi-transport.md) - Supporting multiple transports

## Key Features

- ⚡ **Lightning Fast**: Idiomatic Zig with zero hidden allocations
- 🔌 **Dual Mode**: Full MCP client & lightweight server capabilities
- 🔒 **Security First**: Optional consent hooks and guard rails
- 🌐 **Protocol Agnostic**: JSON-RPC over stdio, WebSocket, and HTTP(S)
- 📜 **Schema Aware**: Built-in OpenAPI/JSON Schema interoperability
- 🦀 **Rust FFI Ready**: Seamless bindings for Rust projects
- 🎯 **Functional**: Leveraging Zig's compile-time capabilities
- 🔄 **Async Native**: Built from the ground up for async/await workflows

## Quick Navigation

**New to Rune?** Start with the [Installation Guide](guides/installation.md) and [Quick Start](guides/quick-start.md).

**Building a server?** Check out [Building MCP Servers](guides/servers.md) and the [Server API](api/server.md).

**Integrating from Rust?** See the [Rust Integration Guide](guides/rust-ffi.md) and [FFI API](api/ffi.md).

**Need examples?** Browse the [Examples](examples/) directory for practical implementations.

## Support

- **Issues**: Report bugs and feature requests on [GitHub Issues](https://github.com/ghostkellz/rune/issues)
- **Discussions**: Join the community on [GitHub Discussions](https://github.com/ghostkellz/rune/discussions)
- **MCP Specification**: Read the official [MCP Specification](https://spec.modelcontextprotocol.io/)

## Contributing

We welcome contributions! Please see our [Contributing Guide](../CONTRIBUTING.md) for details on how to get involved.

## License

Rune is licensed under the MIT License. See [LICENSE](../LICENSE) for details.