# Optional Nix compiler and engine experiments

This branch adds an `aarch64-linux` package for the same pinned, prebuilt
Zig 0.17.1 archive used by Docker, plus access to the maintained Nixpkgs
compiler and a libc integration check. An opt-in native TensorFold engine
derivation now follows the recipe's two pinned checkouts and ordered patch sets.
The engine derivation has built successfully on Linux ARM; it supplies no
runtime wrapper, model, Python environment or serving deployment. It changes no
serving scripts. There is no claimed inference speed gain.

`flake.lock` is copied unchanged from the private-labs Spark Nix experiment:
nixpkgs `d4f25a3e562008648d45bcf2d70bcc7422cad84e`. The archive hash and
mirror-first URL list match `scripts/config.sh` and `zig/Dockerfile` defaults.
The executable installs as `bin/zig`, with its bundled standard library at
`lib/zig`, following the layout used by nixpkgs' Zig 0.17 package. Unlike the
nixpkgs source package, this experiment requires no local LLVM build.

## Validation on Linux ARM (2026-11-14)

Mac evaluation succeeded without building Linux packages. On the Spark, the
archive package built and passed its version and relocated-standard-library
checks. Its executable is byte-identical to the verified archive, with SHA256
`e7eef14c4b674845fa65bbd6ad0dbf82037f6cb4364db7973ed23579a5fc26c0`.
Output: `/nix/store/iks1lq74wcznw3nlk353xysf43dsklmv-tensorfold-zig-bin-0.17.1`.
This is packaging an upstream binary, not building Zig from source.
A static-ELF fixup diagnostic did not fail the build or alter the executable.

`packages.aarch64-linux.zig-nixpkgs` exposes the locked maintained
`pkgs.zig_0_17`, also version 0.17.1. Its source-built Linux ARM output is
available from the signed Nix binary cache. The `zig-libc` check compiles a C
file using `stdlib.h`, links it into a Zig test with `-lc`, then runs the test.
It passed in the Nix build environment. An initial check used the removed
`@cImport` builtin; it was corrected to a C source file and extern declaration.
That was a test-harness syntax issue, not a TensorFold failure.

Both checks passed through `nix flake check --all-systems` on the Spark:

```sh
nix build 'path:.#packages.aarch64-linux.zig' --no-link --print-out-paths
nix build 'path:.#checks.aarch64-linux.zig-libc' --no-link --print-out-paths
nix flake check 'path:.' --all-systems
```

The initial compiler checks used cached compiler/toolchain dependencies rather
than building LLVM. Inference remained running for those checks. The subsequent
full engine compilation described below ran with inference paused.
No profile activation, serving script change or host package replacement was
performed. No macOS compiler output or cross-compilation support is provided.

## Native engine build

`packages.aarch64-linux.tensorfold-engine` uses the maintained, locked Nixpkgs
Zig 0.17.1 and `cudaPackages_13_4.cuda_nvcc` (13.4.92). Its source archives pin
the same `TF_REPO`, `TF_REF` and `INPUTS_REF` as `zig/Dockerfile`. Their unpacked
SHA256 hashes were obtained with `nix-prefetch-url --unpack` on the laptop:

| Checkout | Revision | Unpacked hash |
| --- | --- | --- |
| Engine | `fbbc97132cd004237d9887b8d3185896efaedc5c` | `sha256-tMAd08/ddFb7+VP++r1jcxHn1LY32xVw/DE6R46KQh0=` |
| Inputs | `59402086381a42c74d53053443224eec2790b4c5` | `sha256-ueQmnkeww6KrNvCoO0ePQLvka2VQ6GJPHOn/fR7ok9s=` |

Each checkout receives its current patch directory in filename order, with
`git apply --check` before each patch. The compiler-pin adjustment requires both
the packaged compiler to be exactly 0.17.1 and the checkout pin to be exactly
0.17.0. Sources are fetched separately as fixed-output derivations; the engine
build needs no network. `checks.aarch64-linux.tensorfold-sources` performs only
this preparation, without a compiler or CUDA build.

