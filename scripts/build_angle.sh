#!/usr/bin/env bash
#
# Build ANGLE with a specific backend.
#
# Usage:
#   ./scripts/build_angle.sh metal           # macOS: Metal backend (default on macOS)
#   ./scripts/build_angle.sh vulkan          # Windows/Linux: Vulkan backend
#   ./scripts/build_angle.sh d3d11           # Windows: Direct3D 11 backend
#
#   ANGLE_JOBS=4 ./scripts/build_angle.sh metal   # limit parallelism
#   ./scripts/build_angle.sh --local metal        # project-local only (no shared)
#
# By default, the build cache lives at ~/.cache/angle-build/ and output
# is installed to ~/.local/share/angle/<platform>/ (shared across projects).
# A copy is also placed in the project's third_party/angle-out/<platform>/.
#
# Use --local to keep everything inside the project directory instead.
#
# Prerequisites:
#   - Python 3 in PATH
#   - ~15 GB disk for ANGLE source + build
#   - macOS: Xcode + Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)
#   - Windows: Visual Studio 2022 with C++ workload
#   - Linux: build-essential, libx11-dev, libvulkan-dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -------------------------------------------------------
# Parse flags
# -------------------------------------------------------
LOCAL_MODE=false
BACKEND=""

for arg in "$@"; do
    case "$arg" in
        --local) LOCAL_MODE=true ;;
        *)       BACKEND="$arg" ;;
    esac
done

# -------------------------------------------------------
# Detect OS and backend
# -------------------------------------------------------
UNAME="$(uname -s)"
case "$UNAME" in
    Darwin)  HOST_OS="macos"   ;;
    Linux)   HOST_OS="linux"   ;;
    MINGW*|MSYS*|CYGWIN*) HOST_OS="windows" ;;
    *)       echo "Unsupported OS: $UNAME"; exit 1 ;;
esac

# Backend: first argument, or auto-detect from OS
if [ -z "$BACKEND" ]; then
    case "$HOST_OS" in
        macos)   BACKEND="metal"  ;;
        windows) BACKEND="vulkan" ;;
        linux)   BACKEND="vulkan" ;;
    esac
fi

# Validate backend
case "$BACKEND" in
    metal|vulkan|d3d11) ;;
    *) echo "Unknown backend: $BACKEND (use: metal, vulkan, d3d11)"; exit 1 ;;
esac

# Directories depend on --local mode
if [ "$LOCAL_MODE" = true ]; then
    # Project-local only (old behavior)
    ANGLE_WORK_DIR="$PROJECT_ROOT/.angle-build"
    SHARED_OUTPUT_DIR=""
    PROJECT_OUTPUT_DIR="$PROJECT_ROOT/third_party/angle-out/$HOST_OS"
else
    # Shared system-wide (default)
    ANGLE_WORK_DIR="$HOME/.cache/angle-build"
    SHARED_OUTPUT_DIR="$HOME/.local/share/angle/$HOST_OS"
    PROJECT_OUTPUT_DIR="$PROJECT_ROOT/third_party/angle-out/$HOST_OS"
fi

# Optional: override job count
ANGLE_JOBS="${ANGLE_JOBS:-}"

echo "=== ANGLE Build ==="
echo "Backend: $BACKEND"
echo "Host OS: $HOST_OS"
echo "Workdir: $ANGLE_WORK_DIR"
if [ -n "$SHARED_OUTPUT_DIR" ]; then
    echo "Shared:  $SHARED_OUTPUT_DIR"
fi
echo "Project: $PROJECT_OUTPUT_DIR"
echo ""

# -------------------------------------------------------
# Step 1: Install depot_tools
# -------------------------------------------------------
DEPOT_TOOLS_DIR="$ANGLE_WORK_DIR/depot_tools"

if [ ! -d "$DEPOT_TOOLS_DIR" ]; then
    echo ">>> Cloning depot_tools..."
    mkdir -p "$ANGLE_WORK_DIR"
    git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS_DIR"
else
    echo ">>> depot_tools already present, updating..."
    git -C "$DEPOT_TOOLS_DIR" pull --ff-only || true
fi

export PATH="$DEPOT_TOOLS_DIR:$PATH"

# -------------------------------------------------------
# Step 2: Fetch ANGLE source
# -------------------------------------------------------
# `fetch angle` checks out directly into the current directory
ANGLE_SRC_DIR="$ANGLE_WORK_DIR"

if [ ! -f "$ANGLE_SRC_DIR/.gclient" ]; then
    echo ">>> Fetching ANGLE (this takes a while on first run)..."
    mkdir -p "$ANGLE_SRC_DIR"
    cd "$ANGLE_SRC_DIR"
    fetch angle
else
    echo ">>> ANGLE source exists, syncing..."
    cd "$ANGLE_SRC_DIR"
    gclient sync
fi

