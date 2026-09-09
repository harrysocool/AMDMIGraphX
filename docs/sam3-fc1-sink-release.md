# SAM3 FC1-sink binary release

This branch packages a target-specific MIGraphX 2.17 build for the SAM3 ROCm
runtime. It is based on upstream MIGraphX commit
`9f1a138e77f4738d82a065d225836b3b337950ce` and uses a rocMLIR fork containing
the environment-gated FC1 exact-GELU sink transformation.

This is not a general MIGraphX build. Its supported target is Ubuntu 24.04,
ROCm 7.14, `gfx1151`, Linux x86-64, and CPython 3.12.

## Source identity

- MIGraphX upstream base:
  `9f1a138e77f4738d82a065d225836b3b337950ce`
- rocMLIR upstream base:
  `c35e77b199d2492e8e0f92b3f5ed762700d9334a`
- rocMLIR FC1-sink commit:
  `f3404d59b581fdf9d8cd7c1be9aeeb267851af93`
- rocMLIR FC1-sink tree:
  `2671559325c3a7914488180fe469e45ed6e2917d`
- Public branch: `harrysocool/rocMLIR: sam3/fc1-sink-c35e77b`
- Annotated source tag: `sam3-fc1-sink-rocm714-v2`

`requirements.txt` pins the complete, publicly fetchable rocMLIR commit ID.
The build checks that applying `tools/sam3_fc1sink/align_sink_final.patch` to
the exact upstream base reproduces the pinned fork's `AlignTiling.cpp` Git
blob.

The rejected legacy `find_splits` and host `offload_copy` patches are not part
of this branch. They produced no measurable improvement on MIGraphX 2.17.

## Build

Use an Ubuntu 24.04 build environment with ROCm 7.14 development packages,
CPython 3.12, CMake, Ninja, rbuild, and cget. The build intentionally follows
the normal MIGraphX dependency mechanism: the pinned rocMLIR fork is resolved
from `requirements.txt` and built by rbuild/cget.

```bash
export JOBS="$(nproc)"
export BUILD_ROOT="$HOME/.cache/migraphx-sam3-fc1sink-clean"
export OUTPUT_DIR="$PWD/dist"

tools/sam3_fc1sink/build_release.sh --check
tools/sam3_fc1sink/build_release.sh
```

Formal builds require the annotated tag
`v2.17.0+sam3-fc1sink.20260908.1` to resolve to `HEAD`. Before that tag is
created, use `--allow-untagged-test`; this produces an archive with a
`-pretag` suffix so it cannot be mistaken for the release asset.

The underlying build is equivalent to:

```bash
export CMAKE_BUILD_PARALLEL_LEVEL="${JOBS:-$(nproc)}"
export CGET_JOBS="${JOBS:-$(nproc)}"

rbuild build \
  -d "$BUILD_ROOT/depend" \
  -S "$PWD" \
  -B "$BUILD_ROOT/build" \
  -s develop \
  -G Ninja \
  --cc /opt/rocm/llvm/bin/clang \
  --cxx /opt/rocm/llvm/bin/clang++ \
  -T install \
  -DBUILD_DEV=OFF \
  -DBUILD_TESTING=OFF \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$BUILD_ROOT/install" \
  -DBUILD_SHARED_LIBS=ON \
  -DMIGRAPHX_ENABLE_MLIR=ON \
  -DMIGRAPHX_ENABLE_CPU=OFF \
  -DMIGRAPHX_ENABLE_PYTHON=ON \
  -DMIGRAPHX_USE_HIPBLASLT=ON \
  -DGPU_TARGETS=gfx1151
```

For the repository-owned ROCm 7.14 builder environment, use a normal clone
(not a linked Git worktree whose common Git directory is outside the mount):

```bash
docker build \
  --build-arg JOBS="$(nproc)" \
  -f tools/sam3_fc1sink/Dockerfile.builder \
  -t migraphx-sam3-fc1sink-builder:rocm714 .

mkdir -p "$HOME/.cache/migraphx-sam3-fc1sink-clean" "$PWD/dist"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -e HOME=/tmp \
  -e JOBS="$(nproc)" \
  -e BUILD_ROOT=/build \
  -e DEPS_DIR=/usr/local \
  -e OUTPUT_DIR=/output \
  -v "$PWD:/src:ro" \
  -v "$HOME/.cache/migraphx-sam3-fc1sink-clean:/build" \
  -v "$PWD/dist:/output" \
  -w /src \
  migraphx-sam3-fc1sink-builder:rocm714 \
  tools/sam3_fc1sink/build_release.sh
```

The image build resolves the pinned rocMLIR fork through `requirements.txt`
using rbuild/cget. Because those exact dependencies are already installed in
`/usr/local`, the release script validates that prefix and uses CMake only for
the MIGraphX build/install step. Without `DEPS_DIR`, the script invokes
`rbuild build -s develop` itself and creates the cget dependency prefix below
`BUILD_ROOT`. Neither route fetches or builds ONNX Runtime.

`JOBS` defaults to all logical processors reported by `nproc`; it is not
artificially capped. The Python ABI is fixed to CPython 3.12 rather than being
a filename-only override. ONNX Runtime is neither compiled nor included.
Consumers must obtain the separately pinned ONNX Runtime MIGraphX wheel.

The script refuses a dirty checkout, an unexpected rocMLIR pin, either rejected
legacy patch in the branch ancestry, a source/patch identity mismatch, an
unpatched GPU library, an unexpected Python ABI, and build-directory RPATHs in
the installed GPU library. It does not delete or overwrite an existing build or
release artifact.

To exercise the deterministic packaging stage against an already installed
prefix:

```bash
ROCMLIR_SOURCE=/path/to/rocMLIR \
tools/sam3_fc1sink/build_release.sh \
  --allow-untagged-test \
  --package-only /path/to/migraphx/install \
  --output-dir /path/to/output
```

`ROCMLIR_SOURCE` enables an offline identity check when the pinned commit exists
in the supplied local checkout. Without it, the script downloads the base and
fork versions of `AlignTiling.cpp` over HTTPS and verifies their Git blob IDs.

## Archive contract

The resulting archive is rooted at `migraphx/` and contains:

- the complete CMake install prefix;
- `BUILD-MANIFEST.json`, including source identities, build settings, and
  per-file checksums;
- the MIGraphX MIT license;
- the rocMLIR/LLVM Apache 2.0 with LLVM Exceptions license;
- the exact FC1-sink patch and a source/build notice;
- `THIRD-PARTY-NOTICES` plus pinned license texts for the static and
  template dependencies incorporated into the libraries.

The archive does not contain ROCm, ONNX Runtime, PyTorch, SAM3 checkpoints,
ONNX/MXR model artifacts, or a Docker image. A GNU-format SHA256 sidecar is
written next to it.

GNU tar sorting, a source-commit timestamp, numeric root ownership, and
`gzip -n` make archive serialization deterministic. Reproducible binary bytes
also require the same base image, package repository snapshot, compiler, and
rbuild/cget inputs; record and pin those before publication.

## Runtime use

Enable the optimization while compiling the SAM3 detector backbone:

```bash
export ROCMLIR_SINK_FINAL_ERF=1
```

The switch is compile-time for generated MXR artifacts. It has no effect on an
already compiled MXR. With the variable unset, the additional transformation is
inactive.

Before publishing, verify the final archive through the SAM3 clean Docker flow,
including runtime import, local ONNX/MXR generation, full and hybrid smoke, and
the 30-frame PT-vs-MIG mask regression.
