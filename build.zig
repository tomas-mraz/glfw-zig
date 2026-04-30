const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    const default_use_x11 = target.result.os.tag == .linux and false;
    const default_use_wayland = target.result.os.tag == .linux;

    const use_x11 = b.option(bool, "x11", "Build with X11. Only useful on Linux") orelse default_use_x11;
    const use_wayland = b.option(bool, "wayland", "Build with Wayland. Only useful on Linux") orelse default_use_wayland;
    const use_opengl = b.option(bool, "opengl", "Build with OpenGL; deprecated on macOS") orelse false;
    const use_gles = b.option(bool, "gles", "Build with GLES; not supported on macOS") orelse false;
    const use_metal = b.option(bool, "metal", "Build with Metal; only supported on macOS") orelse true;
    const shared = b.option(bool, "shared", "Build as a shared library") orelse false;

    const glfw_c = b.dependency("glfw_c", .{});

    const glfw_lib = buildGlfwLibrary(b, target, optimize, glfw_c, .{
        .shared = shared,
        .use_x11 = use_x11,
        .use_wayland = use_wayland,
        .use_opengl = use_opengl,
        .use_gles = use_gles,
        .use_metal = use_metal,
    });

    const glfw_c_bindings = createGlfwBindings(b, target, optimize, glfw_c);
    const glfw_native_bindings = createGlfwNativeBindings(b, target, optimize, glfw_c, .{
        .use_x11 = use_x11,
        .use_wayland = use_wayland,
    });

    const module = b.addModule("glfw", .{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
    });
    module.linkLibrary(glfw_lib);
    module.addImport("glfw_c_bindings", glfw_c_bindings);
    module.addImport("glfw_native_bindings", glfw_native_bindings);

    const test_root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root.linkLibrary(glfw_lib);
    test_root.addImport("glfw_c_bindings", glfw_c_bindings);
    test_root.addImport("glfw_native_bindings", glfw_native_bindings);

    const test_step = b.step("test", "Run library tests");
    const main_tests = b.addTest(.{
        .name = "glfw-tests",
        .root_module = test_root,
    });
    b.installArtifact(main_tests);
    test_step.dependOn(&b.addRunArtifact(main_tests).step);
}

const BuildOptions = struct {
    shared: bool,
    use_x11: bool,
    use_wayland: bool,
    use_opengl: bool,
    use_gles: bool,
    use_metal: bool,
};

