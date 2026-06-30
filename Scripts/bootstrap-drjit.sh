#!/usr/bin/env bash
# bootstrap-drjit.sh
#
# Builds drjit-core (Metal backend only), then stages headers + a
# multi-platform STATIC XCFramework into vendor/.
#
# Source selection:
#   1. DRJIT_SRC, when set
#   2. /Volumes/GitHubDeveloper/GitHub/mitsuba-renderer/drjit
#   3. ../DrJit, for compatibility with the original layout
#
# Static library xcframework: no embedding required, no rpath issues.
#
# Prerequisites:
#   git, cmake, xcodebuild, libtool, lipo
#   Xcode with macOS and visionOS SDKs installed
#
# Usage:
#   cd Packages/DrJitCore
#   make bootstrap          # or bash Scripts/bootstrap-drjit.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANONICAL_DRJIT_SRC="/Volumes/GitHubDeveloper/GitHub/mitsuba-renderer/drjit"
LEGACY_DRJIT_SRC="${ROOT_DIR}/../DrJit"
BUILD_ROOT="${ROOT_DIR}/.build/drjit-bootstrap"
INCLUDE_DIR="${ROOT_DIR}/vendor/drjit-include"
XCFRAMEWORK_PATH="${ROOT_DIR}/vendor/DrJitBinary.xcframework"

resolve_drjit_src() {
    local candidates=()
    if [[ -n "${DRJIT_SRC:-}" ]]; then
        candidates+=("${DRJIT_SRC}")
    fi
    candidates+=("${CANONICAL_DRJIT_SRC}" "${LEGACY_DRJIT_SRC}")

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -f "${candidate}/ext/drjit-core/include/drjit-core/jit.h" ]]; then
            (cd "${candidate}" && pwd -P)
            return 0
        fi
    done

    echo "DrJit source not found." >&2
    echo "Set DRJIT_SRC=/path/to/drjit, or clone it with:" >&2
    echo "  git clone --recursive https://github.com/mitsuba-renderer/drjit ${CANONICAL_DRJIT_SRC}" >&2
    return 1
}

DRJIT_SRC="$(resolve_drjit_src)"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required tool: $1" >&2; exit 1
    fi
}
require_tool git
require_tool cmake
require_tool xcodebuild
require_tool libtool

# ── Validate source ────────────────────────────────────────────────────────────
echo "Using DrJit source: ${DRJIT_SRC}"

# ── Prepare a patched build copy ──────────────────────────────────────────────
# drjit-core CMakeLists has:
#   add_library(
#     drjit-core SHARED
# We patch "drjit-core SHARED" → "drjit-core STATIC" on line 2 of that block.
# Using perl for reliable multi-token in-place replace.
PATCHED_SRC="${BUILD_ROOT}/drjit-src"
mkdir -p "${BUILD_ROOT}"
rm -rf "${PATCHED_SRC}"
echo "Copying DrJit source to build dir..."
mkdir -p "${PATCHED_SRC}"
cp -R "${DRJIT_SRC}/." "${PATCHED_SRC}/"

CORE_CMAKE="${PATCHED_SRC}/ext/drjit-core/CMakeLists.txt"
perl -i -p -e 's/drjit-core SHARED/drjit-core STATIC/g' "${CORE_CMAKE}"
# Verify the patch took
if grep -q "drjit-core SHARED" "${CORE_CMAKE}"; then
    echo "ERROR: SHARED→STATIC patch did not apply to ${CORE_CMAKE}" >&2
    exit 1
fi
echo "Patched drjit-core SHARED → STATIC"

# nanothread has a macOS-only deployment target check that fires on visionOS
# simulator because __MAC_OS_X_VERSION_MIN_REQUIRED is defined there too.
NANOTHREAD_CPP="${PATCHED_SRC}/ext/drjit-core/ext/nanothread/src/nanothread.cpp"
perl -i -p -e 's/#  if __MAC_OS_X_VERSION_MIN_REQUIRED < 110000/#  if !defined(__XROS_VERSION_MIN_REQUIRED) \&\& __MAC_OS_X_VERSION_MIN_REQUIRED < 110000/g' \
    "${NANOTHREAD_CPP}"
echo "Patched nanothread visionOS deployment check"

