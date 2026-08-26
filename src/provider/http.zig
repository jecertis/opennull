//! Real HTTP transport backed by std.http.Client. `HttpTransport.send` and
//! the streaming `HttpStream` are thin, deliberately untestable seams (they
//! need a live network + a live std.Io from std.process.Init, neither of
//! which exist in `zig build test`) — see test/http_test.zig for what IS
//! unit-tested here, and exercised against local mock servers by smoke runs.
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
        return .{ .ptr = self, .sendFn = send, .openFn = streamOpen };
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

    fn streamOpen(ptr: *anyopaque, allocator: std.mem.Allocator, req: provider.HttpRequest) anyerror!provider.StreamConnection {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        const stream = try HttpStream.open(allocator, self.io, req);
        return stream.connection();
    }
};

/// Live SSE connection over std.http.Client: sends the request, then hands
/// the response body out line by line. Heap-anchored via `create` so the
/// reader pointers survive being passed around by value. Real-network seam
/// exercised by mock-server smoke runs.
pub const HttpStream = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    client: std.http.Client,
    request: std.http.Client.Request,
    redirect_buffer: []u8,
    transfer_buffer: []u8,
    owned_headers: []std.http.Header,
    /// Mutable copy of req.body: std.http's sendBodyComplete takes []u8,
    /// while HttpRequest.body is const.
    owned_body: []u8,
    body_reader: *std.Io.Reader,

    const redirect_buffer_len = 8192;
    const transfer_buffer_len = 16384;

    pub fn open(allocator: std.mem.Allocator, io: std.Io, req: provider.HttpRequest) !*HttpStream {
        const self = try allocator.create(HttpStream);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .client = .{ .allocator = allocator, .io = io },
            .request = undefined,
            .redirect_buffer = undefined,
            .transfer_buffer = undefined,
            .owned_headers = undefined,
            .owned_body = undefined,
            .body_reader = undefined,
        };

        self.redirect_buffer = try allocator.alloc(u8, redirect_buffer_len);
        errdefer allocator.free(self.redirect_buffer);
        self.transfer_buffer = try allocator.alloc(u8, transfer_buffer_len);
        errdefer allocator.free(self.transfer_buffer);
        // The RequestOptions contract requires headers to outlive the
        // Request — own them here.
        self.owned_headers = try toHttpHeaders(allocator, req.headers);
        errdefer allocator.free(self.owned_headers);
        self.owned_body = try allocator.dupe(u8, req.body);
        errdefer allocator.free(self.owned_body);

        const uri = try std.Uri.parse(req.url);
        self.request = try self.client.request(.POST, uri, .{ .extra_headers = self.owned_headers });
        errdefer self.request.deinit();

        try self.request.sendBodyComplete(self.owned_body);

        var response = try self.request.receiveHead(self.redirect_buffer);
        if (response.head.status != .ok) return error.ApiError;

        // Points into this struct's own request state — hence heap anchor.
        self.body_reader = response.reader(self.transfer_buffer);
        return self;
    }

    pub fn connection(self: *HttpStream) provider.StreamConnection {
        return .{ .ptr = self, .nextLineFn = nextLine, .deinitFn = deinitFn };
    }

    fn nextLine(ptr: *anyopaque) anyerror!?[]const u8 {
        const self: *HttpStream = @ptrCast(@alignCast(ptr));
        return self.body_reader.takeDelimiter('\n');
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *HttpStream = @ptrCast(@alignCast(ptr));
        const a = self.allocator;
        self.request.deinit();
        self.client.deinit();
        a.free(self.owned_headers);
        a.free(self.transfer_buffer);
        a.free(self.redirect_buffer);
        a.free(self.owned_body);
        a.destroy(self);
    }
};
