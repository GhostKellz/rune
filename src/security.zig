//! Security and consent framework for MCP tools
const std = @import("std");

pub const SecurityError = error{
    PermissionDenied,
    ConsentRequired,
    InvalidPolicy,
    SecurityViolation,
};

/// Permission types for MCP operations
pub const Permission = enum {
    fs_read,
    fs_write,
    fs_execute,
    network_http,
    network_ws,
    process_spawn,
    env_read,
    env_write,
    system_info,

    pub fn fromString(str: []const u8) ?Permission {
        if (std.mem.eql(u8, str, "fs.read")) return .fs_read;
        if (std.mem.eql(u8, str, "fs.write")) return .fs_write;
        if (std.mem.eql(u8, str, "fs.execute")) return .fs_execute;
        if (std.mem.eql(u8, str, "network.http")) return .network_http;
        if (std.mem.eql(u8, str, "network.ws")) return .network_ws;
        if (std.mem.eql(u8, str, "process.spawn")) return .process_spawn;
        if (std.mem.eql(u8, str, "env.read")) return .env_read;
        if (std.mem.eql(u8, str, "env.write")) return .env_write;
        if (std.mem.eql(u8, str, "system.info")) return .system_info;
        return null;
    }

    pub fn toString(self: Permission) []const u8 {
        return switch (self) {
            .fs_read => "fs.read",
            .fs_write => "fs.write",
            .fs_execute => "fs.execute",
            .network_http => "network.http",
            .network_ws => "network.ws",
            .process_spawn => "process.spawn",
            .env_read => "env.read",
            .env_write => "env.write",
            .system_info => "system.info",
        };
    }
};

/// Policy decision for a permission request
pub const PolicyDecision = enum {
    allow,
    deny,
    ask_user,
};

/// Security policy for permissions
pub const SecurityPolicy = struct {
    allowed_permissions: std.EnumSet(Permission),
    denied_permissions: std.EnumSet(Permission),
    default_decision: PolicyDecision,

    pub fn init() SecurityPolicy {
        return SecurityPolicy{
            .allowed_permissions = std.EnumSet(Permission).initEmpty(),
            .denied_permissions = std.EnumSet(Permission).initEmpty(),
            .default_decision = .ask_user,
        };
    }

    pub fn allow(self: *SecurityPolicy, permission: Permission) void {
        self.allowed_permissions.insert(permission);
        self.denied_permissions.remove(permission);
    }

    pub fn deny(self: *SecurityPolicy, permission: Permission) void {
        self.denied_permissions.insert(permission);
        self.allowed_permissions.remove(permission);
    }

    pub fn check(self: SecurityPolicy, permission: Permission) PolicyDecision {
        if (self.allowed_permissions.contains(permission)) {
            return .allow;
        }
        if (self.denied_permissions.contains(permission)) {
            return .deny;
        }
        return self.default_decision;
    }
};

/// Context for a permission request
pub const PermissionContext = struct {
    permission: Permission,
    resource: ?[]const u8 = null,
    justification: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
};

/// User consent callback function
pub const ConsentCallback = *const fn (context: PermissionContext) PolicyDecision;

/// Security guard that enforces permissions and consent
pub const SecurityGuard = struct {
    allocator: std.mem.Allocator,
    policy: SecurityPolicy,
    consent_callback: ?ConsentCallback,
    audit_log: std.ArrayList(AuditEntry),

    const AuditEntry = struct {
        timestamp: i64,
        permission: Permission,
        resource: ?[]const u8,
        tool_name: ?[]const u8,
        decision: PolicyDecision,
        granted: bool,
    };

    pub fn init(allocator: std.mem.Allocator) SecurityGuard {
        return SecurityGuard{
            .allocator = allocator,
            .policy = SecurityPolicy.init(),
            .consent_callback = null,
            .audit_log = std.ArrayList(AuditEntry){},
        };
    }

    pub fn deinit(self: *SecurityGuard) void {
        // Free audit log entries
        for (self.audit_log.items) |entry| {
            if (entry.resource) |resource| {
                self.allocator.free(resource);
            }
            if (entry.tool_name) |name| {
                self.allocator.free(name);
            }
        }
        self.audit_log.deinit(self.allocator);
    }

    /// Set the consent callback for user interaction
    pub fn setConsentCallback(self: *SecurityGuard, callback: ConsentCallback) void {
        self.consent_callback = callback;
    }

    /// Configure the security policy
    pub fn setPolicy(self: *SecurityGuard, policy: SecurityPolicy) void {
        self.policy = policy;
    }

    /// Request permission for an operation
    pub fn require(self: *SecurityGuard, permission: Permission, context: PermissionContext) !void {
        const decision = self.policy.check(permission);
        var final_decision = decision;

        // If policy says ask user and we have a callback, ask
        if (decision == .ask_user and self.consent_callback != null) {
            final_decision = self.consent_callback.?(context);
        }

        // Log the decision
        try self.auditLog(permission, context, final_decision, final_decision == .allow);

        // Enforce the decision
        switch (final_decision) {
            .allow => {}, // Permission granted
            .deny => return SecurityError.PermissionDenied,
            .ask_user => return SecurityError.ConsentRequired, // No callback available
        }
    }

    /// Convenient string-based permission request
    pub fn requireString(self: *SecurityGuard, permission_str: []const u8, context: PermissionContext) !void {
        const permission = Permission.fromString(permission_str) orelse return SecurityError.InvalidPolicy;
        try self.require(permission, context);
    }

    /// Add an entry to the audit log
    fn auditLog(self: *SecurityGuard, permission: Permission, context: PermissionContext, decision: PolicyDecision, granted: bool) !void {
        const entry = AuditEntry{
            .timestamp = std.time.timestamp(),
            .permission = permission,
            .resource = if (context.resource) |r| try self.allocator.dupe(u8, r) else null,
            .tool_name = if (context.tool_name) |n| try self.allocator.dupe(u8, n) else null,
            .decision = decision,
            .granted = granted,
        };

        try self.audit_log.append(self.allocator, entry);
    }

    /// Get audit log for security review
    pub fn getAuditLog(self: SecurityGuard) []const AuditEntry {
        return self.audit_log.items;
    }

    /// Clear the audit log
    pub fn clearAuditLog(self: *SecurityGuard) void {
        for (self.audit_log.items) |entry| {
            if (entry.resource) |resource| {
                self.allocator.free(resource);
            }
            if (entry.tool_name) |name| {
                self.allocator.free(name);
            }
        }
        self.audit_log.clearRetainingCapacity();
    }
};

