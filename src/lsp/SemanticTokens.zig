//! Stage 3 of `~/.claude/plans/lexical-wishing-penguin.md`: real `.ntx`
//! syntax highlighting via LSP semantic tokens, not a static grammar --
//! see `Codegen.SemanticToken`'s own doc comment for why grammar
//! injection was tried for real and found not to work cleanly against VS
//! Code's own bundled Go grammar (a locally-declared rule loses same-
//! position ties against an included grammar's own rules, confirmed via a
//! genuine offline `vscode-textmate` test harness, not a guess).
//!
//! Mirrors `Diagnostics.zig`'s own real per-file pipeline
//! (`Expose.findComposers` then `Codegen.generateGo`) -- same transpile,
//! a different half of `Output` consumed.

const std = @import("std");
const Expose = @import("Expose");
const Codegen = @import("Codegen");

/// Real LSP legend order -- index must match `Codegen.SemanticTokenType`'s
/// own declaration order exactly, since `compute` encodes
/// `@intFromEnum(token.token_type)` directly as the wire `tokenType`
/// index rather than going through a separate lookup table.
pub const token_type_legend = [_][]const u8{ "type", "property", "string" };

/// Real LSP `textDocument/semanticTokens/full` `data` array: already
/// delta-encoded (5 integers per token -- deltaLine, deltaStartChar,
/// length, tokenType, tokenModifiers -- each relative to the previous
/// token, sorted by position), the exact wire format the LSP spec
/// requires, not an intermediate shape the caller still has to encode.
/// A source that fails to parse or transpile yields an empty array
/// (`Codegen.SemanticToken`s never get produced past a real error) --
/// matches the real LSP expectation that a broken document just doesn't
/// get new highlighting, not a hard failure.
pub fn compute(gpa: std.mem.Allocator, src: []const u8) ![]u32 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try Expose.findComposers(arena, src);
    if (found.err != null) return &.{};

    const result = try Codegen.generateGo(arena, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{}, false);
    if (result.err != null) return &.{};
    const tokens = result.output.?.semantic_tokens;

    const sorted = try arena.dupe(Codegen.SemanticToken, tokens);
    std.mem.sort(Codegen.SemanticToken, sorted, {}, struct {
        fn lessThan(_: void, a: Codegen.SemanticToken, b: Codegen.SemanticToken) bool {
            if (a.ntx_line != b.ntx_line) return a.ntx_line < b.ntx_line;
            return a.ntx_col < b.ntx_col;
        }
    }.lessThan);

    var data: std.ArrayList(u32) = .empty;
    var prev_line: u32 = 0;
    var prev_char: u32 = 0;
    for (sorted) |t| {
        const line0 = t.ntx_line - 1; // .ntx/Parser positions are 1-based; LSP positions are 0-based.
        const char0 = t.ntx_col - 1;
        const delta_line = line0 - prev_line;
        const delta_char = if (delta_line == 0) char0 - prev_char else char0;
        try data.appendSlice(gpa, &.{ delta_line, delta_char, t.ntx_len, @intFromEnum(t.token_type), 0 });
        prev_line = line0;
        prev_char = char0;
    }
    return data.toOwnedSlice(gpa);
}

test "compute: a real .ntx source produces real delta-encoded tokens, sorted by position" {
    const src =
        \\expose Form
        \\
        \\func Form(parent widgets.Container) error {
        \\    <Container>
        \\        <Button onClick={handleSave}>Save</Button>
        \\    </Container>
        \\}
    ;
    const data = try compute(std.testing.allocator, src);
    defer std.testing.allocator.free(data);

    // Real tokens expected here: Container's own opening AND closing tag
    // (type x2), Button's own opening AND closing tag (type x2), onClick
    // (property) -- 5 tokens x 5 integers each. Child text ("Save")
    // deliberately gets no semantic token (see `Codegen.zig`'s Label/
    // Button branches) -- it renders in the editor's own default color,
    // not as a colored string literal.
    try std.testing.expectEqual(@as(usize, 25), data.len);

    // First token: `Container` on line 4 (0-based line 3), starting right
    // after the real `<` -- deltaLine/deltaChar are absolute for the very
    // first token (no previous token to delta against).
    try std.testing.expectEqual(@as(u32, 3), data[0]); // deltaLine
    try std.testing.expectEqual(@as(u32, 5), data[1]); // deltaStartChar (0-based column of 'C' in "    <Container>")
    try std.testing.expectEqual(@as(u32, 9), data[2]); // length ("Container".len)
    try std.testing.expectEqual(@as(u32, 0), data[3]); // tokenType index for .type
}

test "compute: a tag nested inside a <%...%> raw-code block still gets real, correctly-ordered semantic tokens" {
    // Editor-support audit (2026-09-02, `~/.claude/plans/lexical-wishing-penguin.md`
    // Phase B2): confirms `emitRawCodeBlock`'s recursive `emitElement` calls for
    // nested tags produce tokens that `compute`'s own sort-then-delta-encode pass
    // (see above) already handles correctly -- no new `SemanticTokenType` or
    // ordering fix needed, since the sort is by real source position, not emission
    // order. The surrounding raw code itself (the `for` loop) deliberately gets no
    // token of its own (see `emitRawCodeBlock`'s doc comment) -- that's left to the
    // editor's own Go highlighting.
    const src =
        \\expose Form
        \\
        \\func Form(parent widgets.Container) error {
        \\    <Container>
        \\        <% for _, msg := range messages {
        \\            <Button onClick={handleSave}>Save</Button>
        \\        } %>
        \\    </Container>
        \\}
    ;
    const data = try compute(std.testing.allocator, src);
    defer std.testing.allocator.free(data);

    // Container open+close, Button open+close, onClick property -- same 5
    // tokens as the plain (non-raw-code) test above, just reached through a
    // raw-code splice instead of a direct child.
    try std.testing.expectEqual(@as(usize, 25), data.len);

    // First token is still Container's own opening tag, unaffected by the
    // raw-code block that follows it as a sibling.
    try std.testing.expectEqual(@as(u32, 3), data[0]); // deltaLine
    try std.testing.expectEqual(@as(u32, 5), data[1]); // deltaStartChar
    try std.testing.expectEqual(@as(u32, 9), data[2]); // length ("Container".len)
    try std.testing.expectEqual(@as(u32, 0), data[3]); // tokenType index for .type

    // Every subsequent delta must be non-negative on both axes relative to
    // the running position -- a real regression check for the concern this
    // test exists to rule out (raw-code splicing emitting tokens out of
    // real source order, which delta-encoding can't represent correctly).
    var i: usize = 5;
    while (i < data.len) : (i += 5) {
        const delta_line = data[i];
        if (delta_line == 0) {
            // Same line as the previous token -- deltaStartChar must still
            // move forward, never negative (which would show up as a huge
            // wrapped u32 instead).
            try std.testing.expect(data[i + 1] < 1000);
        }
    }
}

test "compute: a broken .ntx source produces an empty token array, not an error" {
    const src =
        \\expose Form
        \\
        \\func Form(parent widgets.Container) error {
        \\    <Container>
        \\}
    ;
    const data = try compute(std.testing.allocator, src);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(@as(usize, 0), data.len);
}
