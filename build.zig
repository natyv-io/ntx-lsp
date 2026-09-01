const std = @import("std");

// The `ntx-lsp` binary -- deliberately standalone rather than a `natyv`
// subcommand (see README) -- depends on natyv-io/shared for the real
// `.ntx` transpiler core (`Expose`/`Codegen`, which pull in `Parser`/
// `Resolver`/`Stylesheet` transitively) instead of maintaining its own
// copy, mirroring exactly how natyv-io/cli consumes the same package.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared_dep = b.dependency("shared", .{ .target = target, .optimize = optimize });
    const expose_mod = shared_dep.module("Expose");
    const codegen_mod = shared_dep.module("Codegen");

    const ntx_lsp_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_lsp_module.addImport("Expose", expose_mod);
    ntx_lsp_module.addImport("Codegen", codegen_mod);
    const ntx_lsp_exe = b.addExecutable(.{
        .name = "ntx-lsp",
        .root_module = ntx_lsp_module,
    });
    b.installArtifact(ntx_lsp_exe);

    const ntx_lsp_run_cmd = b.addRunArtifact(ntx_lsp_exe);
    ntx_lsp_run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| ntx_lsp_run_cmd.addArgs(args);
    const run_step = b.step("run", "Run ntx-lsp");
    run_step.dependOn(&ntx_lsp_run_cmd.step);

    const ntx_lsp_test_module = b.createModule(.{
        .root_source_file = b.path("src/lsp/Server.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntx_lsp_test_module.addImport("Expose", expose_mod);
    ntx_lsp_test_module.addImport("Codegen", codegen_mod);
    const ntx_lsp_tests = b.addTest(.{ .root_module = ntx_lsp_test_module });
    const run_ntx_lsp_tests = b.addRunArtifact(ntx_lsp_tests);

    const test_step = b.step("test", "Run ntx-lsp's own unit tests");
    test_step.dependOn(&run_ntx_lsp_tests.step);
}
