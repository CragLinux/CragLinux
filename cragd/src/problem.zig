//! RFC 7807 problem+json responses (AD-013: every error body is a Problem).

const std = @import("std");

pub const content_type = "application/problem+json";

pub const Problem = struct {
    /// Stable URN per error class, e.g. "urn:astro:problem:not-found".
    type: []const u8 = "about:blank",
    title: []const u8,
    status: u16,
    detail: ?[]const u8 = null,
};

/// Serialize a Problem to JSON. Caller owns the returned slice.
/// `detail` is omitted (not null) when absent, per RFC 7807 practice.
pub fn render(allocator: std.mem.Allocator, p: Problem) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, p, .{ .emit_null_optional_fields = false });
}

test "problem serialization round-trips and omits absent detail" {
    const allocator = std.testing.allocator;

    const body = try render(allocator, .{
        .type = "urn:astro:problem:not-found",
        .title = "Not Found",
        .status = 404,
    });
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("urn:astro:problem:not-found", obj.get("type").?.string);
    try std.testing.expectEqualStrings("Not Found", obj.get("title").?.string);
    try std.testing.expectEqual(@as(i64, 404), obj.get("status").?.integer);
    try std.testing.expect(obj.get("detail") == null);
}

test "problem serialization includes detail when set" {
    const allocator = std.testing.allocator;
    const body = try render(allocator, .{
        .title = "Method Not Allowed",
        .status = 405,
        .detail = "POST is not supported here",
    });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "POST is not supported here") != null);
}
