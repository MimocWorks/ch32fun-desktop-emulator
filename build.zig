const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "ch32fun-desktop-emulator",
        .root_module = root_module,
    });

    exe.linkSystemLibrary("SDL3");
    exe.linkSystemLibrary("vulkan");

    const compile_vert = b.addSystemCommand(&.{
        "glslc",
        "-fshader-stage=vert",
        "shaders/oled.vert",
        "-o",
    });
    const vert_spv = compile_vert.addOutputFileArg("oled.vert.spv");
    const install_vert = b.addInstallFileWithDir(vert_spv, .{ .custom = "shaders" }, "oled.vert.spv");
    exe.step.dependOn(&compile_vert.step);

    const compile_frag = b.addSystemCommand(&.{
        "glslc",
        "-fshader-stage=frag",
        "shaders/oled.frag",
        "-o",
    });
    const frag_spv = compile_frag.addOutputFileArg("oled.frag.spv");
    const install_frag = b.addInstallFileWithDir(frag_spv, .{ .custom = "shaders" }, "oled.frag.spv");
    exe.step.dependOn(&compile_frag.step);

    b.installArtifact(exe);
    b.getInstallStep().dependOn(&install_vert.step);
    b.getInstallStep().dependOn(&install_frag.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setEnvironmentVariable("SDL_VIDEODRIVER", "x11");
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the desktop emulator");
    run_step.dependOn(&run_cmd.step);

    const probe_module = b.createModule(.{
        .root_source_file = b.path("src/sdl_probe.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const probe = b.addExecutable(.{
        .name = "sdl-probe",
        .root_module = probe_module,
    });
    probe.linkSystemLibrary("SDL3");
    b.installArtifact(probe);

    const run_probe = b.addRunArtifact(probe);
    run_probe.step.dependOn(b.getInstallStep());
    run_probe.setEnvironmentVariable("SDL_VIDEODRIVER", "x11");
    const probe_step = b.step("probe", "Run a minimal SDL window probe");
    probe_step.dependOn(&run_probe.step);
}