The engine runs `install native`, then the inputs checkout runs `install`, both
with `-Dnvcc`, `-Dsm=121` and `-Doptimize=ReleaseFast`. Like Docker, it leaves
the CPU target at Zig's native default; the Nix hook's baseline CPU and safe
optimization defaults are bypassed. This candidate is intended for a GB10
builder, and may depend on that builder's CPU features. Both builds run
sequentially in one derivation, each bounded by `NIX_BUILD_CORES`; they share a
writable global cache and keep separate local caches. The complete engine
install tree and its license/notice tree are retained, followed by
`tf-dsv41-rank-cache`, the three Python preparation scripts and the inputs
license, matching the Docker install layout.

`cudaPackages_13_4.backendStdenv` supplies the supported native GCC wrapper
(16.2.0 with this lock). Nixpkgs' nvcc profile selects that wrapper. CUDA runtime,
CRT and CCCL header paths are explicit; the runtime header package disables
its optional driver-compat propagation because compiling fatbins does not select
a runtime driver. The CUDA hook's extra fatbin compression is disabled to keep
the recipe's kernel flags. There is no unsupported-host-compiler bypass.
Only the opt-in engine package set permits NVIDIA's unfree redistributables.

Evaluation passed on macOS, and the source preparation check passed in the
Linux Nix sandbox (53 engine patches, 2 inputs patches). The complete engine
and inputs builds then succeeded on a Spark in235s, with dependencies already
realized, max-jobs1 and cores16. Its install check passed: required executables
are AArch64 ELF files with Nix-store interpreters, preparation scripts/licenses
exist, and the CPU-only capabilities command works. Its complete capabilities
JSON equals the existing Docker engine's output. The full engine remains outside `checks`,
so `nix flake check` does not launch a large CUDA build implicitly. Run on an
`aarch64-linux` GB10 builder:

```sh
nix build 'path:.#checks.aarch64-linux.tensorfold-sources' --no-link --print-out-paths
nix build 'path:.#packages.aarch64-linux.tensorfold-engine' --no-link --print-out-paths -L
```

Keep the complete resulting Nix closure: the libc-linked executables are not
standalone files for copying into the existing NVIDIA image. This candidate
does not resolve their dynamically loaded CUDA, NCCL or RDMA libraries, package
PyTorch/Pillow/safetensors, or validate inference. A runtime wrapper and actual
two-rank validation remain separate work.

## Optional executable packaging and diagnostics

`packages.aarch64-linux.tensorfold-engine-package` copies the completed engine
install tree and applies Nix's standard debug stripping to `bin` and `native/bin`.
It does not recompile the engine. The normal `out` output is intended to avoid
retaining Zig through DWARF standard-library source paths. It preserves the
existing ELF interpreter and runpaths. The package's install check verifies
required files, absence of native DWARF sections and the CPU-only
`capabilities --json` command. Linux packaging and these checks passed; only
the packaging derivation rebuilt, leaving the tested engine build unchanged.
The main closure is73,154,464bytes, down from521,338,408bytes with retained
compiler debug references. All28 allocated ELF sections (including machine
code and embedded kernel data) are byte-identical; complete capabilities JSON
also matches both the unstripped build and Docker. This is an engine/libc
closure, not a complete GPU/Python runtime or image-size comparison.

The optional `debug` output contains `tensorfold-native-unstripped`, a symlink
to the original full native executable, retaining the original engine and its
compiler/source closure for running under a debugger or loading symbols.
This is not an automatic build-ID-indexed debug store: the original executable
has no GNU Build ID, which Nix's standard separate-debug-info hook requires.
No ELF metadata is added and no Nix references are rewritten. Only `out` is
selected for installation by default; request `debug` explicitly when needed:

```sh
nix build 'path:.#packages.aarch64-linux.tensorfold-engine-package' --no-link --print-out-paths -L
nix build 'path:.#packages.aarch64-linux.tensorfold-engine-package.debug' --no-link --print-out-paths
```

The executable package still requires its complete Nix closure and does not
provide a GPU runtime wrapper or the dynamically loaded CUDA/NCCL/RDMA libraries.
It remains outside flake checks, so ordinary checks do not trigger an engine build.