/// Common security contexts for typical MCP operations
pub const SecurityContext = struct {
    pub fn fileRead(path: []const u8, tool_name: ?[]const u8) PermissionContext {
        return PermissionContext{
            .permission = .fs_read,
            .resource = path,
            .justification = "Tool needs to read file",
            .tool_name = tool_name,
        };
    }

    pub fn fileWrite(path: []const u8, tool_name: ?[]const u8) PermissionContext {
        return PermissionContext{
            .permission = .fs_write,
            .resource = path,
            .justification = "Tool needs to write file",
            .tool_name = tool_name,
        };
    }

    pub fn httpRequest(url: []const u8, tool_name: ?[]const u8) PermissionContext {
        return PermissionContext{
            .permission = .network_http,
            .resource = url,
            .justification = "Tool needs to make HTTP request",
            .tool_name = tool_name,
        };
    }

    pub fn processSpawn(command: []const u8, tool_name: ?[]const u8) PermissionContext {
        return PermissionContext{
            .permission = .process_spawn,
            .resource = command,
            .justification = "Tool needs to execute command",
            .tool_name = tool_name,
        };
    }
};

/// Preset security policies for common scenarios
pub const PresetPolicies = struct {
    /// Very permissive policy (allow everything)
    pub fn permissive() SecurityPolicy {
        var policy = SecurityPolicy.init();
        policy.default_decision = .allow;
        return policy;
    }

    /// Very restrictive policy (deny everything)
    pub fn restrictive() SecurityPolicy {
        var policy = SecurityPolicy.init();
        policy.default_decision = .deny;
        return policy;
    }

    /// Safe defaults (allow safe operations, ask for dangerous ones)
    pub fn safeDefaults() SecurityPolicy {
        var policy = SecurityPolicy.init();
        policy.default_decision = .ask_user;

        // Auto-allow safe operations
        policy.allow(.fs_read);
        policy.allow(.env_read);
        policy.allow(.system_info);

        // Auto-deny dangerous operations by default
        policy.deny(.fs_execute);
        policy.deny(.process_spawn);

        return policy;
    }

    /// Read-only policy (allow only read operations)
    pub fn readOnly() SecurityPolicy {
        var policy = SecurityPolicy.init();
        policy.default_decision = .deny;

        policy.allow(.fs_read);
        policy.allow(.env_read);
        policy.allow(.system_info);
        policy.allow(.network_http); // Read-only HTTP requests

        return policy;
    }
};

test "security policy basic operations" {
    const testing = std.testing;

    var policy = SecurityPolicy.init();

    // Test default behavior
    try testing.expectEqual(PolicyDecision.ask_user, policy.check(.fs_read));

    // Test explicit allow
    policy.allow(.fs_read);
    try testing.expectEqual(PolicyDecision.allow, policy.check(.fs_read));

    // Test explicit deny
    policy.deny(.fs_write);
    try testing.expectEqual(PolicyDecision.deny, policy.check(.fs_write));
}

test "security guard permission enforcement" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var guard = SecurityGuard.init(allocator);
    defer guard.deinit();

    // Set a permissive policy for testing
    guard.setPolicy(PresetPolicies.permissive());

    // Test allowed operation
    const read_context = SecurityContext.fileRead("/tmp/test.txt", "test_tool");
    try guard.require(.fs_read, read_context);

    // Test denied operation with restrictive policy
    guard.setPolicy(PresetPolicies.restrictive());
    try testing.expectError(SecurityError.PermissionDenied, guard.require(.fs_write, read_context));

    // Check audit log
    const log = guard.getAuditLog();
    try testing.expect(log.len == 2);
    try testing.expect(log[0].granted == true);
    try testing.expect(log[1].granted == false);
}

test "permission string conversion" {
    const testing = std.testing;

    try testing.expectEqual(Permission.fs_read, Permission.fromString("fs.read").?);
    try testing.expectEqual(@as(?Permission, null), Permission.fromString("invalid"));

    try testing.expectEqualStrings("fs.write", Permission.fs_write.toString());
}