fn buildGlfwLibrary(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glfw_c: *std.Build.Dependency,
    options: BuildOptions,
) *std.Build.Step.Compile {
    const glfw_root = glfw_c.path("");
    const glfw_include = glfw_c.path("include");

    const lib = b.addLibrary(.{
        .name = "glfw",
        .linkage = if (options.shared) .dynamic else .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addIncludePath(glfw_include);

    if (options.shared) {
        lib.root_module.addCMacro("_GLFW_BUILD_DLL", "1");
    }

    lib.installHeadersDirectory(glfw_c.path("include/GLFW"), "GLFW", .{});

    if (target.result.os.tag.isDarwin()) {
        lib.root_module.addCMacro("__kernel_ptr_semantics", "");
        addMacosSdkRootToModule(b, lib.root_module, target);
    }

    const include_src_flag = "-Isrc";

    switch (target.result.os.tag) {
        .windows => {
            lib.root_module.linkSystemLibrary("gdi32", .{});
            lib.root_module.linkSystemLibrary("user32", .{});
            lib.root_module.linkSystemLibrary("shell32", .{});

            if (options.use_opengl) {
                lib.root_module.linkSystemLibrary("opengl32", .{});
            }
            if (options.use_gles) {
                lib.root_module.linkSystemLibrary("GLESv3", .{});
            }

            const flags = [_][]const u8{ "-D_GLFW_WIN32", include_src_flag };
            lib.root_module.addCSourceFiles(.{
                .root = glfw_root,
                .files = &base_sources,
                .flags = &flags,
            });
            lib.root_module.addCSourceFiles(.{
                .root = glfw_root,
                .files = &windows_sources,
                .flags = &flags,
            });
        },
        .macos => {
            // Cross-compile from a non-Darwin host: xcrun isn't available so
            // point the linker at a staged Apple SDK via $SDKROOT. Native
            // macOS builds rely on Zig's xcrun auto-detection and skip this.
            if (!b.graph.host.result.os.tag.isDarwin()) {
                if (b.graph.environ_map.get("SDKROOT")) |sdk_root| {
                    lib.root_module.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdk_root}) });
                    lib.root_module.addFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdk_root}) });
                    lib.root_module.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdk_root}) });
                }
            }
            lib.root_module.linkFramework("CFNetwork", .{});
            lib.root_module.linkFramework("ApplicationServices", .{});
            lib.root_module.linkFramework("ColorSync", .{});
            lib.root_module.linkFramework("CoreText", .{});
            lib.root_module.linkFramework("ImageIO", .{});

            lib.root_module.linkSystemLibrary("objc", .{});
            lib.root_module.linkFramework("IOKit", .{});
            lib.root_module.linkFramework("CoreFoundation", .{});
            lib.root_module.linkFramework("AppKit", .{});
            lib.root_module.linkFramework("CoreServices", .{});
            lib.root_module.linkFramework("CoreGraphics", .{});
            lib.root_module.linkFramework("Foundation", .{});

            if (options.use_metal) {
                lib.root_module.linkFramework("Metal", .{});
            }
            if (options.use_opengl) {
                lib.root_module.linkFramework("OpenGL", .{});
            }

            const flags = [_][]const u8{ "-D_GLFW_COCOA", include_src_flag };
            lib.root_module.addCSourceFiles(.{
                .root = glfw_root,
                .files = &base_sources,
                .flags = &flags,
            });
            lib.root_module.addCSourceFiles(.{
                .root = glfw_root,
                .files = &macos_sources,
                .flags = &flags,
            });
        },
        else => {
            var sources: std.ArrayList([]const u8) = .empty;
            defer sources.deinit(b.allocator);
            var flags: std.ArrayList([]const u8) = .empty;
            defer flags.deinit(b.allocator);

            appendSlice(&sources, b.allocator, &base_sources);
            appendSlice(&sources, b.allocator, &linux_common_sources);

            if (options.use_x11) {
                appendSlice(&sources, b.allocator, &linux_backend_shared_sources);
                appendSlice(&sources, b.allocator, &linux_x11_sources);
                flags.append(b.allocator, "-D_GLFW_X11") catch @panic("OOM");
            }

            if (options.use_wayland) {
                lib.root_module.addCMacro("WL_MARSHAL_FLAG_DESTROY", "1");
                appendSlice(&sources, b.allocator, &linux_backend_shared_sources);
                appendSlice(&sources, b.allocator, &linux_wayland_sources);
                flags.append(b.allocator, "-D_GLFW_WAYLAND") catch @panic("OOM");
                flags.append(b.allocator, "-Wno-implicit-function-declaration") catch @panic("OOM");

                const generated_wayland = generateWaylandHeaders(b, glfw_c);
                lib.root_module.addIncludePath(generated_wayland);
            }

            flags.append(b.allocator, include_src_flag) catch @panic("OOM");

            lib.root_module.addCSourceFiles(.{
                .root = glfw_root,
                .files = sources.items,
                .flags = flags.items,
            });
        },
    }

    b.installArtifact(lib);
    return lib;
}

fn createGlfwBindings(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glfw_c: *std.Build.Dependency,
) *std.Build.Module {
    const translated = b.addTranslateC(.{
        .root_source_file = glfw_c.path("include/GLFW/glfw3.h"),
        .target = target,
        .optimize = optimize,
    });
    translated.addIncludePath(glfw_c.path("include"));
    addVulkanIncludeIfAvailable(b, translated);
    addAppleSdkIncludesIfAvailable(b, translated, target);
    translated.defineCMacro("GLFW_INCLUDE_VULKAN", "1");
    translated.defineCMacro("GLFW_INCLUDE_NONE", "1");
    if (target.result.os.tag.isDarwin()) {
        translated.defineCMacro("__kernel_ptr_semantics", "");
        addMacosSdkRootToTranslateC(b, translated, target);
    }
    addVulkanSdkInclude(b, translated);
    return translated.createModule();
}

