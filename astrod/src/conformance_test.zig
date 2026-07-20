//! AD-013 conformance gate: api/openapi.yaml is the authoritative contract
//! (authored in JSON syntax so std.json can parse it here), and router.zig's
//! route table is the implementation. `zig build test` fails on drift in
//! either direction, so spec edits and handler edits must land together.
//!
//! GET /api/v1/openapi.json needs no exemption today: the spec documents
//! itself, so it participates in the bidirectional check like any other
//! route. If it is ever dropped from the spec, exempt it here with a
//! comment explaining why.

const std = @import("std");
const router = @import("router.zig");
const system = @import("system.zig");

test "AD-013: every spec operation has a route and every route is documented" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, router.openapi_json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expect(std.mem.startsWith(u8, root.get("openapi").?.string, "3.1"));

    const paths = root.get("paths").?.object;

    // Direction 1: spec → routes. Every documented operation must have a
    // handler, or clients generated from the spec would 404.
    var spec_ops: usize = 0;
    var it = paths.iterator();
    while (it.next()) |entry| {
        const path = entry.key_ptr.*;
        var op_it = entry.value_ptr.object.iterator();
        while (op_it.next()) |op| {
            // Path-item keys like "summary" or "parameters" are not verbs.
            const method = methodFromSpecKey(op.key_ptr.*) orelse continue;
            spec_ops += 1;
            const routed = for (router.routes) |route| {
                if (route.method == method and std.mem.eql(u8, route.path, path)) break true;
            } else false;
            if (!routed) {
                std.debug.print("spec operation without handler: {s} {s}\n", .{ @tagName(method), path });
                return error.SpecOperationWithoutHandler;
            }
        }
    }

    // Direction 2: routes → spec. Every handler must be documented, or the
    // served openapi.json lies about the API surface.
    for (router.routes) |route| {
        var key_buf: [16]u8 = undefined;
        const key = std.ascii.lowerString(&key_buf, @tagName(route.method));
        const documented = if (paths.get(route.path)) |item| item.object.get(key) != null else false;
        if (!documented) {
            std.debug.print("route missing from spec: {s} {s}\n", .{ @tagName(route.method), route.path });
            return error.RouteMissingFromSpec;
        }
    }

    // Both directions passed element-wise; equal counts additionally rule
    // out duplicate entries on either side.
    try std.testing.expectEqual(router.routes.len, spec_ops);
}

fn methodFromSpecKey(key: []const u8) ?router.Method {
    var buf: [16]u8 = undefined;
    if (key.len > buf.len) return null;
    return router.Method.parse(std.ascii.upperString(&buf, key));
}

test "AD-013: SystemInfo schema mirrors system.SystemInfo field-for-field" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, router.openapi_json, .{});
    defer parsed.deinit();
    const schema = parsed.value.object.get("components").?.object
        .get("schemas").?.object
        .get("SystemInfo").?.object;
    const props = schema.get("properties").?.object;
    const required = schema.get("required").?.array;

    // Exact parity: same field count in properties and required as the
    // struct, and each struct field present with the JSON type std.json
    // serialization produces for it. Extra/missing/renamed fields on either
    // side change a count or a lookup and fail.
    const fields = std.meta.fields(system.SystemInfo);
    try std.testing.expectEqual(fields.len, props.count());
    try std.testing.expectEqual(fields.len, required.items.len);

    inline for (fields) |field| {
        const prop = props.get(field.name) orelse {
            std.debug.print("SystemInfo field missing from spec: {s}\n", .{field.name});
            return error.SchemaFieldMissing;
        };
        const type_val = prop.object.get("type").?;
        switch (@typeInfo(field.type)) {
            // Optional fields serialize as JSON null (the daemon keeps the
            // std.json default of emitting null optionals), so the spec must
            // declare the 3.1 nullable form ["<type>", "null"].
            .optional => |opt| {
                const alternatives = type_val.array.items;
                try std.testing.expectEqual(@as(usize, 2), alternatives.len);
                try std.testing.expectEqualStrings(jsonTypeFor(opt.child), alternatives[0].string);
                try std.testing.expectEqualStrings("null", alternatives[1].string);
            },
            else => try std.testing.expectEqualStrings(jsonTypeFor(field.type), type_val.string),
        }

        const listed = for (required.items) |r| {
            if (std.mem.eql(u8, r.string, field.name)) break true;
        } else false;
        if (!listed) {
            std.debug.print("SystemInfo field not marked required in spec: {s}\n", .{field.name});
            return error.SchemaFieldNotRequired;
        }
    }
}

// The daemon serializes SystemInfo with std.json, so the wire type is fully
// determined by the Zig field type.
fn jsonTypeFor(comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .int => "integer",
        .bool => "boolean",
        .pointer => "string", // every pointer field is []const u8 today
        else => @compileError("unmapped SystemInfo field type: " ++ @typeName(T)),
    };
}