# ── Common CMake flags ─────────────────────────────────────────────────────────
COMMON_CMAKE_ARGS=(
    -G Xcode
    -DDRJIT_ENABLE_METAL=ON
    -DDRJIT_ENABLE_LLVM=OFF
    -DDRJIT_ENABLE_CUDA=OFF
    -DDRJIT_ENABLE_PYTHON=OFF
    -DDRJIT_ENABLE_TESTS=OFF
    -DBUILD_SHARED_LIBS=OFF
    -DNANOTHREAD_STATIC=ON
    # Disable LTO: produces LLVM bitcode objects that xcodebuild -create-xcframework
    # cannot read architecture information from (Unknown header: 0x0b17c0de).
    # CMAKE_XCODE_ATTRIBUTE_* sets Xcode project build settings directly — the
    # only reliable way with the Xcode generator (CMake-level flags are overridden).
    -DCMAKE_INTERPROCEDURAL_OPTIMIZATION=OFF
    -DCMAKE_XCODE_ATTRIBUTE_LLVM_LTO=NO
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=NO
)

MACOS_DEPLOY="14.0"
XROS_DEPLOY="1.0"

# ── Build per platform ─────────────────────────────────────────────────────────
build_variant() {
    local name="$1"
    local sysroot="$2"
    local system_name="$3"
    local archs="$4"
    local deploy_flag="${5:-}"
    local extra_cxxflags="${6:-}"
    local build_dir="${BUILD_ROOT}/${name}"

    local -a args=(
        "${COMMON_CMAKE_ARGS[@]}"
        -S "${PATCHED_SRC}"
        -B "${build_dir}"
        -DCMAKE_OSX_ARCHITECTURES="${archs}"
    )
    [[ -n "${sysroot}" ]]        && args+=(-DCMAKE_OSX_SYSROOT="${sysroot}")
    [[ -n "${system_name}" ]]    && args+=(-DCMAKE_SYSTEM_NAME="${system_name}")
    [[ -n "${deploy_flag}" ]]    && args+=("${deploy_flag}")
    [[ -n "${extra_cxxflags}" ]] && args+=("-DCMAKE_CXX_FLAGS=${extra_cxxflags}")

    echo "Configuring ${name}..."
    cmake "${args[@]}"
    echo "Building ${name}..."
    cmake --build "${build_dir}" --config Release --target drjit-core nanothread \
        -- CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" LLVM_LTO=NO
}

rm -rf "${XCFRAMEWORK_PATH}"
rm -rf "${BUILD_ROOT}/macosx" "${BUILD_ROOT}/xrsimulator-arm64" "${BUILD_ROOT}/xros"

XROS_CXXFLAGS="-D__MAC_OS_X_VERSION_MIN_REQUIRED=110000"

build_variant "macosx"            "macosx"      ""         "arm64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_DEPLOY}"
build_variant "xrsimulator-arm64" "xrsimulator" "visionOS" "arm64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${XROS_DEPLOY}" "${XROS_CXXFLAGS}"
build_variant "xros"              "xros"        "visionOS" "arm64" "-DCMAKE_OSX_DEPLOYMENT_TARGET=${XROS_DEPLOY}" "${XROS_CXXFLAGS}"

# ── Locate built static libraries ─────────────────────────────────────────────
find_lib() {
    local build_dir="$1"
    local libname="$2"
    local path
    path="$(find "${build_dir}" -path '*Release*' -name "${libname}" | sort | head -n1)"
    if [[ -z "${path}" ]]; then
        path="$(find "${build_dir}" -name "${libname}" | sort | head -n1)"
    fi
    printf '%s\n' "${path}"
}

# Stage headers
rm -rf "${INCLUDE_DIR}"
mkdir -p "${INCLUDE_DIR}/drjit-core"
mkdir -p "${INCLUDE_DIR}/drjit"
mkdir -p "${INCLUDE_DIR}/nanothread"
cp -R "${PATCHED_SRC}/ext/drjit-core/include/drjit-core/." "${INCLUDE_DIR}/drjit-core/"
cp -R "${PATCHED_SRC}/include/drjit/."                     "${INCLUDE_DIR}/drjit/"
cp -R "${PATCHED_SRC}/ext/drjit-core/ext/nanothread/include/nanothread/." \
      "${INCLUDE_DIR}/nanothread/"
