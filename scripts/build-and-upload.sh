#!/usr/bin/env bash
#
# Build the postgres_scanner extension for multiple platforms and upload to GCS.
#
# Auto-detects the host platform and builds natively when possible,
# falls back to Docker for Linux targets.
#
# Usage:
#   ./scripts/build-and-upload.sh              # build all + upload
#   ./scripts/build-and-upload.sh --no-upload  # build only
#   ./scripts/build-and-upload.sh osx_arm64    # build one platform + upload
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DUCKDB_VERSION="v1.5.2"
GCS_BUCKET="def-duckdb-extensions"
EXTENSION_NAME="postgres_scanner"
DOCKER_IMAGE_AMD64="quay.io/pypa/manylinux_2_28_x86_64"
DOCKER_IMAGE_ARM64="quay.io/pypa/manylinux_2_28_aarch64"

# vcpkg commit pinned in the project Makefile (tag 2025.12.12)
VCPKG_PIN="84bab45d415d22042bd0b9081aea57f362da3f35"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}[$(date +%H:%M:%S)] ✓${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] !${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✗${NC} $*"; }

# ---------------------------------------------------------------------------
# Detect host platform
# ---------------------------------------------------------------------------
detect_host_platform() {
    local os arch
    os="$(uname -s)"
    arch="$(uname -m)"

    case "$os" in
        Darwin)
            case "$arch" in
                arm64)  echo "osx_arm64" ;;
                x86_64) echo "osx_amd64" ;;
                *)      echo "unknown" ;;
            esac
            ;;
        Linux)
            case "$arch" in
                aarch64) echo "linux_arm64" ;;
                x86_64)  echo "linux_amd64" ;;
                *)       echo "unknown" ;;
            esac
            ;;
        *) echo "unknown" ;;
    esac
}

HOST_PLATFORM="$(detect_host_platform)"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DO_UPLOAD=true
UPLOAD_ONLY=false
VERBOSE=false
PLATFORMS=()

for arg in "$@"; do
    case "$arg" in
        --no-upload) DO_UPLOAD=false ;;
        --upload-only) UPLOAD_ONLY=true ;;
        --verbose|-v) VERBOSE=true ;;
        --help|-h)
            echo "Usage: $0 [--no-upload] [--upload-only] [--verbose|-v] [platform ...]"
            echo ""
            echo "Platforms: osx_arm64  osx_amd64  linux_amd64  linux_arm64"
            echo "If no platform is specified, all four are built."
            echo ""
            echo "Options:"
            echo "  --verbose, -v   Show full build output (default: progress lines only)"
            echo "  --no-upload     Build only, don't upload to GCS"
            echo "  --upload-only   Skip building, upload existing dist/ artifacts to GCS"
            echo "  JOBS=N          Override parallel job count for native builds (default: auto-detect)"
            echo ""
            echo "Environment:"
            echo "  VCPKG_ROOT or VCPKG_TOOLCHAIN_PATH   Required for native builds"
            echo "  DOCKER_MAKE_JOBS   make -j inside Docker (default: 4 or JOBS if set)"
            echo ""
            echo "Host detected: $HOST_PLATFORM"
            exit 0
            ;;
        *) PLATFORMS+=("$arg") ;;
    esac
done

if [ ${#PLATFORMS[@]} -eq 0 ]; then
    case "$HOST_PLATFORM" in
        osx_arm64|osx_amd64)
            PLATFORMS=(osx_arm64 osx_amd64 linux_amd64 linux_arm64) ;;
        linux_amd64|linux_arm64)
            PLATFORMS=(linux_amd64 linux_arm64) ;;
        *)
            PLATFORMS=(linux_amd64 linux_arm64) ;;
    esac
    log "Auto-selected platforms for $HOST_PLATFORM host"
fi

