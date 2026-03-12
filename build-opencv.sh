#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenCV Slim Build Script
# Runs inside a debian:trixie container on arm64
#
# Modifications from stock Debian package:
#   - WITH_FFMPEG=OFF   (replaced by GStreamer)
#   - WITH_CAROTENE=ON  (ARM NEON HAL optimizations)
#   - WITH_VTK=OFF      (heavy dep, not needed)
#   - Adds GStreamer plugin Recommends for IP camera support
# ============================================================

OPENCV_SOURCE_PKG="opencv"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
mkdir -p "$OUTPUT_DIR"

echo "=== System information ==="
uname -a
cat /etc/os-release
echo "CPUs: $(nproc)"
echo ""

# ----------------------------------------------------------
# Step 1: Enable deb-src in apt sources
# ----------------------------------------------------------
echo "=== Enabling deb-src ==="
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update

# ----------------------------------------------------------
# Step 2: Install build tooling
# ----------------------------------------------------------
echo "=== Installing build tooling ==="
apt-get install -y --no-install-recommends \
    dpkg-dev \
    devscripts \
    fakeroot \
    equivs

# ----------------------------------------------------------
# Step 3: Fetch OpenCV source package
# ----------------------------------------------------------
echo "=== Fetching OpenCV source ==="
mkdir -p /build
cd /build
apt-get source "$OPENCV_SOURCE_PKG"

# Find the extracted source directory
SRCDIR=$(find /build -maxdepth 1 -type d -name "opencv-*" | head -1)
if [ -z "$SRCDIR" ]; then
    echo "ERROR: Could not find extracted source directory"
    ls -la /build/
    exit 1
fi
echo "Source directory: $SRCDIR"

# ----------------------------------------------------------
# Step 4: Install build dependencies
# ----------------------------------------------------------
echo "=== Installing build dependencies ==="
apt-get build-dep -y "$OPENCV_SOURCE_PKG"

# ----------------------------------------------------------
# Step 5: Patch debian/rules — modify CMAKE_FLAGS
# ----------------------------------------------------------
echo "=== Patching debian/rules ==="
cd "$SRCDIR"

RULES_FILE="debian/rules"

echo "--- Current flag values (before patching) ---"
grep -n 'WITH_FFMPEG\|WITH_CAROTENE\|WITH_VTK\|WITH_GSTREAMER\|WITH_V4L\|WITH_OPENCL' "$RULES_FILE" || true
echo ""

# Disable FFMPEG (replaced by GStreamer)
sed -i 's/-DWITH_FFMPEG=ON/-DWITH_FFMPEG=OFF/' "$RULES_FILE"

# Enable Carotene ARM NEON HAL
if grep -q '\-DWITH_CAROTENE=OFF' "$RULES_FILE"; then
    sed -i 's/-DWITH_CAROTENE=OFF/-DWITH_CAROTENE=ON/' "$RULES_FILE"
elif ! grep -q '\-DWITH_CAROTENE' "$RULES_FILE"; then
    # Flag not present at all — add it to CMAKE_FLAGS
    sed -i '/CMAKE_FLAGS +=.*-DWITH_GSTREAMER/s/$/ \\\n\t-DWITH_CAROTENE=ON/' "$RULES_FILE"
fi

# Disable VTK (heavy, not needed)
sed -i 's/-DWITH_VTK=ON/-DWITH_VTK=OFF/' "$RULES_FILE"

# Disable DNN module (using external inference framework instead)
if grep -q '\-DBUILD_opencv_dnn=ON' "$RULES_FILE"; then
    sed -i 's/-DBUILD_opencv_dnn=ON/-DBUILD_opencv_dnn=OFF/' "$RULES_FILE"
elif ! grep -q '\-DBUILD_opencv_dnn' "$RULES_FILE"; then
    sed -i '/CMAKE_FLAGS +=.*-DBUILD_opencv_face/s/$/ \\\n\t-DBUILD_opencv_dnn=OFF/' "$RULES_FILE"
fi

echo "--- Flag values after patching ---"
grep -n 'WITH_FFMPEG\|WITH_CAROTENE\|WITH_VTK\|WITH_GSTREAMER\|WITH_V4L\|WITH_OPENCL\|BUILD_opencv_dnn' "$RULES_FILE" || true
echo ""