echo "Headers staged to ${INCLUDE_DIR}"

# Merge drjit-core.a + nanothread.a into a single fat static library per platform.
# (nanothread symbols are not included in drjit-core.a when built STATIC.)
MERGED_DIR="${BUILD_ROOT}/merged"
rm -rf "${MERGED_DIR}"

merge_platform() {
    local name="$1"        # e.g. macosx
    local build_dir="${BUILD_ROOT}/${name}"
    local out_dir="${MERGED_DIR}/${name}"
    mkdir -p "${out_dir}"

    local drjit_a nanothread_a
    drjit_a="$(find_lib "${build_dir}" "libdrjit-core.a")"
    if [[ -z "${drjit_a}" ]]; then
        echo "Could not find libdrjit-core.a in ${build_dir}" >&2; exit 1
    fi
    nanothread_a="$(find_lib "${build_dir}" "libnanothread.a")"
    echo "  drjit-core.a  : ${drjit_a}" >&2
    echo "  nanothread.a  : ${nanothread_a:-<not found, skipping>}" >&2

    local merged="${out_dir}/DrJitBinary.a"
    if [[ -n "${nanothread_a}" ]]; then
        libtool -static -o "${merged}" "${drjit_a}" "${nanothread_a}"
    else
        cp "${drjit_a}" "${merged}"
    fi
    printf '%s\n' "${merged}"
}

echo "Merging static libraries..."
MACOS_A="$(merge_platform "macosx")"
XRSIM_A="$(merge_platform "xrsimulator-arm64")"
XROS_A="$(merge_platform  "xros")"

# ── Build XCFramework manually ────────────────────────────────────────────────
# xcodebuild -create-xcframework validates architecture info from the .a, which
# fails when the archives contain LLVM LTO bitcode objects (Unknown header:
# 0x0b17c0de).  We bypass it by constructing the xcframework directory structure
# directly — SPM binaryTarget only reads Info.plist and copies the library;
# it does not validate the object format.
mkdir -p "${XCFRAMEWORK_PATH}"

stage_slice() {
    local lib="$1"
    local slice_dir="${XCFRAMEWORK_PATH}/$2"
    mkdir -p "${slice_dir}/Headers"
    cp "${lib}" "${slice_dir}/DrJitBinary.a"
    cp -R "${INCLUDE_DIR}/." "${slice_dir}/Headers/"
}

stage_slice "${MACOS_A}" "macos-arm64"
stage_slice "${XRSIM_A}" "xros-arm64-simulator"
stage_slice "${XROS_A}"  "xros-arm64"

# Info.plist — describes each platform slice so SPM/Xcode pick the right one.
cat > "${XCFRAMEWORK_PATH}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key>        <string>macos-arm64</string>
            <key>LibraryPath</key>              <string>DrJitBinary.a</string>
            <key>HeadersPath</key>              <string>Headers</string>
            <key>SupportedArchitectures</key>
            <array><string>arm64</string></array>
            <key>SupportedPlatform</key>        <string>macos</string>
        </dict>
        <dict>
            <key>LibraryIdentifier</key>        <string>xros-arm64-simulator</string>
            <key>LibraryPath</key>              <string>DrJitBinary.a</string>
            <key>HeadersPath</key>              <string>Headers</string>
            <key>SupportedArchitectures</key>
            <array><string>arm64</string></array>
            <key>SupportedPlatform</key>        <string>xros</string>
            <key>SupportedPlatformVariant</key> <string>simulator</string>
        </dict>
        <dict>
            <key>LibraryIdentifier</key>        <string>xros-arm64</string>
            <key>LibraryPath</key>              <string>DrJitBinary.a</string>
            <key>HeadersPath</key>              <string>Headers</string>
            <key>SupportedArchitectures</key>
            <array><string>arm64</string></array>
            <key>SupportedPlatform</key>        <string>xros</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>      <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key> <string>1.0</string>
</dict>
</plist>
PLIST

echo ""
echo "DrJitCore bootstrap complete:"
echo "  headers:      ${INCLUDE_DIR}"
echo "  xcframework:  ${XCFRAMEWORK_PATH}"