# ---------------------------------------------------------------------------
# Output directory
# ---------------------------------------------------------------------------
OUTPUT_DIR="$PROJECT_DIR/dist/$DUCKDB_VERSION"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
nproc_portable() {
    if [ -n "${JOBS:-}" ]; then
        echo "$JOBS"
    elif command -v nproc &>/dev/null; then
        nproc
    elif command -v sysctl &>/dev/null; then
        sysctl -n hw.ncpu
    else
        echo 4
    fi
}

build_filter() {
    if $VERBOSE; then
        cat
    else
        grep --line-buffered -E '^\[[ 0-9]{3}%\]|error:|Error |vcpkg install|Installing |===|Building CXX|Linking ' || true
    fi
}

compress_extension() {
    local src="$1"
    local dst="$2"
    if [ -f "$src" ]; then
        gzip -c "$src" > "$dst"
        ok "Compressed: $dst ($(du -h "$dst" | cut -f1))"
    else
        err "Extension not found: $src"
        return 1
    fi
}

ensure_vcpkg() {
    if [ -z "${VCPKG_TOOLCHAIN_PATH:-}" ]; then
        if [ -n "${VCPKG_ROOT:-}" ]; then
            export VCPKG_TOOLCHAIN_PATH="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake"
        elif [ -f "$PROJECT_DIR/vcpkg/scripts/buildsystems/vcpkg.cmake" ]; then
            export VCPKG_TOOLCHAIN_PATH="$PROJECT_DIR/vcpkg/scripts/buildsystems/vcpkg.cmake"
            log "Using bundled vcpkg at $VCPKG_TOOLCHAIN_PATH"
        else
            log "vcpkg not found — bootstrapping into $PROJECT_DIR/vcpkg (commit $VCPKG_PIN)"
            rm -rf "$PROJECT_DIR/vcpkg"
            mkdir -p "$PROJECT_DIR/vcpkg"
            git -C "$PROJECT_DIR/vcpkg" init -q
            git -C "$PROJECT_DIR/vcpkg" remote add origin https://github.com/microsoft/vcpkg.git
            git -C "$PROJECT_DIR/vcpkg" fetch --depth 1 origin "$VCPKG_PIN"
            git -C "$PROJECT_DIR/vcpkg" checkout -q FETCH_HEAD
            "$PROJECT_DIR/vcpkg/bootstrap-vcpkg.sh" -disableMetrics > /dev/null
            export VCPKG_TOOLCHAIN_PATH="$PROJECT_DIR/vcpkg/scripts/buildsystems/vcpkg.cmake"
            ok "vcpkg bootstrapped at $VCPKG_TOOLCHAIN_PATH"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Native build (runs directly on the host)
# ---------------------------------------------------------------------------
build_native() {
    local target_platform="$1"
    log "Building $target_platform (native)..."

    cd "$PROJECT_DIR"
    rm -rf build/release
    ensure_vcpkg || return 1

    local make_env=""
    if [ "$HOST_PLATFORM" = "osx_arm64" ] && [ "$target_platform" = "osx_amd64" ]; then
        log "Cross-compiling: arm64 host -> x86_64 target"
        make_env="OSX_BUILD_ARCH=x86_64 VCPKG_TARGET_TRIPLET=x64-osx-release VCPKG_HOST_TRIPLET=arm64-osx-release"
    elif [ "$HOST_PLATFORM" = "osx_amd64" ] && [ "$target_platform" = "osx_arm64" ]; then
        log "Cross-compiling: x86_64 host -> arm64 target"
        make_env="OSX_BUILD_ARCH=arm64 VCPKG_TARGET_TRIPLET=arm64-osx-release VCPKG_HOST_TRIPLET=x64-osx-release"
    fi

    eval "VCPKG_TOOLCHAIN_PATH='$VCPKG_TOOLCHAIN_PATH' $make_env make GEN=ninja -j$(nproc_portable)" 2>&1 | build_filter

    local ext="build/release/extension/$EXTENSION_NAME/$EXTENSION_NAME.duckdb_extension"
    mkdir -p "$OUTPUT_DIR/$target_platform"
    compress_extension "$ext" "$OUTPUT_DIR/$target_platform/$EXTENSION_NAME.duckdb_extension.gz"
    # Also publish under the `postgres` alias so consumers can do
    # `INSTALL postgres FROM <repo>` without renaming, matching how core
    # DuckDB autoloads this extension.
    cp "$OUTPUT_DIR/$target_platform/$EXTENSION_NAME.duckdb_extension.gz" \
       "$OUTPUT_DIR/$target_platform/postgres.duckdb_extension.gz"
}

# ---------------------------------------------------------------------------
# Docker build (for Linux targets)
# ---------------------------------------------------------------------------
build_docker() {
    local target_platform="$1"

    local docker_platform docker_image
    case "$target_platform" in
        linux_amd64) docker_platform="linux/amd64"; docker_image="$DOCKER_IMAGE_AMD64" ;;
        linux_arm64) docker_platform="linux/arm64"; docker_image="$DOCKER_IMAGE_ARM64" ;;
        *) err "Docker builds only support linux targets, got: $target_platform"; return 1 ;;
    esac

    log "Building $target_platform (Docker $docker_platform on $docker_image)..."

    if ! command -v docker &>/dev/null; then
        err "Docker is required for $target_platform builds. Install Docker Desktop."
        return 1
    fi

    cd "$PROJECT_DIR"

    local docker_make_jobs="${DOCKER_MAKE_JOBS:-${JOBS:-4}}"
    log "Docker make parallelism: ${docker_make_jobs} (DOCKER_MAKE_JOBS or JOBS to override)"

    local host_artifact_dir="$OUTPUT_DIR/$target_platform"
    mkdir -p "$host_artifact_dir"

    docker run --rm \
        --platform "$docker_platform" \
        -v "$PROJECT_DIR:/src:ro" \
        -v "$host_artifact_dir:/artifact" \
        -e VCPKG_PIN="${VCPKG_PIN}" \
        -e DOCKER_MAKE_JOBS="${docker_make_jobs}" \
        -e EXTENSION_NAME="${EXTENSION_NAME}" \
        "$docker_image" \
        bash -c "
            set -e

            echo \"=== Installing libpq/openssl build prerequisites ===\"
            # bison + flex are required by the project's overlay libpq port
            # (vcpkg_ports/libpq); ninja-build / perl-IPC-Cmd / perl-core are
            # required by openssl + the libpq build itself; rsync is used
            # below to copy /src -> /build.
            yum install -y -q ninja-build perl-IPC-Cmd perl-core bison flex \
                zip unzip tar pkgconfig curl rsync > /dev/null

            echo \"=== Verifying toolchain ===\"
            cmake --version | head -1
            ninja --version
            perl -e 'use IPC::Cmd; print \"perl IPC::Cmd OK\\n\"'

            echo \"=== Setting up vcpkg (commit \$VCPKG_PIN) ===\"
            rm -rf /opt/vcpkg
            mkdir -p /opt/vcpkg
            git -C /opt/vcpkg init
            git -C /opt/vcpkg remote add origin https://github.com/microsoft/vcpkg.git
            git -C /opt/vcpkg fetch --depth 1 origin \"\$VCPKG_PIN\"
            git -C /opt/vcpkg checkout -q FETCH_HEAD
            /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics > /dev/null 2>&1

            echo \"=== Copying source into container fs (avoids macOS bind-mount depfile bug) ===\"
            mkdir -p /build
            rsync -a --delete \
                --exclude=build/ --exclude=dist/ --exclude=vcpkg/ --exclude=.git/ \
                /src/ /build/

            echo \"=== Building ===\"
            cd /build
            export VCPKG_TOOLCHAIN_PATH=/opt/vcpkg/scripts/buildsystems/vcpkg.cmake
            export VCPKG_MAX_CONCURRENCY=\"\${VCPKG_MAX_CONCURRENCY:-4}\"
            export CMAKE_BUILD_PARALLEL_LEVEL=\"\${DOCKER_MAKE_JOBS}\"
            make GEN=ninja -j\"\${DOCKER_MAKE_JOBS}\"

            echo \"=== Exporting extension to host artifact dir ===\"
            cp \"build/release/extension/\${EXTENSION_NAME}/\${EXTENSION_NAME}.duckdb_extension\" /artifact/
            ls -la /artifact/
        " 2>&1 | build_filter

    local ext="$host_artifact_dir/$EXTENSION_NAME.duckdb_extension"
    compress_extension "$ext" "$host_artifact_dir/$EXTENSION_NAME.duckdb_extension.gz"
    rm -f "$ext"
    cp "$host_artifact_dir/$EXTENSION_NAME.duckdb_extension.gz" \
       "$host_artifact_dir/postgres.duckdb_extension.gz"
}

