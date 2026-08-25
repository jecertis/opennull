//! BDD spec for src/provider/http.zig. The real Transport wraps
//! std.http.Client, which needs a live std.Io from std.process.Init — that
//! seam cannot run inside `zig build test` and is exercised by the manual
//! network smoke test in the plan's Verification section instead. What CAN
//! be unit-tested here — the pure conversion from opennull's provider-
//! neutral header list to std.http.Header — is tested below so that piece
//! still gets a real failing-test-first cycle rather than being waved
//! through untested.
const std = @import("std");
const opennull = @import("opennull");
const http_transport = opennull.provider.http;
const provider = opennull.provider.core;
const HttpTransport = http_transport.HttpTransport;

// Scenario: Given an empty header list, when converted, then the result is
// an empty (but valid, allocator-owned) slice.
test "converts an empty header list" {
    const out = try http_transport.toHttpHeaders(std.testing.allocator, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// Scenario: Given opennull HttpHeader entries, when converted, then each
// becomes a std.http.Header with the same name/value, in the same order.
test "converts provider headers to std.http.Header preserving order" {
    const in = [_]provider.HttpHeader{
        .{ .name = "x-api-key", .value = "test-key" },
        .{ .name = "anthropic-version", .value = "2023-06-01" },
    };
    const out = try http_transport.toHttpHeaders(std.testing.allocator, &in);
    defer std.testing.allocator.free(out);

    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqualStrings("x-api-key", out[0].name);
    try std.testing.expectEqualStrings("test-key", out[0].value);
    try std.testing.expectEqualStrings("anthropic-version", out[1].name);
    try std.testing.expectEqualStrings("2023-06-01", out[1].value);
}

// Scenario: Given an HttpTransport, when its `.transport()` interface is
// taken, then it conforms to provider.Transport's shape. Zig only compiles
// a function body when its address is actually taken, so this is the
// scenario that forces send()'s body to type-check against the real
// std.http.Client API without performing any real I/O (send() is never
// invoked here — `io` is a placeholder that's never dereferenced).
test "HttpTransport.transport() conforms to the Transport interface" {
    var t = HttpTransport{ .allocator = std.testing.allocator, .io = undefined };
    const iface: provider.Transport = t.transport();
    _ = iface;
}
