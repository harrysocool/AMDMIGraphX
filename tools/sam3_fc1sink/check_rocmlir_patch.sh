#!/usr/bin/env bash
# Verify that the packaged patch maps the pinned upstream source blob exactly
# to the source blob published by the SAM3 rocMLIR fork.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_COMMIT=c35e77b199d2492e8e0f92b3f5ed762700d9334a
RELEASE_COMMIT=41251784f1780270545974c832c1093fb4a8d1c1
BASE_BLOB=30e7476aabcb92aaa8a48c92caa707a8e02328c0
RELEASE_BLOB=420145dbff88b76cc1bf5d632d64c0bb90a59dca
SOURCE_FILE=mlir/lib/Dialect/Rock/Transforms/AlignTiling.cpp
PATCH_FILE="${ROOT}/tools/sam3_fc1sink/align_sink_final.patch"
PATCH_SHA256=2739601912d21c8970244eacc25db8e897bc67043497be53c3725a413f57ad5a
FORK_REPOSITORY=harrysocool/rocMLIR

die()
{
    printf 'rocMLIR FC1-sink source check: %s\n' "$*" >&2
    exit 2
}

for command in cmp git sha256sum; do
    command -v "${command}" >/dev/null 2>&1 || die "required command not found: ${command}"
done

actual_patch_sha="$(sha256sum "${PATCH_FILE}")"
actual_patch_sha="${actual_patch_sha%% *}"
[[ "${actual_patch_sha}" == "${PATCH_SHA256}" ]] || die 'patch SHA256 mismatch'
[[ "$(grep -c '^diff --git ' "${PATCH_FILE}")" == 1 ]] || \
    die 'patch must modify exactly one file'

verify_root="$(mktemp -d "${TMPDIR:-/tmp}/rocmlir-sam3-source-check.XXXXXXXX")"
trap 'rm -rf -- "${verify_root}"' EXIT
mkdir -p "${verify_root}/$(dirname "${SOURCE_FILE}")"

if [[ -n "${ROCMLIR_SOURCE:-}" ]]; then
    [[ -e "${ROCMLIR_SOURCE}/.git" ]] || \
        die "ROCMLIR_SOURCE is not a Git checkout: ${ROCMLIR_SOURCE}"
    git -C "${ROCMLIR_SOURCE}" cat-file -e "${BASE_COMMIT}:${SOURCE_FILE}"
    git -C "${ROCMLIR_SOURCE}" cat-file -e "${RELEASE_COMMIT}:${SOURCE_FILE}"
    git -C "${ROCMLIR_SOURCE}" show "${BASE_COMMIT}:${SOURCE_FILE}" \
        >"${verify_root}/${SOURCE_FILE}"
    base_blob="$(git -C "${ROCMLIR_SOURCE}" rev-parse "${BASE_COMMIT}:${SOURCE_FILE}")"
    release_blob="$(git -C "${ROCMLIR_SOURCE}" rev-parse "${RELEASE_COMMIT}:${SOURCE_FILE}")"
    git -C "${ROCMLIR_SOURCE}" diff --full-index --binary \
        "${BASE_COMMIT}" "${RELEASE_COMMIT}" -- "${SOURCE_FILE}" \
        >"${verify_root}/canonical.patch"
    cmp -s "${verify_root}/canonical.patch" "${PATCH_FILE}" || \
        die 'packaged patch differs from the pinned rocMLIR commit'
else
    command -v curl >/dev/null 2>&1 || die 'required command not found: curl'
    curl --fail --location --retry 3 --silent --show-error \
        "https://raw.githubusercontent.com/ROCm/rocMLIR/${BASE_COMMIT}/${SOURCE_FILE}" \
        --output "${verify_root}/${SOURCE_FILE}"
    base_blob="$(git hash-object "${verify_root}/${SOURCE_FILE}")"
    curl --fail --location --retry 3 --silent --show-error \
        "https://raw.githubusercontent.com/${FORK_REPOSITORY}/${RELEASE_COMMIT}/${SOURCE_FILE}" \
        --output "${verify_root}/fork-AlignTiling.cpp"
    release_blob="$(git hash-object "${verify_root}/fork-AlignTiling.cpp")"
fi

[[ "${base_blob}" == "${BASE_BLOB}" ]] || die "unexpected base blob: ${base_blob}"
[[ "${release_blob}" == "${RELEASE_BLOB}" ]] || \
    die "unexpected release blob: ${release_blob}"

git -C "${verify_root}" init --quiet
git -C "${verify_root}" apply --check "${PATCH_FILE}"
git -C "${verify_root}" apply "${PATCH_FILE}"
result_blob="$(git hash-object "${verify_root}/${SOURCE_FILE}")"
[[ "${result_blob}" == "${RELEASE_BLOB}" ]] || \
    die 'applied patch did not reproduce the release source blob'

printf 'rocMLIR FC1-sink source identity verified: %s\n' "${RELEASE_COMMIT}"
