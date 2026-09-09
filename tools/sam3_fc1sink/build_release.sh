#!/usr/bin/env bash
# Build and package the gfx1151 SAM3 FC1-sink MIGraphX prefix.
#
# This intentionally uses MIGraphX's normal rbuild/cget dependency flow. The
# rocMLIR dependency in requirements.txt must point at the published fork
# commit containing align_sink_final.patch. ONNX Runtime is not built here.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_COMMIT=9f1a138e77f4738d82a065d225836b3b337950ce
BASE_SHORT=9f1a138
ROCMLIR_BASE_COMMIT=c35e77b199d2492e8e0f92b3f5ed762700d9334a
ROCMLIR_RELEASE_COMMIT=f3404d59b581fdf9d8cd7c1be9aeeb267851af93
RELEASE_TAG=v2.17.0+sam3-fc1sink.20260908.1
ROCM_VERSION="${ROCM_VERSION:-7.14}"
GPU_ARCH="${GPU_ARCH:-gfx1151}"
PYTHON_ABI=cp312
JOBS="${JOBS:-$(nproc)}"
BUILD_ROOT="${BUILD_ROOT:-${HOME}/.cache/migraphx-sam3-fc1sink}"
DEPS_DIR="${DEPS_DIR:-}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT}/dist}"
PATCH_FILE="${ROOT}/tools/sam3_fc1sink/align_sink_final.patch"
SOURCE_CHECK="${ROOT}/tools/sam3_fc1sink/check_rocmlir_patch.sh"
THIRD_PARTY_NOTICES="${ROOT}/tools/sam3_fc1sink/THIRD-PARTY-NOTICES"
LICENSE_DIR="${ROOT}/tools/sam3_fc1sink/licenses"
LICENSE_SUMS="${LICENSE_DIR}/SHA256SUMS"
PATCH_SHA256=00de576a486dc6dc1a89d1c5ae2e15273317069413bf8911f810430f0cc79f88
ARCHIVE_STEM="migraphx-2.17.0-dev-${BASE_SHORT}-sam3-fc1sink-rocm${ROCM_VERSION}-\
${GPU_ARCH}-${PYTHON_ABI}"
PACKAGE_ONLY=""
RESUME=0
CHECK_ONLY=0
ALLOW_UNTAGGED_TEST=0

usage()
{
    cat <<'EOF'
Usage: tools/sam3_fc1sink/build_release.sh [options]

Build MIGraphX and its pinned patched rocMLIR dependency with the standard
rbuild/cget flow, then create a deterministic binary-prefix archive.
ONNX Runtime is not built or packaged.

Options:
  --build-root DIR       Out-of-tree dependency/build/install root.
  --output-dir DIR       Destination for the tarball and SHA256 sidecar.
  --package-only PREFIX  Package an existing CMake install prefix; skip build.
  --resume               Reuse a non-empty build root.
  --check                Validate source pins and prerequisites without writing.
  --allow-untagged-test  Permit a pre-tag test artifact with a -pretag suffix.
  -h, --help             Show this help.

Environment overrides: JOBS (defaults to nproc), ROCM_VERSION, GPU_ARCH,
BUILD_ROOT, DEPS_DIR, OUTPUT_DIR, and ROCMLIR_SOURCE. Python is fixed to the
CPython 3.12 ABI. Point ROCMLIR_SOURCE at a local rocMLIR checkout for an
offline source check.
EOF
}

die()
{
    printf 'sam3-fc1sink release: %s\n' "$*" >&2
    exit 2
}

