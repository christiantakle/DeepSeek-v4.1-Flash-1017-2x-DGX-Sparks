# Optional Nix compiler experiment

This branch adds an `aarch64-linux` package for the same pinned, prebuilt
Zig 0.17.1 archive used by Docker, plus access to the maintained Nixpkgs
compiler and a libc integration check. It does not build Zig from source or package
TensorFold, CUDA, the model, Python preparation, or the serving environment.
It changes no serving scripts. There is no claimed inference speed gain.

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

Only small compiler checks ran; cached compiler/toolchain dependencies were
fetched instead of building LLVM. Inference remained running and healthy.
No profile activation, serving script change or host package replacement was
performed. No macOS compiler output or cross-compilation support is provided.

## What a real engine package still needs

The pinned [TensorFold CUDA build](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/build/cuda.zig)
invokes `nvcc -fatbin`, records `nvcc --version` as an input and uses SASS
`-gencode` targets; this kit selects `-Dsm=121`. It can instead embed prebuilt
`-Dfatbins` files. A future derivation must pin a suitable CUDA compiler,
headers and host toolchain, or independently hash every matching prebuilt
fatbin. The repository's ordered patches also modify the kernel set. Merely
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
discovery. Its version table already offers 0.17.1 using LLVM 22. That is a
possible later alternative; this experiment deliberately tests the known
archive first and does not assume its unmodified system-path discovery is
sufficient for a sandboxed, libc-linked TensorFold build.

## Version boundary for the next experiment

The locked `cudaPackages_13_4` evaluates for Linux ARM and x86 Linux. Version
inspection only (no GPU package build or installation): nvcc/cudart13.4.92,
cuBLAS13.8.2.12, NCCL2.32.6-1, cuda-compat615.71.10; rdma-core65.0.
The running NVIDIA image instead loads cuBLAS13.8.1.7, NCCL2.32.3 and
cuda-compat615.71.09. Choosing the maintained Nix CUDA set would therefore
change runtime library versions as well as packaging. Attribute evaluation is
not proof that every package substitutes, builds or works on the Sparks.

Prefer the maintained Nixpkgs Zig package for an actual libc-linked engine
experiment; its setup hook and source patches support Nix path discovery.
Keep the archive package as the exact-compiler packaging baseline. A future
engine derivation must explicitly choose its optimization, CUDA flags and
install targets; the Nixpkgs setup hook defaults do not reproduce the recipe.
It must also ship its actual libc/loader closure. A successful tiny check is
not evidence that its executable can simply be copied into the existing image.
