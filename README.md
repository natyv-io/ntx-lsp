# natyv-io/ntx-lsp

The `ntx-lsp` binary -- a real LSP server for `.ntx` (natyv's JSX-like markup DSL), giving editors
hover, go-to-definition, semantic tokens, and diagnostics against `.ntx` source without needing to
understand its grammar themselves.

Deliberately standalone rather than a `natyv` CLI subcommand -- decouples its stdio/JSON-RPC process
lifecycle from the CLI's own argv/exit-code conventions. Moved out of
[natyv-io/cli](https://github.com/natyv-io/cli) into its own repo (2026-09-01) once the `.ntx`
transpiler core it depends on (`Parser`/`Expose`/`Codegen`/`Resolver`/`Stylesheet`) moved to
[natyv-io/shared](https://github.com/natyv-io/shared), which `cli` also depends on -- `ntx-lsp` re-runs
the real transpile (`Expose.findComposers` + `Codegen.generateGo`) on every LSP request rather than
maintaining its own parallel understanding of `.ntx`.

Consumed by the natyv-io editor extensions (`vscode-ntx`, `zed-ntx`, etc.) as the actual language
server they launch.