require_command()
{
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --build-root)
            [[ $# -ge 2 ]] || die '--build-root requires a value'
            BUILD_ROOT="$2"
            shift 2
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || die '--output-dir requires a value'
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --package-only)
            [[ $# -ge 2 ]] || die '--package-only requires a value'
            PACKAGE_ONLY="$2"
            shift 2
            ;;
        --resume)
            RESUME=1
            shift
            ;;
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --allow-untagged-test)
            ALLOW_UNTAGGED_TEST=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
done

[[ "${JOBS}" =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer'
[[ "${GPU_ARCH}" =~ ^gfx[0-9a-f]+$ ]] || die 'GPU_ARCH must be a gfx target'
[[ "${ROCM_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]] || die 'ROCM_VERSION must be major.minor'
[[ "${PYTHON_ABI}" =~ ^cp[0-9]+$ ]] || die 'PYTHON_ABI must look like cp312'

for command in awk cp find git grep gzip mkdir mktemp mv nproc python3 readelf \
               readlink sha256sum tar; do
    require_command "${command}"
done
if [[ -z "${PACKAGE_ONLY}" ]]; then
    require_command cmake
fi
if [[ -z "${PACKAGE_ONLY}" && -z "${DEPS_DIR}" ]]; then
    require_command rbuild
fi

[[ -f "${PATCH_FILE}" ]] || die "missing patch: ${PATCH_FILE}"
[[ -f "${THIRD_PARTY_NOTICES}" ]] || \
    die "missing third-party notices: ${THIRD_PARTY_NOTICES}"
[[ -f "${LICENSE_SUMS}" ]] || die "missing third-party license manifest: ${LICENSE_SUMS}"
(cd "${LICENSE_DIR}" && sha256sum --check --strict SHA256SUMS)
actual_patch_sha="$(sha256sum "${PATCH_FILE}")"
actual_patch_sha="${actual_patch_sha%% *}"
[[ "${actual_patch_sha}" == "${PATCH_SHA256}" ]] || die 'FC1-sink patch SHA256 mismatch'

mgx_head="$(git -C "${ROOT}" rev-parse HEAD)"
mgx_tree="$(git -C "${ROOT}" rev-parse HEAD^{tree})"
git -C "${ROOT}" merge-base --is-ancestor "${BASE_COMMIT}" HEAD || \
    die "source is not based on ${BASE_COMMIT}"

for rejected in c3d4d38edbc84ad930b9a2a08650456cc99b8c06 \
                e58acef6f8fa6a1e0a6497a346c79784bb778cdc; do
    if git -C "${ROOT}" merge-base --is-ancestor "${rejected}" HEAD 2>/dev/null; then
        die "rejected legacy patch is present in release ancestry: ${rejected}"
    fi
done

if [[ -n "$(git -C "${ROOT}" status --porcelain --untracked-files=all)" ]]; then
    die 'source checkout must be clean'
fi

tag_object_type="$(git -C "${ROOT}" cat-file -t "refs/tags/${RELEASE_TAG}" 2>/dev/null || true)"
tag_commit="$(git -C "${ROOT}" rev-parse --verify "refs/tags/${RELEASE_TAG}^{commit}" 2>/dev/null || true)"
pretag_mode=false
if [[ "${tag_object_type}" != tag || "${tag_commit}" != "${mgx_head}" ]]; then
    [[ "${ALLOW_UNTAGGED_TEST}" == 1 ]] || \
        die "HEAD must be pointed to by annotated tag ${RELEASE_TAG}"
    pretag_mode=true
fi
if "${pretag_mode}"; then
    ARCHIVE_NAME="${ARCHIVE_STEM}-pretag.tar.gz"
else
    ARCHIVE_NAME="${ARCHIVE_STEM}.tar.gz"
fi

rocmlir_spec="$(awk '$1 ~ /rocMLIR@/ {print $1}' "${ROOT}/requirements.txt")"
[[ -n "${rocmlir_spec}" ]] || die 'requirements.txt has no rocMLIR dependency'
rocmlir_repo="${rocmlir_spec%@*}"
rocmlir_commit="${rocmlir_spec##*@}"
[[ "${rocmlir_repo}" == "harrysocool/rocMLIR" ]] || \
    die 'rocMLIR dependency must use the harrysocool/rocMLIR release fork'
[[ "${rocmlir_commit}" == "${ROCMLIR_RELEASE_COMMIT}" ]] || \
    die "requirements.txt must pin ${rocmlir_repo}@${ROCMLIR_RELEASE_COMMIT}"

[[ -x "${SOURCE_CHECK}" ]] || die "missing source checker: ${SOURCE_CHECK}"
"${SOURCE_CHECK}"

temp_paths=()
cleanup()
{
    local path
    for path in "${temp_paths[@]}"; do
        [[ -z "${path}" ]] || rm -rf -- "${path}"
    done
}
trap cleanup EXIT

python_version="$(python3 -c 'import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}")')"
[[ "${python_version}" == "${PYTHON_ABI}" ]] || \
    die "Python ABI mismatch: requested ${PYTHON_ABI}, running ${python_version}"

printf '%s\n' \
    "MIGraphX source: ${mgx_head}" \
    "MIGraphX tree:   ${mgx_tree}" \
    "Release tag:     ${RELEASE_TAG} (pretag test: ${pretag_mode})" \
    "rocMLIR source:  ${rocmlir_repo}@${rocmlir_commit}" \
    "ROCm/GPU/Python: ${ROCM_VERSION} / ${GPU_ARCH} / ${PYTHON_ABI}" \
    "Parallel jobs:   ${JOBS}" \
    "Build root:      ${BUILD_ROOT}" \
    "Output:          ${OUTPUT_DIR}/${ARCHIVE_NAME}"

if [[ "${CHECK_ONLY}" == 1 ]]; then
    printf 'Preflight OK; no build or package was written.\n'
    exit 0
fi

if [[ -z "${PACKAGE_ONLY}" ]]; then
    if [[ -d "${BUILD_ROOT}" && "${RESUME}" != 1 ]] &&
       [[ -n "$(find "${BUILD_ROOT}" -mindepth 1 -print -quit)" ]]; then
        die "build root is not empty; use a new path or pass --resume: ${BUILD_ROOT}"
    fi
    mkdir -p "${BUILD_ROOT}"
    build_dir="${BUILD_ROOT}/build"
    install_prefix="${BUILD_ROOT}/install"

    export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS}"
    export CGET_JOBS="${JOBS}"
    if [[ -z "${DEPS_DIR}" ]]; then
        rbuild build \
            -d "${BUILD_ROOT}/depend" \
            -S "${ROOT}" \
            -B "${build_dir}" \
            -s develop \
            -G Ninja \
            --cc /opt/rocm/llvm/bin/clang \
            --cxx /opt/rocm/llvm/bin/clang++ \
            -T install \
            -DBUILD_DEV=OFF \
            -DBUILD_TESTING=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
            -DBUILD_SHARED_LIBS=ON \
            -DMIGRAPHX_ENABLE_MLIR=ON \
            -DMIGRAPHX_ENABLE_CPU=OFF \
            -DMIGRAPHX_ENABLE_PYTHON=ON \
            -DMIGRAPHX_USE_HIPBLASLT=ON \
            -DGPU_TARGETS="${GPU_ARCH}"
    else
        rock_compiler="${DEPS_DIR}/lib/librockCompiler.a"
        [[ -f "${DEPS_DIR}/hash" ]] || \
            die "prepared cget dependency hash is missing: ${DEPS_DIR}/hash"
        [[ -f "${rock_compiler}" ]] || \
            die "prepared rocMLIR archive is missing: ${rock_compiler}"
        grep -aFq ROCMLIR_SINK_FINAL_ERF "${rock_compiler}" || \
            die 'prepared rocMLIR archive does not contain the FC1-sink gate'
        cmake -S "${ROOT}" -B "${build_dir}" -G Ninja \
            -DBUILD_DEV=OFF \
            -DBUILD_TESTING=OFF \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_C_COMPILER=/opt/rocm/llvm/bin/clang \
            -DCMAKE_CXX_COMPILER=/opt/rocm/llvm/bin/clang++ \
            -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
            -DCMAKE_PREFIX_PATH="${DEPS_DIR};/opt/rocm" \
            -DBUILD_SHARED_LIBS=ON \
            -DMIGRAPHX_ENABLE_MLIR=ON \
            -DMIGRAPHX_ENABLE_CPU=OFF \
            -DMIGRAPHX_ENABLE_PYTHON=ON \
            -DMIGRAPHX_USE_HIPBLASLT=ON \
            -DGPU_TARGETS="${GPU_ARCH}"
        cmake --build "${build_dir}" --target install --parallel "${JOBS}"
    fi
else
    install_prefix="$(readlink -f -- "${PACKAGE_ONLY}")"
fi

gpu_lib="${install_prefix}/lib/migraphx/lib/libmigraphx_gpu.so.2017000.0"
python_module="${install_prefix}/lib/migraphx.cpython-312-x86_64-linux-gnu.so"
[[ -f "${gpu_lib}" ]] || die "MIGraphX GPU library is missing: ${gpu_lib}"
[[ -f "${python_module}" ]] || die "CPython 3.12 module is missing: ${python_module}"
grep -aFq ROCMLIR_SINK_FINAL_ERF "${gpu_lib}" || \
    die 'libmigraphx_gpu does not contain the FC1-sink environment gate'
if readelf -d "${gpu_lib}" | grep -E 'RPATH|RUNPATH' | grep -Eq '/tmp|/work|/build'; then
    die 'installed libmigraphx_gpu contains a build-directory RPATH'
fi

mkdir -p "${OUTPUT_DIR}"
archive="${OUTPUT_DIR}/${ARCHIVE_NAME}"
sidecar="${archive}.sha256"
[[ ! -e "${archive}" && ! -e "${sidecar}" ]] || \
    die "refusing to replace an existing release artifact: ${archive}"

staging="$(mktemp -d "${TMPDIR:-/tmp}/migraphx-sam3-fc1sink.XXXXXXXX")"
temp_paths+=("${staging}")
mkdir -p "${staging}/migraphx"
cp -a "${install_prefix}/." "${staging}/migraphx/"

doc_root="${staging}/migraphx/share/doc"
mkdir -p "${doc_root}/amdrocm-migraphx" "${doc_root}/rocmlir" \
         "${doc_root}/sam3-rocmlir" "${doc_root}/third-party"
cp "${ROOT}/LICENSE" "${doc_root}/amdrocm-migraphx/LICENSE"
cp "${LICENSE_DIR}/rocmlir-LLVM-LICENSE" "${doc_root}/rocmlir/LICENSE"
cp "${PATCH_FILE}" "${doc_root}/sam3-rocmlir/align_sink_final.patch"
cp "${THIRD_PARTY_NOTICES}" "${doc_root}/THIRD-PARTY-NOTICES"
cp "${LICENSE_DIR}/"* "${doc_root}/third-party/"

gpu_sha="$(sha256sum "${gpu_lib}")"
gpu_sha="${gpu_sha%% *}"
cat >"${doc_root}/sam3-rocmlir/NOTICE.txt" <<EOF
SAM3 MIGraphX 2.17 binary package

MIGraphX release branch commit: ${mgx_head}
MIGraphX upstream base: ${BASE_COMMIT}
rocMLIR fork source: ${rocmlir_repo}@${rocmlir_commit}
Target: ROCm ${ROCM_VERSION} / ${GPU_ARCH} / ${PYTHON_ABI} / Linux x86-64

The packaged libmigraphx_gpu contains the environment-gated
ROCMLIR_SINK_FINAL_ERF transformation used while compiling the SAM3 detector
backbone. The transformation is inactive when the variable is unset. The
exact source patch is included beside this notice.

Patch SHA256: ${PATCH_SHA256}
libmigraphx_gpu.so.2017000.0 SHA256: ${gpu_sha}
EOF

export MANIFEST_ROOT="${staging}/migraphx"
export MANIFEST_MGX_COMMIT="${mgx_head}"
export MANIFEST_MGX_TREE="${mgx_tree}"
export MANIFEST_MGX_BASE="${BASE_COMMIT}"
export MANIFEST_RELEASE_TAG="${RELEASE_TAG}"
export MANIFEST_PRETAG_MODE="${pretag_mode}"
export MANIFEST_ROCMLIR_REPO="${rocmlir_repo}"
export MANIFEST_ROCMLIR_COMMIT="${rocmlir_commit}"
export MANIFEST_ROCM_VERSION="${ROCM_VERSION}"
export MANIFEST_GPU_ARCH="${GPU_ARCH}"
export MANIFEST_PYTHON_ABI="${PYTHON_ABI}"
export MANIFEST_JOBS="${JOBS}"
export MANIFEST_PATCH_SHA="${PATCH_SHA256}"
export MANIFEST_GPU_SHA="${gpu_sha}"
export MANIFEST_COMPILER="$(/opt/rocm/llvm/bin/clang++ --version | head -n 1)"
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["MANIFEST_ROOT"])
manifest_path = root / "BUILD-MANIFEST.json"
files = []
for path in sorted(root.rglob("*")):
    relative = path.relative_to(root).as_posix()
    if path == manifest_path:
        continue
    if path.is_symlink():
        files.append({"path": relative, "type": "symlink", "target": os.readlink(path)})
        continue
    if path.is_dir():
        continue
    if not path.is_file():
        raise SystemExit(f"unsupported package entry: {relative}")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    files.append(
        {"path": relative, "type": "file", "size": path.stat().st_size,
         "sha256": digest.hexdigest()}
    )

manifest = {
    "format": "sam3-migraphx-binary-prefix",
    "format_version": 1,
    "source": {
        "migraphx_commit": os.environ["MANIFEST_MGX_COMMIT"],
        "migraphx_tree": os.environ["MANIFEST_MGX_TREE"],
        "migraphx_upstream_base": os.environ["MANIFEST_MGX_BASE"],
        "release_tag": os.environ["MANIFEST_RELEASE_TAG"],
        "pretag_test_mode": os.environ["MANIFEST_PRETAG_MODE"] == "true",
        "rocmlir_repository": os.environ["MANIFEST_ROCMLIR_REPO"],
        "rocmlir_commit": os.environ["MANIFEST_ROCMLIR_COMMIT"],
        "fc1_sink_patch_sha256": os.environ["MANIFEST_PATCH_SHA"],
    },
    "build": {
        "build_type": "Release",
        "generator": "Ninja",
        "rocm": os.environ["MANIFEST_ROCM_VERSION"],
        "gpu_arch": os.environ["MANIFEST_GPU_ARCH"],
        "python_abi": os.environ["MANIFEST_PYTHON_ABI"],
        "jobs": int(os.environ["MANIFEST_JOBS"]),
        "compiler": os.environ["MANIFEST_COMPILER"],
        "dependency_builder": "rbuild/cget",
        "onnxruntime_built_or_packaged": False,
    },
    "key_artifacts": {
        "lib/migraphx/lib/libmigraphx_gpu.so.2017000.0":
            os.environ["MANIFEST_GPU_SHA"],
    },
    "files": files,
}
manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

export PACKAGE_ROOT="${staging}/migraphx"
python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["PACKAGE_ROOT"])
for path in root.rglob("*"):
    relative = path.relative_to(root)
    if ".." in relative.parts:
        raise SystemExit(f"unsafe path: {relative}")
    if path.is_symlink():
        target = os.readlink(path)
        if target.startswith("/"):
            raise SystemExit(f"absolute symlink: {relative} -> {target}")
        resolved = (path.parent / target).resolve(strict=False)
        if not resolved.is_relative_to(root.resolve()):
            raise SystemExit(f"escaping symlink: {relative} -> {target}")
PY

source_date_epoch="$(git -C "${ROOT}" show -s --format=%ct HEAD)"
temporary_archive="$(mktemp "${OUTPUT_DIR}/.${ARCHIVE_NAME}.XXXXXXXX")"
temporary_sidecar="$(mktemp "${OUTPUT_DIR}/.${ARCHIVE_NAME}.sha256.XXXXXXXX")"
temp_paths+=("${temporary_archive}" "${temporary_sidecar}")
tar --sort=name \
    --format=gnu \
    --mtime="@${source_date_epoch}" \
    --owner=0 --group=0 --numeric-owner \
    -cf - -C "${staging}" migraphx | gzip -n -9 >"${temporary_archive}"

tar -tzf "${temporary_archive}" >/dev/null
archive_sha="$(sha256sum "${temporary_archive}")"
archive_sha="${archive_sha%% *}"
printf '%s  %s\n' "${archive_sha}" "${ARCHIVE_NAME}" >"${temporary_sidecar}"
chmod 0644 "${temporary_archive}" "${temporary_sidecar}"
mv -T "${temporary_archive}" "${archive}"
mv -T "${temporary_sidecar}" "${sidecar}"
printf 'Created %s\n' "${archive}"
cat "${sidecar}"
