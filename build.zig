const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os = target.result.os.tag;

    // --- ANGLE library paths ---
    // Per-platform defaults: third_party/angle-out/<platform>/
    // Override with -Dangle-lib-path= and -Dangle-include-path= for custom locations.
    const default_platform_dir = switch (os) {
        .macos => "macos",
        .windows => "windows",
        .linux => "linux",
        else => "unknown",
    };

    const angle_lib_path = b.option(
        []const u8,
        "angle-lib-path",
        "Path to directory containing ANGLE shared libraries",
    ) orelse b.pathJoin(&.{ "third_party/angle-out", default_platform_dir, "lib" });

    const angle_include_path = b.option(
        []const u8,
        "angle-include-path",
        "Path to ANGLE include directory (EGL/, GLES2/ headers)",
    ) orelse b.pathJoin(&.{ "third_party/angle-out", default_platform_dir, "include" });

    // --- Build raylib with OpenGL ES 2 (for ANGLE on all platforms) ---
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
        .opengl_version = .gles_2,
        .platform = .glfw,
        .linkage = .static,
    });

    const raylib = raylib_dep.artifact("raylib");

    // --- Build the application ---
    const exe = b.addExecutable(.{
        .name = "raylib_love",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            // macOS: Cocoa/GLFW needs OS main thread
            .single_threaded = if (os == .macos) true else null,
        }),
    });

    // Link raylib (static)
    exe.root_module.linkLibrary(raylib);

    // Raylib headers
    exe.root_module.addIncludePath(raylib_dep.path("src"));

    // --- Link ANGLE (all platforms) ---
    exe.root_module.addLibraryPath(.{ .cwd_relative = angle_lib_path });
    exe.root_module.addIncludePath(.{ .cwd_relative = angle_include_path });
    exe.root_module.linkSystemLibrary("EGL", .{});
    exe.root_module.linkSystemLibrary("GLESv2", .{});

    // --- Platform-specific system libraries ---
    switch (os) {
        .macos => {
            // macOS frameworks (NOT OpenGL.framework — ANGLE replaces it)
            exe.root_module.linkFramework("Foundation", .{});
            exe.root_module.linkFramework("CoreServices", .{});
            exe.root_module.linkFramework("CoreGraphics", .{});
            exe.root_module.linkFramework("AppKit", .{});
            exe.root_module.linkFramework("IOKit", .{});
            exe.root_module.linkFramework("CoreVideo", .{});
            exe.root_module.linkFramework("Cocoa", .{});
            exe.root_module.linkFramework("CoreAudio", .{});

            // rpaths for macOS dylib resolution
            exe.root_module.addRPath(.{ .cwd_relative = angle_lib_path });
            exe.root_module.addRPath(.{ .cwd_relative = "@executable_path" });
        },
        .windows => {
            // Windows system libraries raylib needs
            exe.root_module.linkSystemLibrary("gdi32", .{});
            exe.root_module.linkSystemLibrary("winmm", .{});
            exe.root_module.linkSystemLibrary("shell32", .{});
            exe.root_module.linkSystemLibrary("user32", .{});
            exe.root_module.linkSystemLibrary("kernel32", .{});
        },
        .linux => {
            // Linux system libraries
            exe.root_module.linkSystemLibrary("X11", .{});
            exe.root_module.linkSystemLibrary("Xrandr", .{});
            exe.root_module.linkSystemLibrary("Xinerama", .{});
            exe.root_module.linkSystemLibrary("Xi", .{});
            exe.root_module.linkSystemLibrary("Xcursor", .{});
            exe.root_module.linkSystemLibrary("pthread", .{});
            exe.root_module.linkSystemLibrary("dl", .{});
            exe.root_module.linkSystemLibrary("m", .{});

            // rpath for .so resolution
            exe.root_module.addRPath(.{ .cwd_relative = angle_lib_path });
            exe.root_module.addRPath(.{ .cwd_relative = "$ORIGIN" });
        },
        else => {},
    }

    b.installArtifact(exe);

    // --- Copy ANGLE shared libraries to zig-out/bin/ ---
    const lib_ext: []const u8 = switch (os) {
        .macos => "dylib",
        .windows => "dll",
        .linux => "so",
        else => "so",
    };

    const egl_name = b.fmt("libEGL.{s}", .{lib_ext});
    const gles_name = b.fmt("libGLESv2.{s}", .{lib_ext});

    const install_egl = b.addInstallBinFile(.{ .cwd_relative = b.pathJoin(&.{ angle_lib_path, egl_name }) }, egl_name);
    const install_gles = b.addInstallBinFile(.{ .cwd_relative = b.pathJoin(&.{ angle_lib_path, gles_name }) }, gles_name);
    b.getInstallStep().dependOn(&install_egl.step);
    b.getInstallStep().dependOn(&install_gles.step);

    // --- Run step ---
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_cmd.step);
}
