# Raylib + ANGLE (Metal) on macOS via Zig

A complete guide to building a Zig application that uses raylib for rendering, with Google's ANGLE providing OpenGL ES 2.0 over Apple's Metal API. This bypasses Apple's deprecated OpenGL framework entirely.

## Architecture

```
Your Zig application
  |
  |  (static link)
  v
raylib (compiled with GRAPHICS_API_OPENGL_ES2)
  |
  |  (GLFW requests EGL context via GLFW_EGL_CONTEXT_API hint)
  v
libEGL.dylib + libGLESv2.dylib  (ANGLE)
  |
  |  (translates GLES calls to Metal)
  v
Metal.framework (Apple GPU driver)
```

**Why this works**: Apple deprecated OpenGL in macOS 10.14 and has not updated it since. ANGLE is Google's production-grade OpenGL ES implementation (used in Chrome, Android emulator, etc.) that can target Metal as its backend. Raylib has experimental support for desktop OpenGL ES 2.0, originally intended for exactly this ANGLE use case.

## Prerequisites

- macOS 10.14+ (for Metal support)
- Xcode with Command Line Tools and Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`)
- Zig 0.15.x (`zig version` to confirm)
- Python 3 in PATH
- ~15 GB disk space for ANGLE source and build artifacts

## Project Layout

```
your-project/
  build.zig              # Zig build: compiles raylib, links ANGLE, builds app
  build.zig.zon          # Dependency manifest (raylib)
  src/
    main.zig             # Your application code
  scripts/
    build_angle.sh # Builds ANGLE from source with Metal backend
  third_party/
    angle-out/           # ANGLE build output (produced by the script)
      lib/
        libEGL.dylib     # ANGLE's EGL implementation
        libGLESv2.dylib  # ANGLE's OpenGL ES 2.0 implementation
      include/
        EGL/             # EGL headers
        GLES2/           # OpenGL ES 2.0 headers
        GLES3/           # OpenGL ES 3.0 headers
        KHR/             # Khronos platform headers
  .angle-build/          # ANGLE source + build working directory (gitignored)
```

## Step 1: Build ANGLE from Source

ANGLE uses Google's `depot_tools` build system (the same one that builds Chromium). The `scripts/build_angle.sh` script automates the entire process.

### What the script does

**1. Installs depot_tools**

```bash
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
```

`depot_tools` provides `fetch`, `gclient`, `gn`, and `autoninja` - the tools needed to build any Chromium-ecosystem project. `fetch` is the entry point: it clones a project and all its dependencies in one step (think `git clone --recursive` but for Google's more complex dependency system).

**2. Fetches ANGLE source**

```bash
cd .angle-build
fetch angle
```

This clones the ANGLE repository and runs `gclient sync` to pull dozens of sub-dependencies (build toolchain, shader compiler, test frameworks, etc.). First run downloads several GB. Subsequent runs use `gclient sync` to update incrementally.

**Important**: `fetch angle` checks out directly into the current directory (not into a subdirectory). The `.gclient` file, `BUILD.gn`, `src/`, etc. all appear at the top level.

**3. Configures the build with GN**

GN (Generate Ninja) is the meta-build system. We write `args.gn` to configure a Metal-only release build:

```gn
# .angle-build/out/Release/args.gn
is_debug = false
is_component_build = false    # Self-contained dylibs (no internal shared lib deps)

angle_enable_metal = true     # The only backend we want

angle_enable_d3d9  = false    # Disable everything else
angle_enable_d3d11 = false
angle_enable_gl    = false
angle_enable_vulkan = false
angle_enable_null  = false
angle_enable_swiftshader = false

angle_enable_essl = false
angle_enable_glsl = true      # Required: Metal shader pipeline uses GLSL translator
```

Key flags explained:
- `is_component_build = false`: Statically links all ANGLE internals into the two output dylibs, making them fully self-contained and relocatable.
- `angle_enable_glsl = true`: Even though we disable the desktop GL backend, the Metal shader compiler internally uses the GLSL translator to process shaders. Without this, you get link errors.

Then `gn gen out/Release` generates the Ninja build files.

**4. Builds with Ninja**

```bash
autoninja -C out/Release libEGL libGLESv2
```

We only build the two targets we need, not the entire ANGLE tree. This takes ~10 minutes on Apple Silicon.

**5. Copies and fixes outputs**

```bash
cp out/Release/libEGL.dylib   third_party/angle-out/lib/
cp out/Release/libGLESv2.dylib third_party/angle-out/lib/

