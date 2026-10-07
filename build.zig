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
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "run drome-lord").dependOn(&run.step);
}
