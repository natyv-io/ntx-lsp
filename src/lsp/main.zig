//! Entry point for `ntx-lsp`, the `.ntx` language server (Stage 1 of
//! `~/.claude/plans/lexical-wishing-penguin.md`). A standalone binary, not
//! a `natyv` subcommand -- confirmed with Quinn 2026-08-26: this decouples
//! the server's real stdio/JSON-RPC process lifecycle (an editor spawns
//! and owns this process for as long as the file stays open) from the
//! `natyv` CLI's own argv/exit-code conventions, and lets `ntx-lsp` ship on
//! its own cadence rather than always moving in lockstep with the CLI.
//!
//! Every real LSP client (VS Code, Zed) speaks JSON-RPC over this
//! process's own stdin/stdout, never a socket -- so `main` just wires the
//! real process stdio streams into `Server.run`'s generic
//! `std.Io.Reader`/`Writer` loop.

const std = @import("std");
const ServerModule = @import("Server.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var stdin_file = std.Io.File.stdin();
    var stdout_file = std.Io.File.stdout();

    // Only needs to hold one header line at a time (`Content-Length: N`) --
    // message *bodies* of any size are read straight into their own
    // allocation by `Transport.readMessage`, not through this buffer.
    var read_buf: [4096]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stdin_file.reader(io, &read_buf);
    var writer = stdout_file.writer(io, &write_buf);

    // Real per-connection state as of Stage 3 (open documents' own text,
    // needed to answer a `textDocument/semanticTokens/full` request,
    // which per the real LSP spec carries only a URI). Explicitly
    // deinited even though the process exits right after -- confirmed via
    // a real end-to-end smoke test against the compiled binary that
    // skipping this trips the debug allocator's real leak detector on
    // every open document, not just a theoretical concern.
    var server: ServerModule.Server = .{};
    defer server.deinit(gpa, io);
    try server.run(gpa, io, &reader.interface, &writer.interface);
}
