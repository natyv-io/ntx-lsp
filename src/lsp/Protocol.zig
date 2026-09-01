//! Real LSP JSON-RPC shapes, Stage 1 scope only (lifecycle messages --
//! `initialize`/`initialized`/`shutdown`/`exit` -- plus the generic
//! error-response shape every later stage's request handling will reuse).
//! `id`/`params`/`result` are inherently polymorphic per the JSON-RPC spec
//! (an id is a string, number, or absent; params/result shapes vary by
//! method) -- kept as `std.json.Value` here rather than forced into a
//! narrower Zig type, matching `std.json.Value`'s own real support for
//! being embedded directly inside a typed struct's field (its
//! `jsonStringify`/parse-time handling round-trips whatever JSON shape was
//! actually there). Concrete shapes this server itself controls
//! end-to-end (e.g. `InitializeResult`) are real Zig structs instead.

const std = @import("std");

pub const version = "2.0";

pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
};

pub const ResponseError = struct {
    code: i32,
    message: []const u8,
};

/// Real legend for `textDocumentSync = 1`'s sibling capability below --
/// order must match `Codegen.SemanticTokenType`'s own declaration order
/// exactly (`SemanticTokens.compute` encodes `@intFromEnum` directly as
/// the wire index, no separate lookup table), hardcoded here rather than
/// imported from `SemanticTokens.zig` to keep this file dependency-free
/// (only `std`) the way it's been since Stage 1.
pub const SemanticTokensLegend = struct {
    tokenTypes: []const []const u8 = &.{ "type", "property", "string" },
    tokenModifiers: []const []const u8 = &.{},
};

pub const SemanticTokensOptions = struct {
    legend: SemanticTokensLegend = .{},
    full: bool = true,
};

/// `textDocumentSync = 1` (Full) as of Stage 2 -- real diagnostics need
/// the client to send the document's current full text on every change,
/// which `TextDocumentSyncKind.Full` (value `1`) is what asks for.
/// `semanticTokensProvider` as of Stage 3, `hoverProvider` as of Stage 5,
/// `definitionProvider`/`completionProvider` as of Stage 6. Anything else
/// gets added here only once its own handler actually lands -- advertising
/// a capability before the handler exists would be a real client-visible
/// lie, not just premature.
pub const ServerCapabilities = struct {
    textDocumentSync: u32 = 1,
    semanticTokensProvider: SemanticTokensOptions = .{},
    hoverProvider: bool = true,
    definitionProvider: bool = true,
    completionProvider: CompletionOptions = .{},
};

pub const CompletionOptions = struct {
    /// `.`/`&` cover the two real Stage 6 completion targets: a plain Go
    /// selector expression inside `onClick={...}` (`.`), and a `ref={&...}`
    /// target identifier (`&`). Real gopls-driven completion still works
    /// without a trigger character at all (a client can always ask
    /// on-demand, e.g. Ctrl+Space) -- this list only adds *automatic*
    /// popup-on-keystroke behavior for these two real cases.
    triggerCharacters: []const []const u8 = &.{ ".", "&" },
};

pub const InitializeResult = struct {
    capabilities: ServerCapabilities = .{},
};

pub const Position = struct {
    line: u32,
    character: u32,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

/// Zero-width (`start == end`) for every diagnostic today -- `Expose`'s
/// and `Codegen`'s own error types only ever carry a single point
/// position, not a span, so a zero-width range is the honest
/// representation, not an approximation of a real range this server
/// doesn't actually have.
pub const Diagnostic = struct {
    range: Range,
    message: []const u8,
};

pub const PublishDiagnosticsParams = struct {
    uri: []const u8,
    diagnostics: []const Diagnostic,
};

/// Stage 5 (`.ntx` LSP, gopls proxying): the real `textDocument/hover`
/// response shape sent back to the *editor* -- distinct from
/// `GoplsClient.HoverResult`, which carries `gopls`'s own raw
/// generated-document-relative response before `Server.zig` maps its
/// `range` back to a real `.ntx` position.
pub const MarkupContent = struct {
    kind: []const u8 = "markdown",
    value: []const u8,
};

pub const Hover = struct {
    contents: MarkupContent,
    range: ?Range = null,
};

/// Stage 6 (`.ntx` LSP, gopls proxying): the real `textDocument/definition`
/// response shape sent to the editor -- always encoded as an array (a
/// single-element one for a single result), a real, allowed LSP shape,
/// rather than switching between a bare `Location` and `Location[]`
/// depending on result count.
pub const Location = struct {
    uri: []const u8,
    range: Range,
};

/// Stage 6: the real `textDocument/completion` response shape. `kind` is
/// the real LSP `CompletionItemKind` numeric enum (e.g. `3` = Function,
/// `6` = Variable) -- forwarded verbatim from `gopls`'s own response
/// rather than re-declared here, since this server never needs to
/// interpret it, only pass it through so the editor can pick the right
/// icon.
pub const CompletionItem = struct {
    label: []const u8,
    kind: ?i64 = null,
    detail: ?[]const u8 = null,
    insertText: ?[]const u8 = null,
};