# Critical: fix dylib install names
install_name_tool -id @rpath/libEGL.dylib   third_party/angle-out/lib/libEGL.dylib
install_name_tool -id @rpath/libGLESv2.dylib third_party/angle-out/lib/libGLESv2.dylib
```

**The install_name_tool step is critical.** ANGLE's build produces dylibs with the install name `./libEGL.dylib` (relative to the current working directory). This means the dynamic linker looks for the dylib in whatever directory you run the app from - which almost never works. We rewrite them to `@rpath/libEGL.dylib` so that macOS resolves them using the rpath entries embedded in the executable.

### Running the script

```bash
./scripts/build_angle.sh                     # default output
./scripts/build_angle.sh /custom/path        # custom output directory
ANGLE_JOBS=4 ./scripts/build_angle.sh        # limit CPU cores
```

## Step 2: Declare raylib as a Zig Dependency

### build.zig.zon

```zig
.{
    .name = .raylib_love,
    .version = "0.0.1",
    .fingerprint = 0xbf3f85965e5b366f,
    .dependencies = .{
        .raylib = .{
            // Compatible with Zig 0.15.1+ (commit 2025-12-16)
            .url = "git+https://github.com/raysan5/raylib#33adda198366e560afa59a806dd8db2609261e40",
            .hash = "raylib-5.6.0-dev-whq8uGRCCgX38P2GBEH6tmBMIAYt3SxIK_VkHvIehETU",
        },
    },
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

**Version pinning matters.** Raylib's master branch moves fast and periodically bumps the minimum Zig version. The commit `33adda19` (2025-12-16) is the last one compatible with both Zig 0.15.1 and 0.16-dev. When you upgrade Zig, you may need to update this pin.

**How to find the hash**: Set the `.hash` field to any placeholder string, run `zig build`, and the compiler will tell you the correct hash in the error message.

## Step 3: The Build Configuration (build.zig)

The build.zig does four things: builds raylib, links ANGLE, sets up rpaths, and copies dylibs.

### 3a. Build raylib with OpenGL ES 2

```zig
const raylib_dep = b.dependency("raylib", .{
    .target = target,
    .optimize = optimize,
    .opengl_version = .gles_2,   // Defines GRAPHICS_API_OPENGL_ES2
    .platform = .glfw,            // Window/input backend
    .linkage = .static,           // Static library (linked into our binary)
});

const raylib = raylib_dep.artifact("raylib");
```

Setting `.opengl_version = .gles_2` causes raylib's build to define the C macro `GRAPHICS_API_OPENGL_ES2`. This switches raylib's rendering layer (rlgl) from desktop OpenGL calls to OpenGL ES 2.0 calls, and tells GLFW to create an EGL context instead of a native NSGL context.

### 3b. Link ANGLE instead of Apple OpenGL

```zig
// Point the linker at the ANGLE dylibs
exe.root_module.addLibraryPath(.{ .cwd_relative = angle_lib_path });
exe.root_module.addIncludePath(.{ .cwd_relative = angle_include_path });

// Link ANGLE's libraries
exe.root_module.linkSystemLibrary("EGL", .{});
exe.root_module.linkSystemLibrary("GLESv2", .{});

// macOS frameworks raylib needs (but NOT OpenGL.framework!)
exe.root_module.linkFramework("Foundation", .{});
exe.root_module.linkFramework("CoreServices", .{});
exe.root_module.linkFramework("CoreGraphics", .{});
exe.root_module.linkFramework("AppKit", .{});
exe.root_module.linkFramework("IOKit", .{});
exe.root_module.linkFramework("CoreVideo", .{});
exe.root_module.linkFramework("Cocoa", .{});
exe.root_module.linkFramework("CoreAudio", .{});
```

The critical detail: we link `EGL` and `GLESv2` (which resolve to ANGLE's dylibs) and we do **not** link Apple's `OpenGL` framework. The macOS frameworks listed are what raylib needs for windowing, input, and audio - they have nothing to do with graphics rendering.

### 3c. Set up runtime library paths (rpaths)

```zig
// Development: find dylibs relative to project root
exe.root_module.addRPath(.{ .cwd_relative = angle_lib_path });
// Installed: find dylibs next to the executable
exe.root_module.addRPath(.{ .cwd_relative = "@executable_path" });
```

macOS uses rpaths to locate dynamic libraries at runtime. We set two:
1. The source `third_party/angle-out/lib/` path (works during development)
2. `@executable_path` (works when dylibs are copied next to the binary in `zig-out/bin/`)

### 3d. Copy ANGLE dylibs to output

```zig
const install_egl = b.addInstallBinFile(
    .{ .cwd_relative = b.pathJoin(&.{ angle_lib_path, "libEGL.dylib" }) },
    "libEGL.dylib",
);
const install_gles = b.addInstallBinFile(
    .{ .cwd_relative = b.pathJoin(&.{ angle_lib_path, "libGLESv2.dylib" }) },
    "libGLESv2.dylib",
);
b.getInstallStep().dependOn(&install_egl.step);
b.getInstallStep().dependOn(&install_gles.step);
```

This ensures `zig-out/bin/` contains both the executable and the ANGLE dylibs, so `zig build run` works without any manual file copying.

### macOS threading requirement

```zig
.single_threaded = true, // macOS: Cocoa/GLFW needs OS main thread
```

On Zig 0.15+, `main()` may run on a spawned thread, but Cocoa and GLFW require the OS main thread. Setting `single_threaded = true` ensures `main()` runs on the main thread.

## Step 4: Using raylib from Zig

Zig's `@cImport` translates raylib's C headers into Zig types at compile time:

```zig
const rl = @cImport({
    @cInclude("raylib.h");
    @cInclude("raymath.h");
});
```

Then you call raylib functions directly:

```zig
pub fn main() void {
    rl.InitWindow(800, 600, "raylib + ANGLE (Metal)");
    defer rl.CloseWindow();

    rl.SetTargetFPS(60);

    const camera = rl.Camera3D{
        .position = .{ .x = 4.0, .y = 4.0, .z = 4.0 },
        .target = .{ .x = 0.0, .y = 0.0, .z = 0.0 },
        .up = .{ .x = 0.0, .y = 1.0, .z = 0.0 },
        .fovy = 45.0,
        .projection = rl.CAMERA_PERSPECTIVE,
    };

    while (!rl.WindowShouldClose()) {
        rl.BeginDrawing();
        defer rl.EndDrawing();

        rl.ClearBackground(rl.RAYWHITE);

        rl.BeginMode3D(camera);
        rl.DrawGrid(10, 1.0);
        rl.EndMode3D();

        rl.DrawFPS(700, 10);
    }
}
```

All raylib types (Vector3, Color, Camera3D, etc.) and constants (RAYWHITE, CAMERA_PERSPECTIVE, etc.) are available through the `rl` namespace.

## Step 5: Build and Run

```bash
# First time only: build ANGLE (~10 min)
./scripts/build_angle.sh

# Build and run the app
zig build run
```

### Verifying it works

The raylib log output confirms the ANGLE Metal pipeline:

```
INFO: GLAD: OpenGL ES 2.0 loaded successfully
INFO: GL: OpenGL device information:
INFO:     > Vendor:   Google Inc. (Apple)
INFO:     > Renderer: ANGLE (Apple, ANGLE Metal Renderer: Apple M4, ...)
INFO:     > Version:  OpenGL ES 3.0 (ANGLE 2.1.27230 ...)
```

You can also verify the binary's dynamic library dependencies:

```bash
otool -L zig-out/bin/raylib_love | grep -E 'EGL|GLES'
# Should show:
#   @rpath/libEGL.dylib
#   @rpath/libGLESv2.dylib
```

If you see references to `OpenGL.framework` instead, something went wrong with the build configuration.

## How GLFW + EGL Works on macOS

This is the piece that makes the whole setup possible without patching raylib.

Raylib bundles GLFW, and on macOS, `rglfw.c` compiles **both** context backends:
- `nsgl_context.m` - the native macOS OpenGL context (used with desktop GL)
- `egl_context.c` - the EGL context (used with ANGLE)

GLFW selects between them at runtime based on a window hint. In raylib's `rcore_desktop_glfw.c`:

```c
if (rlGetVersion() == RL_OPENGL_ES_20) {
    glfwWindowHint(GLFW_CLIENT_API, GLFW_OPENGL_ES_API);
    glfwWindowHint(GLFW_CONTEXT_CREATION_API, GLFW_EGL_CONTEXT_API);
}
```

When `GRAPHICS_API_OPENGL_ES2` is defined (which our `.opengl_version = .gles_2` does), raylib tells GLFW to use EGL for context creation. GLFW then calls `eglGetDisplay`, `eglCreateContext`, etc. - and since our executable links ANGLE's `libEGL.dylib`, those calls go to ANGLE, which creates a Metal-backed context.

No patching required. The pieces just fit together.

## Reproducing for Other Projects

### Using a different Zig project with raylib + ANGLE

1. Copy `scripts/build_angle.sh` and `third_party/angle-out/` structure
2. Run the script once to build ANGLE
3. In your `build.zig.zon`, add the raylib dependency (same URL and hash)
4. In your `build.zig`:
   - Set `.opengl_version = .gles_2` on the raylib dependency
   - Link `EGL` and `GLESv2` with the ANGLE library path
   - Do NOT link `OpenGL.framework`
   - Add rpaths and copy the dylibs to the output directory
5. Set `.single_threaded = true` for macOS

### What is EGL?

To understand the two ANGLE dylibs, you need to understand the split between **context management** and **rendering commands** in the OpenGL ecosystem.

**OpenGL ES** (the "ES" stands for Embedded Systems) is the rendering API — it defines functions like `glDrawArrays`, `glCreateShader`, `glTexImage2D`, etc. These are the commands that actually draw things. This is what `libGLESv2.dylib` provides.

**EGL** (originally "Embedded-system Graphics Library") is the **platform interface layer** that sits between OpenGL ES and the native window system. It handles:

- **Display connection**: Connecting to the GPU / display server (`eglGetDisplay`)
- **Surface creation**: Creating a drawable surface tied to a native window (`eglCreateWindowSurface`)
- **Context creation**: Creating an OpenGL ES rendering context (`eglCreateContext`)
- **Making current**: Binding a context + surface pair so GL calls go to the right place (`eglMakeCurrent`)
- **Buffer swapping**: Presenting rendered frames to the screen (`eglSwapBuffers`)

Think of it this way:

```
EGL  = "give me a canvas to draw on"  (libEGL.dylib)
GLES = "draw things on that canvas"   (libGLESv2.dylib)
```

On desktop platforms, this role is traditionally filled by platform-specific APIs:
- **Windows**: WGL (Windows GL) — `wglCreateContext`, `wglMakeCurrent`
- **macOS**: NSGL / CGL — `NSOpenGLContext`, `CGLCreateContext`
- **Linux/X11**: GLX — `glXCreateContext`, `glXMakeCurrent`
- **Linux/Wayland**: EGL (Wayland adopted EGL as its native GL interface)

EGL was designed by Khronos (the same standards body behind OpenGL) as a **cross-platform replacement** for all of these. Instead of every platform having its own context API, EGL provides one API that works everywhere. It's the standard context API for OpenGL ES, and it's the only context API for OpenGL ES on desktop (since WGL/NSGL/GLX only know about desktop OpenGL, not OpenGL ES).

This is why ANGLE provides **two** libraries:

| Library | What it implements | Role |
|---|---|---|
| `libEGL.dylib` | The EGL 1.5 API | Creates contexts, manages surfaces, connects to the GPU (via Metal) |
| `libGLESv2.dylib` | The OpenGL ES 2.0/3.0 API | Receives draw calls, translates them to Metal commands |

When GLFW calls `eglCreateContext` (from `libEGL.dylib`), ANGLE internally creates a Metal device and command queue. When raylib later calls `glDrawArrays` (from `libGLESv2.dylib`), ANGLE translates that into Metal render encoder commands. When GLFW calls `eglSwapBuffers`, ANGLE presents the Metal drawable.

### Using ANGLE with a different renderer (not raylib)

Because EGL and OpenGL ES are Khronos standards with stable, well-defined ABIs, ANGLE's dylibs are drop-in replacements anywhere those APIs are expected. Any library that supports OpenGL ES 2.0 via EGL can use them:

- **SDL2**: Set `SDL_GL_CONTEXT_PROFILE_ES` and `SDL_GL_CONTEXT_EGL` before creating a window
- **GLFW** (standalone): Set `GLFW_CLIENT_API` to `GLFW_OPENGL_ES_API` and `GLFW_CONTEXT_CREATION_API` to `GLFW_EGL_CONTEXT_API`
- **Custom code**: Call `eglGetDisplay`, `eglInitialize`, `eglCreateContext`, etc. directly
- **Any C/C++ library**: Link `-lEGL -lGLESv2` and point the library path at your ANGLE dylibs

The key steps are always:
1. Build ANGLE with Metal backend
2. Fix install names with `install_name_tool -id @rpath/...`
3. Link your app against the ANGLE dylibs instead of the system OpenGL
4. Set rpaths so the dylibs are found at runtime

### Caching ANGLE builds

ANGLE builds are slow. For team/CI use:
- Cache `third_party/angle-out/` (just the two dylibs + headers, ~8 MB per platform)
- Pin the ANGLE commit in the build script for reproducibility
- Don't rebuild unless you need a newer ANGLE version

## Cross-Platform: Vulkan Everywhere, Metal on macOS

The build system is set up so your rendering code is always OpenGL ES 2.0, and ANGLE translates to the best native API per platform:

```
┌─────────────────────────────────────────────────┐
│            Your app (Zig + raylib)              │
│            OpenGL ES 2.0 via EGL                │
├─────────────────────────────────────────────────┤
│                    ANGLE                        │
├───────────┬───────────────┬─────────────────────┤
│  macOS    │   Windows     │      Linux          │
│  Metal    │   Vulkan      │      Vulkan         │
└───────────┴───────────────┴─────────────────────┘
```

### How the build system handles this

The `build.zig` auto-detects the target OS and:
- Looks for ANGLE libraries in `third_party/angle-out/<platform>/lib/`
- Links the correct platform-specific system libraries (Cocoa on macOS, gdi32 on Windows, X11 on Linux)
- Uses the right shared library extension (`.dylib`, `.dll`, `.so`)
- Sets platform-appropriate rpaths for runtime library resolution

The `scripts/build_angle.sh` script accepts a backend argument:

```bash
./scripts/build_angle.sh metal    # macOS (default on macOS)
./scripts/build_angle.sh vulkan   # Windows or Linux (default on both)
./scripts/build_angle.sh d3d11    # Windows alternative
```

It auto-detects the host OS and places output in the right platform directory.

### Directory structure with multiple platforms

```
third_party/angle-out/
  macos/
    lib/libEGL.dylib, libGLESv2.dylib
    include/EGL/, GLES2/, ...
  windows/
    lib/libEGL.dll, libGLESv2.dll, libEGL.dll.lib, libGLESv2.dll.lib
    include/EGL/, GLES2/, ...
  linux/
    lib/libEGL.so, libGLESv2.so
    include/EGL/, GLES2/, ...
```

### Building for each platform

You need to build ANGLE **on each target platform** (ANGLE uses GN/Ninja, not Zig, so it can't cross-compile through Zig). The workflow is:

**On your Mac (what you have now):**
```bash
./scripts/build_angle.sh metal
# produces third_party/angle-out/macos/lib/libEGL.dylib, libGLESv2.dylib
```

**On a Windows machine (or Windows CI):**
```bash
./scripts/build_angle.sh vulkan
# produces third_party/angle-out/windows/lib/libEGL.dll, libGLESv2.dll
```

**On a Linux machine (or Linux CI):**
```bash
./scripts/build_angle.sh vulkan
# produces third_party/angle-out/linux/lib/libEGL.so, libGLESv2.so
```

Once you have the ANGLE libraries for each platform, commit them (or cache them in CI), and then **Zig handles the rest**:

```bash
# Native build (uses the current platform's ANGLE libs)
zig build

# Cross-compile to Windows (uses third_party/angle-out/windows/)
zig build -Dtarget=x86_64-windows

# Cross-compile to Linux (uses third_party/angle-out/linux/)
zig build -Dtarget=x86_64-linux
```

### Why Vulkan on Windows instead of D3D11?

Either works. The tradeoffs:

| Backend | Pros | Cons |
|---|---|---|
| Vulkan | Same backend as Linux; Vulkan is actively developed; future-proof | Requires Vulkan runtime (most modern GPUs have it) |
| D3D11 | Most mature ANGLE backend (used in Chrome); works on all Windows 7+ machines | Windows-only; one more backend to maintain |

Vulkan is the default in our setup because it gives you the same backend on Windows and Linux — fewer things to think about. If you need maximum Windows compatibility (old hardware, Windows 7), switch to D3D11.

### What you can and can't cross-compile from macOS

| Task | From macOS? | Notes |
|---|---|---|
| Compile raylib + your Zig code for Windows | Yes | Zig cross-compiles C and Zig natively |
| Compile raylib + your Zig code for Linux | Yes | Same |
| Build ANGLE for Windows | No | Must build on Windows (GN/Ninja toolchain) |
| Build ANGLE for Linux | No | Must build on Linux |
| Link against pre-built ANGLE libs for other platforms | Yes | Just need the .dll/.so files present |

So the practical workflow is: build ANGLE once per platform (locally or in CI), cache the output libraries, and then cross-compile everything else from any machine with Zig.

## Upgrading Zig, Raylib, or ANGLE

The three components (Zig, raylib, ANGLE) are largely independent. Here's what changes when you upgrade each one.

### Upgrading Zig

ANGLE is **completely unaffected** — it's built with Chromium's clang toolchain, not Zig. Your `third_party/angle-out/` dylibs stay the same.

What you need to do:

1. **Check raylib compatibility.** Raylib's `build.zig` targets specific Zig versions. After upgrading Zig, try `zig build`. If it fails with errors inside raylib's cached `build.zig` (like `has no member 'init'` or unfamiliar type changes), you need a newer raylib pin.

2. **Update the raylib commit in `build.zig.zon`.** Find a raylib commit compatible with your new Zig version:
   ```bash
   # Search for Zig-compatibility commits in raylib
   curl -s "https://api.github.com/search/commits?q=repo:raysan5/raylib+zig&sort=committer-date&order=desc&per_page=5" \
     -H "Accept: application/vnd.github.cloak-preview+json" | python3 -c "
   import json, sys
   for item in json.load(sys.stdin).get('items', []):
       print(f\"{item['sha'][:12]}  {item['commit']['committer']['date']}  {item['commit']['message'].split(chr(10))[0]}\")
   "
   ```

3. **Update the URL and hash.** Replace the commit hash in the `.url` field, set `.hash` to any placeholder, run `zig build`, and copy the correct hash from the error message.

4. **Check for build.zig API changes.** Zig's `std.Build` API evolves between versions. Things that may need updating:
   - `LazyPath` union variants (e.g., `.special` was added in later versions)
   - `ArrayList` initialization API
   - `addExecutable` / `createModule` parameter structs
   - Framework/library linking function signatures

   These are compile errors in *your* `build.zig`, not raylib's. Fix them by checking the Zig standard library source at `$(zig env | grep lib_dir)/std/Build.zig`.

5. **Verify `.single_threaded` still exists.** This option has been stable, but check if the threading model changes in your target Zig version.

**Summary for Zig upgrades:**

| What | Changes? | Action |
|---|---|---|
| ANGLE dylibs | No | None |
| ANGLE build script | No | None |
| `build.zig.zon` (raylib pin) | Likely | Update commit hash + package hash |
| `build.zig` (build logic) | Maybe | Fix any `std.Build` API changes |
| `src/main.zig` (app code) | Rarely | Only if Zig language semantics change |

### Upgrading Raylib

ANGLE is **completely unaffected** — raylib and ANGLE only interact through the standard EGL/GLES2 ABI, which is stable.

What you need to do:

1. **Find the new commit.** Pick a raylib commit or tag that's compatible with your Zig version. Check the `minimum_zig_version` field in raylib's `build.zig.zon` at that commit.

2. **Update `build.zig.zon`:**
   ```zig
   .raylib = .{
       .url = "git+https://github.com/raysan5/raylib#<new-full-40-char-commit-hash>",
       .hash = "placeholder",
   },
   ```
   Run `zig build`, copy the correct hash from the error.

3. **Check if raylib's Options struct changed.** The fields passed to `b.dependency("raylib", .{ ... })` come from raylib's `Options` struct. If raylib renames or removes an option (e.g., if `.opengl_version` becomes `.graphics_api`), you'll get a compile error. Check raylib's `build.zig` at the new commit.

4. **Check framework linking.** Raylib occasionally changes which macOS frameworks it links internally. If you get undefined symbol errors at link time, compare the frameworks in your `build.zig` against what raylib's `build.zig` links for macOS in its `compileRaylib` function.

5. **Verify GLES2/EGL support still exists.** Raylib labels this as "experimental". Check that:
   - `rglfw.c` still includes `egl_context.c` on macOS
   - `rcore_desktop_glfw.c` still sets `GLFW_EGL_CONTEXT_API` for ES2
   - The `OpenglVersion` enum still has `.gles_2`

**Summary for raylib upgrades:**

| What | Changes? | Action |
|---|---|---|
| ANGLE dylibs | No | None |
| ANGLE build script | No | None |
| `build.zig.zon` | Yes | New URL + hash |
| `build.zig` | Maybe | Check Options struct, framework list |
| `src/main.zig` | Maybe | Only if raylib's C API changes |

### Upgrading ANGLE

Zig and raylib are **completely unaffected** — ANGLE's output is just two dylibs that expose the standard EGL/GLES2 interface.

What you need to do:

1. **Update ANGLE source and rebuild:**
   ```bash
   cd .angle-build
   git pull
   gclient sync
   ```
   Or delete `.angle-build/` entirely and re-run the script for a clean build.

2. **Check GN args compatibility.** ANGLE occasionally renames or removes GN flags. If `gn gen` fails, check `gni/angle.gni` in the ANGLE source for the current flag names. The most likely change is if a backend flag gets renamed or a new required flag is added.

3. **Re-run the build script:**
   ```bash
   ./scripts/build_angle.sh
   ```
   The script handles the `install_name_tool` fix automatically.

4. **Test.** Run `zig build run` and check the ANGLE version in the log output:
   ```
   > Renderer: ANGLE (Apple, ANGLE Metal Renderer: ...)
   > Version:  OpenGL ES 3.0 (ANGLE <new-version> ...)
   ```

**Summary for ANGLE upgrades:**

| What | Changes? | Action |
|---|---|---|
| `build_angle.sh` | Maybe | Check if GN arg names changed |
| `third_party/angle-out/` | Yes | Rebuilt by the script |
| `build.zig.zon` | No | None |
| `build.zig` | No | None |
| `src/main.zig` | No | None |

### Version Compatibility Matrix

The three components communicate through stable interfaces:

```
Zig  <---->  raylib    via: raylib's build.zig Options struct + Zig std.Build API
raylib <---->  ANGLE   via: EGL/GLES2 ABI (stable, standardized by Khronos)
Zig  <---->  ANGLE    via: dylib linking (standard macOS dynamic linking)
```

Because raylib↔ANGLE uses a standardized ABI, you can upgrade ANGLE without touching raylib, and vice versa. The only coupling that requires care is Zig↔raylib, because raylib's `build.zig` must match your Zig version's build API.

## Gotchas and Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Library not loaded: ./libEGL.dylib` | ANGLE dylibs have `./` install name | Run `install_name_tool -id @rpath/libEGL.dylib` on the dylib |
| `Metal Toolchain not found` during ANGLE build | Missing Xcode component | `xcodebuild -downloadComponent MetalToolchain` |
| `ref not found` in build.zig.zon | Short git hash | Use the full 40-character commit hash |
| `hash mismatch` in build.zig.zon | Wrong or placeholder hash | Copy the correct hash from the error message |
| `ArrayList has no member 'init'` | Raylib version incompatible with your Zig | Pin raylib to a commit that matches your Zig version |
| ZLS reports `raylib.h not found` | ZLS doesn't see build system include paths | This is cosmetic; `zig build` works fine |
| App links `OpenGL.framework` | Executable links the wrong library | Remove any `linkFramework("OpenGL", .{})` from build.zig |
| Window opens but is black/unresponsive | GLFW not on main thread | Set `.single_threaded = true` in module options |