fn createGlfwNativeBindings(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glfw_c: *std.Build.Dependency,
    options: struct {
        use_x11: bool,
        use_wayland: bool,
    },
) *std.Build.Module {
    const wrapper = b.addWriteFiles().add("glfw_native_wrapper.h",
        \\#include <GLFW/glfw3.h>
        \\#include <GLFW/glfw3native.h>
        \\
    );
    const translated = b.addTranslateC(.{
        .root_source_file = wrapper,
        .target = target,
        .optimize = optimize,
    });
    translated.addIncludePath(glfw_c.path("include"));
    addVulkanIncludeIfAvailable(b, translated);
    addAppleSdkIncludesIfAvailable(b, translated, target);
    translated.defineCMacro("GLFW_INCLUDE_VULKAN", "1");
    translated.defineCMacro("GLFW_INCLUDE_NONE", "1");
    addVulkanSdkInclude(b, translated);

    // Apple's Cocoa/AppKit headers contain Objective-C constructs (blocks,
    // nullability annotations on uuid_t) that translate-c cannot parse. When
    // cross-compiling to macOS from a non-Darwin host we skip the COCOA/NSGL
    // macros so glfw3native.h's Apple branch isn't pulled in. Native macOS
    // builds (host is Darwin) keep them so getCocoaWindow / getNSGLContext
    // remain available.
    const host_is_darwin = b.graph.host.result.os.tag.isDarwin();
    switch (target.result.os.tag) {
        .windows => {
            translated.defineCMacro("GLFW_EXPOSE_NATIVE_WIN32", "1");
            translated.defineCMacro("GLFW_EXPOSE_NATIVE_WGL", "1");
        },
        .macos => {
            if (host_is_darwin) {
                translated.defineCMacro("GLFW_EXPOSE_NATIVE_COCOA", "1");
                translated.defineCMacro("GLFW_EXPOSE_NATIVE_NSGL", "1");
            }
            translated.defineCMacro("__kernel_ptr_semantics", "");
            addMacosSdkRootToTranslateC(b, translated, target);
        },
        else => {
            if (options.use_x11) {
                translated.defineCMacro("GLFW_EXPOSE_NATIVE_X11", "1");
                translated.defineCMacro("GLFW_EXPOSE_NATIVE_GLX", "1");
            }
            if (options.use_wayland) {
                translated.defineCMacro("GLFW_EXPOSE_NATIVE_WAYLAND", "1");
            }
            translated.defineCMacro("GLFW_EXPOSE_NATIVE_EGL", "1");
        },
    }

    return translated.createModule();
}

fn appendSlice(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, items: []const []const u8) void {
    list.appendSlice(allocator, items) catch @panic("OOM");
}

const WaylandProtocol = struct {
    xml: []const u8,
    base: []const u8,
};

const wayland_protocols = [_]WaylandProtocol{
    .{ .xml = "deps/wayland/wayland.xml", .base = "wayland-client-protocol" },
    .{ .xml = "deps/wayland/xdg-shell.xml", .base = "xdg-shell-client-protocol" },
    .{ .xml = "deps/wayland/xdg-decoration-unstable-v1.xml", .base = "xdg-decoration-unstable-v1-client-protocol" },
    .{ .xml = "deps/wayland/viewporter.xml", .base = "viewporter-client-protocol" },
    .{ .xml = "deps/wayland/relative-pointer-unstable-v1.xml", .base = "relative-pointer-unstable-v1-client-protocol" },
    .{ .xml = "deps/wayland/pointer-constraints-unstable-v1.xml", .base = "pointer-constraints-unstable-v1-client-protocol" },
    .{ .xml = "deps/wayland/idle-inhibit-unstable-v1.xml", .base = "idle-inhibit-unstable-v1-client-protocol" },
    .{ .xml = "deps/wayland/xdg-activation-v1.xml", .base = "xdg-activation-v1-client-protocol" },
    .{ .xml = "deps/wayland/fractional-scale-v1.xml", .base = "fractional-scale-v1-client-protocol" },
};

