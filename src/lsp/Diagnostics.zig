//! Stage 2 of `~/.claude/plans/lexical-wishing-penguin.md`: the LSP's
//! first genuinely useful feature, needing no `gopls` proxying at all --
//! just the real in-process transpile CLAUDE.md already designed for
//! ("the LSP's planned reuse of prepare's transpilation logic... should
//! call the underlying Zig functions directly, in-process"), confirmed
//! zero-disk-I/O-required by the earlier position-mapping spike.
//!
//! Mirrors `src/cli/Prepare.zig`'s own real per-file pipeline
//! (`Expose.findComposers` then `Codegen.generateGo`, first error wins --
//! `Prepare.run` itself never accumulates more than one) rather than
//! reimplementing it: same two calls, same "first error stops the
//! pipeline" behavior, just returning the error instead of writing files.

const std = @import("std");
const Expose = @import("Expose");
const Codegen = @import("Codegen");

pub const Diagnostic = struct {
    /// 1-based, matching `Parser`/`Expose`/`Codegen`'s own convention --
    /// callers building an LSP `Position` (0-based) must subtract 1.
    line: u32,
    col: u32,
    message: []const u8,
};

/// Runs the real transpile pipeline against `src` and returns its first
/// real error, if any -- `null` means `src` transpiles cleanly. `message`
/// is allocated via `gpa` (owned by the caller); everything else the
/// pipeline allocates internally is arena-scoped and freed before this
/// returns, so a long-running server calling this on every keystroke
/// doesn't leak.
///
/// `package_name` is hardcoded to `"main"` rather than extracted from
/// `src` (`Prepare.zig`'s own `extractPackageName` is private to that
/// file) -- safe here because `generateGo` only ever uses it to emit the
/// output's own `package` line, never to affect whether an error is
/// produced, and diagnostics never look at `Output` at all.
pub fn compute(gpa: std.mem.Allocator, src: []const u8) !?Diagnostic {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try Expose.findComposers(arena, src);
    if (found.err) |e| return .{ .line = e.line, .col = e.col, .message = try gpa.dupe(u8, e.message) };

    const result = try Codegen.generateGo(
        arena,
        "main",
        src,
        found.composers,
        &.{},
        found.uses,
        found.uses_start,
        found.uses_end,
        .{},
        false, // recycle_enabled: no live project config in scope in the LSP -- diagnostics/hover/semantic-tokens don't need Part 2's codegen-automation output, just a clean transpile
    );
    if (result.err) |e| return .{ .line = e.line, .col = e.col, .message = try gpa.dupe(u8, e.message) };

    return null;
}

// Mirrors examples/ntx-form/guest/form.go.ntx's own real, already-proven
// shape exactly (no `parent={parent}` attribute -- `Container` doesn't
// take one -- and no explicit `return` inside the markup body, since this
// whole body is replaced by codegen's own forwarding call, never compiled
// as Go directly).
const clean_source =
    \\package main
    \\
    \\import "natyv/sdk/widgets"
    \\
    \\expose Form
    \\
    \\func Form(parent widgets.Container) error {
    \\    <Container>
    \\        <Button onClick={handleSave}>Save</Button>
    \\    </Container>
    \\}
    \\
    \\func handleSave() {}
    \\
;

const broken_source =
    \\package main
    \\
    \\import "natyv/sdk/widgets"
    \\
    \\expose Form
    \\
    \\func Form(parent widgets.Container) error {
    \\    <Container>
    \\        <Button onClick={handleSave}>Save</Button>
    \\}
    \\
    \\func handleSave() {}
    \\
;

test "compute: a clean real .ntx source produces no diagnostic" {
    const diag = try compute(std.testing.allocator, clean_source);
    try std.testing.expect(diag == null);
}

test "compute: an unclosed tag surfaces a real Expose/parse error with a real position" {
    const diag = (try compute(std.testing.allocator, broken_source)).?;
    defer std.testing.allocator.free(diag.message);
    try std.testing.expect(diag.line >= 1);
    try std.testing.expect(diag.col >= 1);
    try std.testing.expect(diag.message.len > 0);
}

const unterminated_raw_code_source =
    \\package main
    \\
    \\import "natyv/sdk/widgets"
    \\
    \\expose Form
    \\
    \\func Form(parent widgets.Container) error {
    \\    <Container>
    \\        <% x := 1
    \\    </Container>
    \\}
    \\
;

test "compute: an unterminated <%...%> raw-code block surfaces a real error at the '<%' itself, not the end of file" {
    // Editor-support audit (2026-09-02, `~/.claude/plans/lexical-wishing-penguin.md`
    // Phase B2): a raw-code-block error needs correct line/col attribution
    // or an editor's diagnostic squiggle points at the wrong place --
    // `Parser.parseRawCodeBlock`'s own `fail(start_line, start_col, ...)`
    // call (seeded from the '<' of the opening '<%') is what this proves.
    const diag = (try compute(std.testing.allocator, unterminated_raw_code_source)).?;
    defer std.testing.allocator.free(diag.message);
    // Line 9, col 9 (1-based) is the real "<%" in the source above --
    // proves this is a raw-code-specific error (Parser.parseRawCodeBlock's
    // own fail call), not Expose.findComposers' outer brace-matching
    // (confirmed by hand: a source with an unbalanced Go '{' inside the
    // raw-code block instead reports the *composer's own* opening brace as
    // unterminated, a real but different error path this test isn't
    // exercising).
    try std.testing.expectEqual(@as(u32, 9), diag.line);
    try std.testing.expectEqual(@as(u32, 9), diag.col);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "'<%'") != null);
}

test "compute: fixing the same source clears the diagnostic" {
    const broken_diag = try compute(std.testing.allocator, broken_source);
    try std.testing.expect(broken_diag != null);
    std.testing.allocator.free(broken_diag.?.message);

    const fixed_diag = try compute(std.testing.allocator, clean_source);
    try std.testing.expect(fixed_diag == null);
}