# ---------------------------------------------------------------------------
# Decide how to build a given platform
# ---------------------------------------------------------------------------
build_platform() {
    local target="$1"

    case "$target" in
        osx_arm64|osx_amd64)
            if [[ "$HOST_PLATFORM" == osx_* ]]; then
                build_native "$target"
            else
                err "$target requires a macOS host (detected: $HOST_PLATFORM). Skipping."
                return 1
            fi
            ;;
        linux_amd64|linux_arm64)
            if [ "$HOST_PLATFORM" = "$target" ]; then
                build_native "$target"
            else
                build_docker "$target"
            fi
            ;;
        *)
            err "Unknown platform: $target"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Upload to GCS
# ---------------------------------------------------------------------------
upload_to_gcs() {
    log "Uploading to gs://$GCS_BUCKET/..."

    if ! command -v gcloud &>/dev/null; then
        err "gcloud is required for upload. Install Google Cloud SDK."
        return 1
    fi

    echo ""
    log "Repository structure:"
    find "$OUTPUT_DIR" -name "*.gz" -type f | sort | while read -r f; do
        echo "  $(echo "$f" | sed "s|$PROJECT_DIR/dist/||") ($(du -h "$f" | cut -f1))"
    done
    echo ""

    gcloud storage rsync -r --exclude='\.DS_Store$|\.keep$' "$PROJECT_DIR/dist/" "gs://$GCS_BUCKET/"
    gcloud storage buckets add-iam-policy-binding "gs://$GCS_BUCKET" --member=allUsers --role=roles/storage.objectViewer

    ok "Upload complete!"
    echo ""
    log "Install in DuckDB with:"
    echo "  SET custom_extension_repository='https://storage.googleapis.com/$GCS_BUCKET';"
    echo "  INSTALL postgres;"
    echo "  LOAD postgres;"
    echo ""
    log "Or, by the upstream binary name:"
    echo "  INSTALL $EXTENSION_NAME;"
    echo "  LOAD $EXTENSION_NAME;"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo ""
log "postgres_scanner Extension Builder"
log "DuckDB version: $DUCKDB_VERSION"
log "Host platform:  $HOST_PLATFORM"
log "Upload only:    $UPLOAD_ONLY"
if ! $UPLOAD_ONLY; then
    log "Platforms:      ${PLATFORMS[*]}"
fi
log "Upload:         $DO_UPLOAD"
echo ""

if $UPLOAD_ONLY; then
    upload_to_gcs
    exit 0
fi

FAILED=()

for platform in "${PLATFORMS[@]}"; do
    build_platform "$platform" || FAILED+=("$platform")
    echo ""
done

# Summary
echo ""
log "Build summary:"
for platform in "${PLATFORMS[@]}"; do
    local_dir="$OUTPUT_DIR/$platform"
    if [ -f "$local_dir/$EXTENSION_NAME.duckdb_extension.gz" ]; then
        ok "$platform"
    else
        err "$platform (FAILED)"
    fi
done

if [ ${#FAILED[@]} -gt 0 ]; then
    echo ""
    warn "Failed platforms: ${FAILED[*]}"
fi

if $DO_UPLOAD; then
    echo ""
    upload_to_gcs
fi