fn generateWaylandHeaders(b: *std.Build, glfw_c: *std.Build.Dependency) std.Build.LazyPath {
    const wf = b.addWriteFiles();

    for (wayland_protocols) |p| {
        const header_name = b.fmt("{s}.h", .{p.base});
        const code_name = b.fmt("{s}-code.h", .{p.base});

        const header_run = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
        header_run.addFileArg(glfw_c.path(p.xml));
        const header_out = header_run.addOutputFileArg(header_name);
        _ = wf.addCopyFile(header_out, header_name);

        const code_run = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        code_run.addFileArg(glfw_c.path(p.xml));
        const code_out = code_run.addOutputFileArg(code_name);
        _ = wf.addCopyFile(code_out, code_name);
    }

    return wf.getDirectory();
}

const base_sources = [_][]const u8{
    "src/context.c",
    "src/egl_context.c",
    "src/init.c",
    "src/input.c",
    "src/monitor.c",
    "src/null_init.c",
    "src/null_joystick.c",
    "src/null_monitor.c",
    "src/null_window.c",
    "src/osmesa_context.c",
    "src/platform.c",
    "src/vulkan.c",
    "src/window.c",
};

const linux_common_sources = [_][]const u8{
    "src/posix_module.c",
    "src/posix_thread.c",
    "src/posix_time.c",
};

const linux_backend_shared_sources = [_][]const u8{
    "src/linux_joystick.c",
    "src/posix_poll.c",
};

const linux_wayland_sources = [_][]const u8{
    "src/wl_init.c",
    "src/wl_monitor.c",
    "src/wl_window.c",
};

const linux_x11_sources = [_][]const u8{
    "src/xkb_unicode.c",
    "src/glx_context.c",
    "src/x11_init.c",
    "src/x11_monitor.c",
    "src/x11_window.c",
};

const windows_sources = [_][]const u8{
    "src/wgl_context.c",
    "src/win32_init.c",
    "src/win32_joystick.c",
    "src/win32_module.c",
    "src/win32_monitor.c",
    "src/win32_thread.c",
    "src/win32_time.c",
    "src/win32_window.c",
};

const macos_sources = [_][]const u8{
    "src/cocoa_time.c",
    "src/posix_module.c",
    "src/posix_thread.c",
    "src/cocoa_init.m",
    "src/cocoa_joystick.m",
    "src/cocoa_monitor.m",
    "src/cocoa_window.m",
    "src/nsgl_context.m",
};

// macOS cross-compile from non-Darwin hosts: Zig doesn't auto-discover the SDK,
// so we wire SDKROOT into system include / framework / library search paths.
fn addMacosSdkRootToModule(
    b: *std.Build,
    m: *std.Build.Module,
    target: std.Build.ResolvedTarget,
) void {
    if (!target.result.os.tag.isDarwin()) return;
    const sdkroot = b.graph.environ_map.get("SDKROOT") orelse return;
    m.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdkroot}) });
    m.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdkroot}) });
    m.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/usr/lib", .{sdkroot}) });
}

fn addAppleSdkIncludesIfAvailable(
    b: *std.Build,
    t: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) void {
    if (!target.result.os.tag.isDarwin()) return;
    const sdkroot = b.graph.environ_map.get("SDKROOT") orelse return;
    t.addSystemIncludePath(.{ .cwd_relative = b.fmt("{s}/usr/include", .{sdkroot}) });
    t.addSystemFrameworkPath(.{ .cwd_relative = b.fmt("{s}/System/Library/Frameworks", .{sdkroot}) });
}

fn addVulkanIncludeIfAvailable(b: *std.Build, t: *std.Build.Step.TranslateC) void {
    const sdk = b.graph.environ_map.get("VULKAN_SDK") orelse return;
    t.addIncludePath(.{ .cwd_relative = b.fmt("{s}/x86_64/include", .{sdk}) });
}
