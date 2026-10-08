const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite_dep = b.dependency("sqlite", .{});
    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION=1", "-DSQLITE_DQS=0" },
    });
    sqlite.root_module.addIncludePath(sqlite_dep.path("."));

    const exe = b.addExecutable(.{
        .name = "drome-lord",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addIncludePath(sqlite_dep.path("."));
    // stb_image decodes cover art for `drome-lord cover`
    const stb_dep = b.dependency("stb", .{});
    exe.root_module.addIncludePath(stb_dep.path("."));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/stb_impl.c"), .flags = &.{} });
    exe.root_module.linkLibrary(sqlite);
    // macos visualizer: core audio process tap (`drome-lord tap <pid>`, see src/tap.m)
    if (target.result.os.tag == .macos) {
        exe.root_module.addCSourceFile(.{ .file = b.path("src/tap.m"), .flags = &.{ "-fobjc-arc", "-mmacosx-version-min=14.2" } });
        exe.root_module.linkFramework("CoreAudio", .{});
        exe.root_module.linkFramework("Foundation", .{});
    }
    // macos keys the system audio permission to the code signature: an ad-hoc one changes with every
    // build (so every rebuild asks again), a real identity keeps the grant. re-signing also binds the
    // embedded Info.plist from tap.m.
    if (target.result.os.tag == .macos) {
        const identity = b.option([]const u8, "codesign", "macos signing identity (default: ad-hoc, re-asks for audio permission after every rebuild)") orelse "-";
        const sign = b.addSystemCommand(&.{ "sh", "-c", "cp \"$1\" \"$2\" && codesign --remove-signature \"$2\" && codesign --sign \"$3\" --identifier al.imre.drome-lord \"$2\"", "sign" });
        sign.addFileArg(exe.getEmittedBin());
        const signed = sign.addOutputFileArg("drome-lord");
        sign.addArg(identity);
        b.getInstallStep().dependOn(&b.addInstallBinFile(signed, "drome-lord").step);
    } else {
        b.installArtifact(exe);
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "run drome-lord").dependOn(&run.step);
}