# Verify critical flags
grep -q '\-DWITH_FFMPEG=OFF' "$RULES_FILE" || { echo "FATAL: FFMPEG not set to OFF"; exit 1; }
grep -q '\-DWITH_CAROTENE=ON' "$RULES_FILE" || { echo "FATAL: CAROTENE not set to ON"; exit 1; }
grep -q '\-DWITH_VTK=OFF' "$RULES_FILE" || { echo "FATAL: VTK not set to OFF"; exit 1; }
grep -q '\-DWITH_GSTREAMER=ON' "$RULES_FILE" || { echo "FATAL: GSTREAMER not ON"; exit 1; }
echo "All patches verified."

# ----------------------------------------------------------
# Step 6: Patch debian/control
# ----------------------------------------------------------
echo "=== Patching debian/control ==="

CONTROL_FILE="debian/control"

# 6a. Add GStreamer runtime plugin recommendations to libopencv-videoio package
if grep -q 'Package: libopencv-videoio' "$CONTROL_FILE"; then
    sed -i '/^Package: libopencv-videoio[0-9]*/,/^$/{
        /^Depends:/a Recommends: gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad
    }' "$CONTROL_FILE"
    echo "Added GStreamer plugin Recommends to videoio package"
else
    echo "WARNING: Could not find libopencv-videoio package in control file"
fi

# 6b. python3-opencv: ${shlibs:Depends} is kept — it auto-detects the
#     minimal set of libopencv-* packages that cv2.so actually links
#     against. Since FFMPEG/VTK are disabled at the CMake level, their
#     runtime libs won't appear here. The result is a headless-style
#     dependency set (core, imgproc, imgcodecs, videoio, dnn, etc.).
echo "--- python3-opencv Depends (auto-detected, headless) ---"
sed -n '/^Package: python3-opencv$/,/^$/{/^Depends:/p}' "$CONTROL_FILE"

# ----------------------------------------------------------
# Step 7: Update changelog
# ----------------------------------------------------------
echo "=== Updating changelog ==="
export DEBEMAIL="opencv-slim@localhost"
export DEBFULLNAME="OpenCV Slim Builder"
dch --local "~slim" "Slim build: FFMPEG=OFF, CAROTENE=ON, VTK=OFF. GStreamer is the primary video I/O backend."

head -5 debian/changelog
echo ""

# ----------------------------------------------------------
# Step 8: Build binary packages
# ----------------------------------------------------------
echo "=== Starting build ==="
export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
echo "DEB_BUILD_OPTIONS=$DEB_BUILD_OPTIONS"
echo "Build started at: $(date -u)"

dpkg-buildpackage -us -uc -b

echo "Build finished at: $(date -u)"

# ----------------------------------------------------------
# Step 9: Collect output
# ----------------------------------------------------------
echo "=== Collecting build artifacts ==="
cp /build/*.deb "$OUTPUT_DIR/" 2>/dev/null || true
cp /build/*.buildinfo "$OUTPUT_DIR/" 2>/dev/null || true
cp /build/*.changes "$OUTPUT_DIR/" 2>/dev/null || true

# Try to extract build configuration info
# The CMake build directory name depends on the host architecture
DEB_HOST_MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "aarch64-linux-gnu")
for build_dir in "$SRCDIR/obj-${DEB_HOST_MULTIARCH}" "$SRCDIR/obj-"*; do
    if [ -d "$build_dir" ]; then
        # Look for the CMake cache to extract build info
        if [ -f "$build_dir/CMakeCache.txt" ]; then
            echo "=== CMake configuration summary ===" > "$OUTPUT_DIR/build-info.txt"
            grep -E 'WITH_FFMPEG|WITH_GSTREAMER|WITH_CAROTENE|WITH_VTK|WITH_OPENCL|WITH_V4L|WITH_TBB|WITH_EIGEN|WITH_LAPACK|CPU_BASELINE|CPU_DISPATCH|ENABLE_NEON|CAROTENE' \
                "$build_dir/CMakeCache.txt" >> "$OUTPUT_DIR/build-info.txt" 2>/dev/null || true
            echo "" >> "$OUTPUT_DIR/build-info.txt"
        fi
        # Also capture the version_string.inc if available
        if [ -f "$build_dir/modules/core/version_string.inc" ]; then
            echo "=== OpenCV Build Information ===" >> "$OUTPUT_DIR/build-info.txt"
            cat "$build_dir/modules/core/version_string.inc" >> "$OUTPUT_DIR/build-info.txt"
        fi
        break
    fi
done

echo ""
echo "=== Built packages ==="
ls -lh "$OUTPUT_DIR"/*.deb 2>/dev/null || echo "WARNING: No .deb files found in $OUTPUT_DIR"
echo ""
echo "=== Done ==="
