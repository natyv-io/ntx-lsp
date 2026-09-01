//! Hand-rolled LSP wire framing: `Content-Length: N\r\n\r\n<json bytes>`,
//! read/written directly against `std.Io.Reader`/`std.Io.Writer` -- no
//! third-party JSON-RPC/LSP package exists in `build.zig.zon` (only `sdl`
//! is vendored today), and `std.json` itself has no framing helper, so this
//! is genuinely new plumbing, not a wrapper over an existing mechanism (see
//! `~/.claude/plans/lexical-wishing-penguin.md`'s Stage 1). Deliberately
//! decoupled from any real file/process: both functions operate on the
//! generic `std.Io.Reader`/`Writer` interfaces, so `ntx-lsp`'s real stdio
//! loop (`Server.zig`) and this file's own tests (against
//! `std.Io.Reader.fixed`/`std.Io.Writer.Allocating`) exercise the exact
//! same code, no I/O mocking needed.

const std = @import("std");

pub const ReadError = error{
    ReadFailed,
    EndOfStream,
    /// A header line exceeded the reader's own internal buffer capacity
    /// before a newline was found -- real LSP headers are always short, so
    /// this only fires against a malformed/adversarial stream.
    HeaderTooLong,
    /// A header line wasn't a well-formed `Name: value` pair.
    InvalidHeader,
    /// The blank line ending the header block arrived without a
    /// `Content-Length` header ever having been seen.
    MissingContentLength,
    OutOfMemory,
};

/// Reads one full LSP message (headers + body) from `reader`, returning the
/// body's raw JSON bytes, allocated via `allocator` (owned by the caller).
/// Any header other than `Content-Length` (e.g. `Content-Type`, which real
/// clients sometimes send) is read and silently ignored, matching the LSP
/// spec's own "headers other than Content-Length may be present" allowance.
pub fn readMessage(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError![]u8 {
    var content_length: ?usize = null;
    while (true) {
        // `takeDelimiter` (not `takeDelimiterExclusive`) -- the latter
        // advances only *up to* the delimiter, leaving it unconsumed for
        // the next call to immediately re-find at position 0, which never
        // makes progress. `takeDelimiter` advances *past* it, matching
        // `Init.zig`'s own `readLine` precedent for the same reason.
        const line = (reader.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => return error.HeaderTooLong,
            error.ReadFailed => return error.ReadFailed,
        }) orelse return error.EndOfStream;
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) break; // blank line: end of headers
        const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, trimmed[0..colon], " \t");
        if (std.ascii.eqlIgnoreCase(name, "Content-Length")) {
            const raw_value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            content_length = std.fmt.parseInt(usize, raw_value, 10) catch return error.InvalidHeader;
        }
    }
    const len = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    reader.readSliceAll(body) catch |err| switch (err) {
        error.EndOfStream => return error.EndOfStream,
        error.ReadFailed => return error.ReadFailed,
    };
    return body;
}

/// Writes one full LSP message (headers + body) to `writer` and flushes it
/// -- a real LSP client/server reads messages as they arrive, so a message
/// left sitting in an unflushed buffer is indistinguishable from one never
/// sent at all.
pub fn writeMessage(writer: *std.Io.Writer, body: []const u8) std.Io.Writer.Error!void {
    try writer.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try writer.writeAll(body);
    try writer.flush();
}

test "readMessage: a well-formed message round-trips its exact body" {
    var r = std.Io.Reader.fixed("Content-Length: 12\r\n\r\n{\"a\":\"body\"}extra-bytes-not-part-of-this-message");
    const body = try readMessage(&r, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"a\":\"body\"}", body);
}

test "readMessage: an unrelated header before Content-Length is ignored, not fatal" {
    var r = std.Io.Reader.fixed("Content-Type: application/vscode-jsonrpc; charset=utf-8\r\nContent-Length: 2\r\n\r\n{}");
    const body = try readMessage(&r, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{}", body);
}

test "readMessage: missing Content-Length is a distinct real error" {
    var r = std.Io.Reader.fixed("Content-Type: application/json\r\n\r\n{}");
    try std.testing.expectError(error.MissingContentLength, readMessage(&r, std.testing.allocator));
}

test "readMessage: a header with no colon is a distinct real error" {
    var r = std.Io.Reader.fixed("not-a-real-header\r\n\r\n");
    try std.testing.expectError(error.InvalidHeader, readMessage(&r, std.testing.allocator));
}

test "readMessage: a body shorter than Content-Length claims is EndOfStream" {
    var r = std.Io.Reader.fixed("Content-Length: 100\r\n\r\n{}");
    try std.testing.expectError(error.EndOfStream, readMessage(&r, std.testing.allocator));
}

test "readMessage: two messages back to back each read exactly their own body" {
    var r = std.Io.Reader.fixed("Content-Length: 2\r\n\r\n{}" ++ "Content-Length: 7\r\n\r\n{\"a\":1}");
    const first = try readMessage(&r, std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("{}", first);
    const second = try readMessage(&r, std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings("{\"a\":1}", second);
}

test "writeMessage: emits a real Content-Length header matching the body's own byte length" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeMessage(&aw.writer, "{\"hello\":\"world\"}");
    try std.testing.expectEqualStrings("Content-Length: 17\r\n\r\n{\"hello\":\"world\"}", aw.writer.buffered());
}

test "writeMessage output round-trips through readMessage" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeMessage(&aw.writer, "{\"round\":\"trip\"}");

    var r = std.Io.Reader.fixed(aw.writer.buffered());
    const body = try readMessage(&r, std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"round\":\"trip\"}", body);
}
