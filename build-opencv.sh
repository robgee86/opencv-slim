#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# OpenCV Slim Build Script
# Runs inside a debian:trixie container on arm64
#
# All debian/rules modifications are in debian-slim.patch.
# This script fetches the source, restores carotene from
# upstream, applies the patch, and builds.
# ============================================================

OPENCV_SOURCE_PKG="opencv"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
PATCH_FILE="${PATCH_FILE:-/workspace/debian-slim.patch}"
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
    equivs \
    wget \
    patch

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
# Step 4: Restore carotene HAL (stripped from the +dfsg tarball)
# ----------------------------------------------------------
echo "=== Restoring carotene from upstream ==="
OPENCV_VERSION=$(basename "$SRCDIR" | sed 's/opencv-\([0-9.]*\).*/\1/')
echo "OpenCV version: $OPENCV_VERSION"

UPSTREAM_URL="https://github.com/opencv/opencv/archive/refs/tags/${OPENCV_VERSION}.tar.gz"
echo "Fetching $UPSTREAM_URL ..."
wget -q -O /tmp/opencv-upstream.tar.gz "$UPSTREAM_URL"

mkdir -p /tmp/carotene-src
tar xzf /tmp/opencv-upstream.tar.gz \
    -C /tmp/carotene-src \
    --strip-components=1 \
    "opencv-${OPENCV_VERSION}/3rdparty/carotene"
rm /tmp/opencv-upstream.tar.gz

# debian/rules copies debian/3rdparty-<ver> -> 3rdparty/ during configure,
# so we must inject carotene into the staging directory.
for staging_dir in "$SRCDIR"/debian/3rdparty-*; do
    if [ -d "$staging_dir" ]; then
        cp -a /tmp/carotene-src/3rdparty/carotene "$staging_dir/carotene"
        echo "Injected carotene into $(basename "$staging_dir")"
    fi
done
rm -rf /tmp/carotene-src

# Verify
for staging_dir in "$SRCDIR"/debian/3rdparty-*; do
    if [ -d "$staging_dir/carotene/hal" ]; then
        echo "Carotene HAL restored successfully in $(basename "$staging_dir")"
    else
        echo "FATAL: carotene/hal not found in $(basename "$staging_dir")"
        exit 1
    fi
done

# ----------------------------------------------------------
# Step 5: Install build dependencies
# ----------------------------------------------------------
echo "=== Installing build dependencies ==="
apt-get build-dep -y "$OPENCV_SOURCE_PKG"

# ----------------------------------------------------------
# Step 6: Apply debian-slim.patch
# ----------------------------------------------------------
echo "=== Applying debian-slim.patch ==="
cd "$SRCDIR"
patch -p1 < "$PATCH_FILE"

# Verify critical flags
echo "--- Patched flag values ---"
grep -n 'WITH_FFMPEG\|WITH_CAROTENE\|WITH_VTK\|WITH_GSTREAMER\|WITH_OPENCL\|BUILD_opencv_dnn' debian/rules || true
echo ""

# ----------------------------------------------------------
# Step 7: Patch debian/control (GStreamer Recommends)
# ----------------------------------------------------------
echo "=== Patching debian/control ==="
# Insert Recommends before Description in the runtime videoio package only.
# Must use [0-9]\+ (one-or-more) and $ anchor to avoid matching -dev package.
if grep -q '^Package: libopencv-videoio[0-9]' debian/control; then
    sed -i '/^Package: libopencv-videoio[0-9]\+$/,/^$/{
        /^Description:/i Recommends: gstreamer1.0-plugins-good, gstreamer1.0-plugins-bad
    }' debian/control
    echo "Added GStreamer plugin Recommends to videoio package"
fi

# ----------------------------------------------------------
# Step 8: Update changelog
# ----------------------------------------------------------
echo "=== Updating changelog ==="
export DEBEMAIL="opencv-slim@localhost"
export DEBFULLNAME="OpenCV Slim Builder"
dch --local "~slim" \
    "Slim build: FFMPEG=OFF, CAROTENE=ON, VTK=OFF, DNN=OFF. GStreamer is the primary video I/O backend."

head -5 debian/changelog
echo ""

# ----------------------------------------------------------
# Step 9: Build binary packages
# ----------------------------------------------------------
echo "=== Starting build ==="
export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
echo "DEB_BUILD_OPTIONS=$DEB_BUILD_OPTIONS"
echo "Build started at: $(date -u)"

dpkg-buildpackage -us -uc -b

echo "Build finished at: $(date -u)"

# ----------------------------------------------------------
# Step 10: Collect output
# ----------------------------------------------------------
echo "=== Collecting build artifacts ==="
cp /build/*.deb "$OUTPUT_DIR/" 2>/dev/null || true
cp /build/*.buildinfo "$OUTPUT_DIR/" 2>/dev/null || true
cp /build/*.changes "$OUTPUT_DIR/" 2>/dev/null || true

# Capture build configuration info
DEB_HOST_MULTIARCH=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo "aarch64-linux-gnu")
for build_dir in "$SRCDIR/obj-${DEB_HOST_MULTIARCH}" "$SRCDIR/obj-"*; do
    if [ -d "$build_dir" ]; then
        if [ -f "$build_dir/CMakeCache.txt" ]; then
            echo "=== CMake configuration summary ===" > "$OUTPUT_DIR/build-info.txt"
            grep -E 'WITH_FFMPEG|WITH_GSTREAMER|WITH_CAROTENE|WITH_VTK|WITH_OPENCL|WITH_V4L|WITH_TBB|WITH_EIGEN|WITH_LAPACK|CPU_BASELINE|CPU_DISPATCH|ENABLE_NEON|CAROTENE' \
                "$build_dir/CMakeCache.txt" >> "$OUTPUT_DIR/build-info.txt" 2>/dev/null || true
            echo "" >> "$OUTPUT_DIR/build-info.txt"
        fi
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
