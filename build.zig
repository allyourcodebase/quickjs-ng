const std = @import("std");

fn addDefines(c: *std.Build.Step.Compile, b: *std.Build) void {
    c.root_module.addCMacro("CONFIG_BIGNUM", "1");
    c.root_module.addCMacro("_GNU_SOURCE", "1");
    _ = b;
}

fn addStdLib(c: *std.Build.Step.Compile, cflags: []const []const u8, root: *std.Build.Dependency) void {
    if (c.rootModuleTarget().os.tag == .wasi) {
        c.root_module.addCMacro("_WASI_EMULATED_PROCESS_CLOCKS", "1");
        c.root_module.addCMacro("_WASI_EMULATED_SIGNAL", "1");
        c.linkSystemLibrary("wasi-emulated-process-clocks");
        c.linkSystemLibrary("wasi-emulated-signal");
    }
    c.addCSourceFiles(.{ .files = &.{"quickjs-libc.c"}, .flags = cflags, .root = root.path(".") });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const include_stdlib = b.option(bool, "stdlib", "include stdlib in library") orelse true;

    const csrc = b.dependency("quickjs-ng", .{});

    const cflags = &.{
        "-Wno-implicit-fallthrough",
        "-Wno-sign-compare",
        "-Wno-missing-field-initializers",
        "-Wno-unused-parameter",
        "-Wno-unused-but-set-variable",
        "-Wno-array-bounds",
        "-Wno-format-truncation",
        "-funsigned-char",
        "-fwrapv",
    };

    const libquickjs_source = &.{
        "quickjs.c",
        "libregexp.c",
        "libunicode.c",
        "cutils.c",
        "xsum.c",
    };

    const libquickjs = b.addLibrary(.{
        .name = "quickjs",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    libquickjs.addCSourceFiles(.{
        .files = libquickjs_source,
        .flags = cflags,
        .root = csrc.path("."),
    });
    addDefines(libquickjs, b);
    if (include_stdlib) {
        addStdLib(libquickjs, cflags, csrc);
    }
    libquickjs.linkLibC();
    if (target.result.os.tag == .windows) {
        libquickjs.stack_size = 8388608;
    }
    b.installArtifact(libquickjs);

    const qjsc = b.addExecutable(.{
        .name = "qjsc",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    qjsc.addCSourceFiles(.{
        .files = &.{"qjsc.c"},
        .flags = cflags,
        .root = csrc.path("."),
    });
    qjsc.linkLibrary(libquickjs);
    addDefines(qjsc, b);
    if (!include_stdlib) {
        addStdLib(qjsc, cflags, csrc);
    }
    b.installArtifact(qjsc);

    const qjsc_host = b.addExecutable(.{
        .name = "qjsc-host",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    if (b.graph.host.result.os.tag == .windows) {
        qjsc_host.stack_size = 8388608;
    }

    qjsc_host.addCSourceFiles(.{
        .files = &.{"qjsc.c"},
        .flags = cflags,
        .root = csrc.path("."),
    });
    qjsc_host.addCSourceFiles(.{
        .files = libquickjs_source,
        .flags = cflags,
        .root = csrc.path("."),
    });
    addStdLib(qjsc_host, cflags, csrc);
    addDefines(qjsc_host, b);
    qjsc_host.linkLibC();

    const header = b.addTranslateC(.{
        .root_source_file = csrc.path("quickjs.h"),
        .target = target,
        .optimize = optimize,
    });
    _ = b.addModule("quickjs-ng", .{ .root_source_file = header.getOutput() });

    const gen_repl = b.addRunArtifact(qjsc_host);
    gen_repl.addArg("-N");
    gen_repl.addArg("qjsc_repl");
    gen_repl.addArg("-o");
    const gen_repl_out = gen_repl.addOutputFileArg("repl.c");
    gen_repl.addArg("-m");
    gen_repl.addFileArg(csrc.path("repl.js"));

    const gen_standalone = b.addRunArtifact(qjsc_host);
    gen_standalone.addArg("-N");
    gen_standalone.addArg("qjsc_standalone");
    gen_standalone.addArg("-o");
    const gen_standalone_out = gen_standalone.addOutputFileArg("standalone.c");
    gen_standalone.addArg("-m");
    gen_standalone.addFileArg(csrc.path("standalone.js"));

    const qjs = b.addExecutable(.{
        .name = "qjs",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
    });
    qjs.addCSourceFiles(.{
        .files = &.{"qjs.c"},
        .flags = cflags,
        .root = csrc.path("."),
    });
    qjs.addCSourceFiles(.{
        .files = &.{"repl.c"},
        .root = gen_repl_out.dirname(),
        .flags = cflags,
    });
    qjs.addCSourceFiles(.{
        .files = &.{"standalone.c"},
        .root = gen_standalone_out.dirname(),
        .flags = cflags,
    });
    if (!include_stdlib) {
        addStdLib(qjs, cflags, csrc);
    }
    qjs.linkLibrary(libquickjs);
    addDefines(qjs, b);
    qjs.step.dependOn(&gen_repl.step);
    qjs.step.dependOn(&gen_standalone.step);
    b.installArtifact(qjs);
}
