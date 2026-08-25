//! Real HTTP transport backed by std.http.Client. `HttpTransport.send` is a
//! thin, deliberately untestable seam (it needs a live network + a live
//! std.Io from std.process.Init, neither of which exist in `zig build
//! test`) — see test/http_test.zig for what IS unit-tested here, and the
//! plan's Verification section for the manual smoke test that exercises
//! this against a real API.
const std = @import("std");
const provider = @import("provider.zig");

/// Converts opennull's provider-neutral headers to std.http.Header,
/// preserving order. Caller frees the returned slice.
pub fn toHttpHeaders(allocator: std.mem.Allocator, headers: []const provider.HttpHeader) ![]std.http.Header {
    const out = try allocator.alloc(std.http.Header, headers.len);
    for (headers, 0..) |h, i| out[i] = .{ .name = h.name, .value = h.value };
    return out;
}

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn transport(self: *HttpTransport) provider.Transport {
        return .{ .ptr = self, .sendFn = send };
    }

    fn send(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.HttpResponse {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));

        var client = std.http.Client{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        const http_headers = try toHttpHeaders(allocator, req.headers);
        defer allocator.free(http_headers);

        var response_buf: std.Io.Writer.Allocating = .init(allocator);
        defer response_buf.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = req.url },
            .method = .POST,
            .payload = req.body,
            .extra_headers = http_headers,
            .response_writer = &response_buf.writer,
        });

        const body = try allocator.dupe(u8, response_buf.written());
        return .{ .status = @intFromEnum(result.status), .body = body };
    }
};
