#!/usr/bin/env bash
#
# Build ANGLE with Metal backend only (macOS).
#
# Usage:
#   ./scripts/build_angle_metal.sh                     # output to third_party/angle-out/
#   ./scripts/build_angle_metal.sh /custom/output       # custom output dir
#   ANGLE_JOBS=4 ./scripts/build_angle_metal.sh         # limit parallelism
#
# Prerequisites:
#   - Xcode (or Command Line Tools) installed
#   - Python 3 in PATH
#   - ~15 GB disk for ANGLE source + build
#   - ~10 min build time on Apple Silicon

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Output directory for the final dylibs + headers
OUTPUT_DIR="${1:-$PROJECT_ROOT/third_party/angle-out}"

# Working directory for ANGLE source + build
ANGLE_WORK_DIR="$PROJECT_ROOT/.angle-build"

# Optional: override job count
ANGLE_JOBS="${ANGLE_JOBS:-}"

echo "=== ANGLE Metal Build ==="
echo "Output:  $OUTPUT_DIR"
echo "Workdir: $ANGLE_WORK_DIR"
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
# `fetch angle` checks out directly into the current directory (not a subdirectory)
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
# Step 3: Configure GN — Metal only, release, static linking
# -------------------------------------------------------
BUILD_DIR="$ANGLE_SRC_DIR/out/Release"

echo ">>> Configuring GN args (Metal-only release build)..."
mkdir -p "$BUILD_DIR"

cat > "$BUILD_DIR/args.gn" << 'GN_ARGS'
# Metal-only release build for macOS
is_debug = false
is_component_build = false

# Enable Metal backend
angle_enable_metal = true

# Disable all other backends
angle_enable_d3d9  = false
angle_enable_d3d11 = false
angle_enable_gl    = false
angle_enable_vulkan = false
angle_enable_null  = false
angle_enable_swiftshader = false

# GLSL translator needed by Metal shader pipeline
angle_enable_essl = false
angle_enable_glsl = true
GN_ARGS

gn gen "$BUILD_DIR"

# -------------------------------------------------------
# Step 4: Build libEGL and libGLESv2
# -------------------------------------------------------
echo ">>> Building ANGLE (libEGL + libGLESv2)..."

NINJA_ARGS="-C $BUILD_DIR libEGL libGLESv2"
if [ -n "$ANGLE_JOBS" ]; then
    NINJA_ARGS="-j $ANGLE_JOBS $NINJA_ARGS"
fi

autoninja $NINJA_ARGS

# -------------------------------------------------------
# Step 5: Copy outputs
# -------------------------------------------------------
echo ">>> Copying dylibs and headers to $OUTPUT_DIR..."

mkdir -p "$OUTPUT_DIR/lib"
mkdir -p "$OUTPUT_DIR/include"

# Copy dylibs
cp "$BUILD_DIR/libEGL.dylib" "$OUTPUT_DIR/lib/"
cp "$BUILD_DIR/libGLESv2.dylib" "$OUTPUT_DIR/lib/"

# Fix install names: ANGLE builds with ./libX.dylib, change to @rpath/libX.dylib
# so the executable's rpath settings work at runtime
install_name_tool -id @rpath/libEGL.dylib "$OUTPUT_DIR/lib/libEGL.dylib"
install_name_tool -id @rpath/libGLESv2.dylib "$OUTPUT_DIR/lib/libGLESv2.dylib"

# Copy EGL and GLES headers from ANGLE source
if [ -d "$ANGLE_SRC_DIR/include/EGL" ]; then
    cp -R "$ANGLE_SRC_DIR/include/EGL" "$OUTPUT_DIR/include/"
fi
if [ -d "$ANGLE_SRC_DIR/include/GLES2" ]; then
    cp -R "$ANGLE_SRC_DIR/include/GLES2" "$OUTPUT_DIR/include/"
fi
if [ -d "$ANGLE_SRC_DIR/include/GLES3" ]; then
    cp -R "$ANGLE_SRC_DIR/include/GLES3" "$OUTPUT_DIR/include/"
fi
if [ -d "$ANGLE_SRC_DIR/include/KHR" ]; then
    cp -R "$ANGLE_SRC_DIR/include/KHR" "$OUTPUT_DIR/include/"
fi

echo ""
echo "=== Done! ==="
echo ""
echo "Output files:"
ls -lh "$OUTPUT_DIR/lib/"*.dylib
echo ""
echo "Headers:"
ls -d "$OUTPUT_DIR/include"/*/ 2>/dev/null || echo "  (none copied)"
echo ""
echo "Next steps:"
echo "  1. cd $PROJECT_ROOT"
echo "  2. zig build"
echo "  3. zig build run"
echo ""
echo "Verify ANGLE linkage:"
echo "  otool -L zig-out/bin/raylib_love | grep -E 'EGL|GLES'"