# -------------------------------------------------------
# Step 3: Configure GN args for the chosen backend
# -------------------------------------------------------
BUILD_DIR="$ANGLE_SRC_DIR/out/Release-$BACKEND"

echo ">>> Configuring GN args ($BACKEND backend, release build)..."
mkdir -p "$BUILD_DIR"

# Common args: release, self-contained libraries, disable unused backends
cat > "$BUILD_DIR/args.gn" << GN_ARGS
# ANGLE $BACKEND backend — release build
is_debug = false
is_component_build = false

# GLSL translator (needed by all backends for shader compilation)
angle_enable_glsl = true
angle_enable_essl = false

# Disable all backends, then enable just the one we want
angle_enable_metal       = false
angle_enable_vulkan      = false
angle_enable_d3d9        = false
angle_enable_d3d11       = false
angle_enable_gl          = false
angle_enable_null        = false
angle_enable_swiftshader = false

# Enable the selected backend
$(case "$BACKEND" in
    metal)  echo "angle_enable_metal  = true" ;;
    vulkan) echo "angle_enable_vulkan = true" ;;
    d3d11)  echo "angle_enable_d3d11  = true" ;;
esac)
GN_ARGS

gn gen "$BUILD_DIR"

# -------------------------------------------------------
# Step 4: Build libEGL and libGLESv2
# -------------------------------------------------------
echo ">>> Building ANGLE (libEGL + libGLESv2) with $BACKEND backend..."

NINJA_ARGS="-C $BUILD_DIR libEGL libGLESv2"
if [ -n "$ANGLE_JOBS" ]; then
    NINJA_ARGS="-j $ANGLE_JOBS $NINJA_ARGS"
fi

autoninja $NINJA_ARGS

# -------------------------------------------------------
# Step 5: Copy outputs
# -------------------------------------------------------

# Determine shared library extension
case "$HOST_OS" in
    macos)   LIB_EXT="dylib" ;;
    windows) LIB_EXT="dll"   ;;
    linux)   LIB_EXT="so"    ;;
esac

# Helper: copy ANGLE libs + headers into a target directory and fix install names
copy_angle_output() {
    local dest="$1"
    echo ">>> Copying libraries and headers to $dest..."

    mkdir -p "$dest/lib"
    mkdir -p "$dest/include"

    cp "$BUILD_DIR/libEGL.$LIB_EXT"    "$dest/lib/"
    cp "$BUILD_DIR/libGLESv2.$LIB_EXT" "$dest/lib/"

    # macOS: fix install names (ANGLE builds with ./ prefix, change to @rpath/)
    if [ "$HOST_OS" = "macos" ]; then
        install_name_tool -id @rpath/libEGL.dylib    "$dest/lib/libEGL.dylib"
        install_name_tool -id @rpath/libGLESv2.dylib "$dest/lib/libGLESv2.dylib"
    fi

    # Windows: also copy import libraries if present
    if [ "$HOST_OS" = "windows" ]; then
        [ -f "$BUILD_DIR/libEGL.dll.lib" ]    && cp "$BUILD_DIR/libEGL.dll.lib"    "$dest/lib/"
        [ -f "$BUILD_DIR/libGLESv2.dll.lib" ] && cp "$BUILD_DIR/libGLESv2.dll.lib" "$dest/lib/"
    fi

    # Copy EGL and GLES headers from ANGLE source
    for dir in EGL GLES2 GLES3 KHR; do
        if [ -d "$ANGLE_SRC_DIR/include/$dir" ]; then
            cp -R "$ANGLE_SRC_DIR/include/$dir" "$dest/include/"
        fi
    done
}

# Copy to shared system location (if not --local)
if [ -n "$SHARED_OUTPUT_DIR" ]; then
    copy_angle_output "$SHARED_OUTPUT_DIR"
fi

# Always copy to project-local directory
copy_angle_output "$PROJECT_OUTPUT_DIR"

echo ""
echo "=== Done! ==="
echo ""
echo "Backend: $BACKEND"
if [ -n "$SHARED_OUTPUT_DIR" ]; then
    echo ""
    echo "Shared (all projects):"
    ls -lh "$SHARED_OUTPUT_DIR/lib/"* 2>/dev/null || echo "  (none)"
fi
echo ""
echo "Project-local:"
ls -lh "$PROJECT_OUTPUT_DIR/lib/"* 2>/dev/null || echo "  (none)"
echo ""
echo "Headers:"
ls -d "$PROJECT_OUTPUT_DIR/include"/*/ 2>/dev/null || echo "  (none copied)"
echo ""
if [ -n "$SHARED_OUTPUT_DIR" ]; then
    echo "Other projects can find the shared libs at:"
    echo "  $SHARED_OUTPUT_DIR"
    echo ""
fi
echo "Next steps:"
echo "  cd $PROJECT_ROOT"
echo "  zig build        # native build"
echo "  zig build run    # build and run"