## Runtime integration still needed

The pinned [TensorFold CUDA build](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/build/cuda.zig)
invokes `nvcc -fatbin`, records `nvcc --version` as an input and uses SASS
`-gencode` targets; this kit selects `-Dsm=121`. It can instead embed prebuilt
`-Dfatbins` files. The candidate above pins a CUDA compiler, headers and host
toolchain; it does not use prebuilt fatbins. The repository's ordered patches
also modify the kernel set. Merely
compiling a Linux binary without these images does not validate the served path.

Runtime dependencies cannot be inferred from `ldd` alone. The pinned sources
explicitly use `std.DynLib` to load
[`libcuda.so.1`](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/src/cuda/driver.zig),
[`libnccl.so.2`](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/src/cuda/nccl.zig),
[`libcublas.so.13` (fallback `libcublas.so`)](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/src/families/dsv41/cublas.zig)
and [`libibverbs.so.1`](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/src/fabric/verbs.zig).
The supervisor's read-only maps inspection of the existing service additionally
found cuBLAS Lt, mlx5 and the HPC-X NCCL Spectrum-X network plugin. Its CUDA
driver userspace library comes from `/usr/local/cuda-13.4/compat/lib.real/`
(`615.71.09`) while the host kernel module is `580.178.04`. Replacing that
compatibility arrangement with a host library is a separate compatibility test.

A future runtime wrapper must deliberately resolve these libraries and their
transitive dependencies/providers, retain access to the host GPU and RDMA
devices, and validate the actual two-rank path. A Nix store closure alone does
not provide a CUDA driver, kernel modules or devices. Keep the current image
available until that integration has been tested independently.

The existing Docker build also uses PyTorch for CPU RoPE-table preparation;
optional ABLIT preparation uses PyTorch and safetensors. Non-PNG input starts a
Python/Pillow decoder child. These are distinct preparation/feature dependencies
to package or explicitly retain later; the native engine being Zig does not
remove them. Existing `scripts/prepare.sh`, `zig/Dockerfile` and
[`zig-engine.md`](zig-engine.md) describe those paths.

The locked [nixpkgs Zig recipe](https://github.com/NixOS/nixpkgs/blob/d4f25a3e562008648d45bcf2d70bcc7422cad84e/pkgs/development/compilers/zig/generic.nix)
builds Zig from source with CMake, Ninja and LLVM, and patches system-path
discovery. Its version table already offers 0.17.1 using LLVM 22. The candidate
above uses that maintained package. The archive remains a known compiler
baseline; its unmodified system-path discovery is not assumed
sufficient for a sandboxed, libc-linked TensorFold build.

## Version boundary for the next experiment

The locked `cudaPackages_13_4` evaluates for Linux ARM and x86 Linux. The engine build
realized NVCC13.4.92 and its cudart/CRT/CCCL header dependencies in the Nix
store. Remaining runtime versions were inspected only: cuBLAS13.8.2.12,
NCCL2.32.6-1, cuda-compat615.71.10 and rdma-core65.0.
The running NVIDIA image instead loads cuBLAS13.8.1.7, NCCL2.32.3 and
cuda-compat615.71.09. Choosing the maintained Nix CUDA set would therefore
change runtime library versions as well as packaging. Attribute evaluation is
not proof that every package substitutes, builds or works on the Sparks.

The candidate uses the maintained Nixpkgs Zig package for the libc-linked
engine; its setup hook and source patches support Nix path discovery. The
archive package remains the exact-compiler packaging baseline. The candidate
explicitly chooses its optimization, CUDA flags and install targets; the
Nixpkgs setup hook defaults do not reproduce the recipe. It must ship its actual
libc/loader closure. A successful tiny check is
not evidence that its executable can simply be copied into the existing image.

## Deployment status

Full engine compilation paused inference through the existing head supervisor;
normal source/image/configuration were restored afterward. Packaging-only
checks ran with the normal model healthy. No Nix profile activation, host
package or kernel-driver replacement, model/kit change or service migration
was performed. Full scoped flake checks pass; runtime inference/RDMA, image
features and preparation under a Nix wrapper remain unqualified.
