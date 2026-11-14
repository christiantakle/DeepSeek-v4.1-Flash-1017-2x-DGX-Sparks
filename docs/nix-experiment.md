# Optional Nix compiler and engine experiments

This branch adds an `aarch64-linux` package for the same pinned, prebuilt
Zig 0.17.1 archive used by Docker, plus access to the maintained Nixpkgs
compiler and a libc integration check. An opt-in native TensorFold engine
derivation now follows the recipe's two pinned checkouts and ordered patch sets.
The engine derivation has built successfully on Linux ARM. A separate opt-in
runtime candidate now declares GPU/RDMA libraries and an isolated Pillow decoder,
with an optional Nix-built Docker image; their Linux build and a controlled two-node GPU serving test have passed. Neither package
contains a model or serving deployment. Serving scripts remain unchanged.
There is no claimed inference speed gain.

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
standalone files for copying into the existing NVIDIA image. The engine package alone does not resolve dynamically loaded GPU/RDMA libraries
or Python dependencies. The optional runtime and controlled serving validation
below cover that separate integration boundary; preparation remains external.

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

## Optional runtime candidate

`packages.aarch64-linux.tensorfold-runtime` wraps the existing stripped package;
it does not rebuild TensorFold. Its `bin/tensorfold-native` and
`bin/tf-dsv41-lanes` execute the packaged head and worker executables with the
same declared library path and Python first on `PATH`.
The runtime has a separate Nixpkgs import with scoped `allowUnfree` and
`enableCudaDriverCompat = true`; the latter is required by this lock's
`cuda_compat` recipe. This import also selects `cudaCapabilities = [ "12.1" ]`
for GB10. CUDA 13.4's locked supported-capability list includes 12.1, and the
maintained recipes pass
`-gencode=arch=compute_121,code=sm_121 -gencode=arch=compute_121,code=compute_121`
to source-built NCCL/GDRCopy. Nixpkgs' default `cudaForwardCompat = true` retains
the latter PTX target; this setting is separate from selecting the compatibility
driver. The tested engine's import, explicit SM121 build and derivation remain unchanged.
The runtime and decoder check are optional packages, outside the default package
and flake checks.

| Locked attribute | Version |
| --- | --- |
| `cudaPackages_13_4.cuda_compat` | 615.71.10 |
| `cudaPackages_13_4.libcublas` | 13.8.2.12 |
| `cudaPackages_13_4.nccl` | 2.32.6-1 |
| `cudaPackages_13_4.gdrcopy` (NCCL dependency) | 2.6 |
| `rdma-core` | 65.0 |
| `python3` | 3.14.10 |
| `python3Packages.pillow` | 13.0.0 |

These attributes and derivations evaluate on macOS; evaluation alone establishes
neither Linux substitutability nor a complete working runtime. The Linux dry run
requires source builds of NCCL and its GDRCopy userspace dependency; the scoped
capability setting avoids compiling kernels for the full default GPU set.
The maintained GDRCopy recipe builds only `lib` and `exes`; upstream `install`
installs those userspace components, while `drv_install` is a separate target.
No `gdrdrv` kernel module is built or installed. Its hardware tests are disabled
because they require an existing host module. This does not establish GDRCopy
availability or operation on the host.
The Linux runtime and image built successfully, including source-built NCCL
and GDRCopy userspace. See the controlled qualification below for scope.
The running Docker image was inspected with Python 3.12.3 and Pillow 13.0.0;
the pinned engine's comment naming Pillow 12.3.0 is stale. Python changes version,
and the CUDA/collectives versions differ from the running image as detailed below.

The wrapper replaces inherited `LD_LIBRARY_PATH`: forward-compat `libcuda` comes
first, followed by cuBLAS (including Lt), NCCL and rdma-core. It never selects a
host `libcuda` as an implicit replacement. rdma-core 65 discovers providers through
its compiled Nix-store provider/config paths; the wrapper exports no unused
`IBV_DRIVERS_PATH` override. Its mlx5
provider and config are checked for existence. Host modules, GPU/RDMA devices,
udev permissions and kernel compatibility remain prerequisites outside Nix.

The HPC-X Spectrum-X NCCL plugin is not packaged. An explicitly selected external
plugin can be supplied using `TF_NCCL_PLUGIN_DIR`; this directory is appended
after the declared libraries. `TF_RUNTIME_EXTRA_LIBRARY_PATH` appends deliberate
external dependency paths, including deliberately exposed host NVML on this non-NixOS host.
Existing `NCCL_*` settings pass through, including `NCCL_NET_PLUGIN` selection.
External paths are outside the derivation and closure and must be qualified for
the selected NCCL/verbs ABI. Do not infer equivalent Spectrum-X, GPUDirect,
mlx5-provider or transport behavior from installing rdma-core or loading a DSO.

The engine's pinned [`pil.zig`](https://github.com/bertholomus/TensorFold/blob/fbbc97132cd004237d9887b8d3185896efaedc5c/zig/src/families/dsv41/pil.zig)
launches exactly `python3 -I -c SCRIPT` for non-PNG images. The runtime uses the
locked Python `withPackages` environment and checks it under `-I`, including a
second isolated child decoding a tiny BMP. The independent decoder check passed
on Linux ARM with Python 3.14.10/Pillow 13.0.0; merely setting `PYTHONPATH` is
insufficient under isolated mode. `tensorfold-runtime-check`
runs the same CPU check after installation. The install check also validates
required library/provider files and runs `capabilities --json`; capabilities may attempt `cuInit` and report no device in the sandbox. This
install check does not establish GPU initialization or load a model. Run on an `aarch64-linux` builder:

```sh
# Decoder only; does not realize the engine or GPU libraries.
nix build 'path:.#packages.aarch64-linux.tensorfold-runtime-python-check' --no-link --print-out-paths -L
# Explicitly opt into the larger runtime dependency closure.
nix build 'path:.#packages.aarch64-linux.tensorfold-runtime' --no-link --print-out-paths -L
runtime=$(nix path-info 'path:.#packages.aarch64-linux.tensorfold-runtime')
"$runtime/bin/tensorfold-runtime-check"
"$runtime/bin/tensorfold-native" capabilities --json
nix path-info -S 'path:.#packages.aarch64-linux.tensorfold-runtime'
```

Model weights, validated rank-cache/kit files, network addresses, RDMA tuning and
two-rank service orchestration stay in the existing external/private configuration.
For the first serving qualification, reuse the already validated rank caches and
kit; provide their existing host paths as engine arguments. This candidate does
not replace `start.sh`, activate a profile or change the production Docker service.
PyTorch/safetensors preparation remains a separate existing Docker preparation
path (`scripts/prepare.sh` and `zig/Dockerfile`); it is not needed to reuse those
prepared artifacts and is not included in this runtime. GPU initialization and two-rank inference were tested separately after the CPU
packaging checks; the results and transport limits are recorded below.

## Optional Nix-built Docker image

`packages.aarch64-linux.tensorfold-runtime-image` uses
`dockerTools.buildLayeredImage` to produce `tensorfold-dsv41-nix:sm121-test`,
an ARM64 Docker-loadable image archive. Nix builds the filesystem and captures
its Nix-store runtime closure; Docker still runs the containers, provides the
existing NFS mounts and applies the existing orchestration and memory guards.
This is not a NixOS migration. The image has no NVIDIA base image, VM build phase,
`runAsRoot`, model data, private environment file or node-specific networking.
The locked layered-image API names its prepared root input `contents`;
`copyToRoot` is the separate `buildImage` API.

The image puts the head and worker wrappers first on `PATH`, followed by isolated
Python and the remaining engine tools. `/opt/tensorfold` points to the complete
packaged engine tree, including preparation scripts and notices. Bash, coreutils
and findutils support the launcher's existing utility and spill-cleanup commands.
`/tmp` is writable with the usual sticky permissions. There is no entrypoint;
the launcher can append `tensorfold-native ...` or `tf-dsv41-lanes ...` directly.
The default command prints capabilities. `NVIDIA_VISIBLE_DEVICES=all` and
`NVIDIA_DRIVER_CAPABILITIES=compute,utility` request the existing NVIDIA runtime's
device/library injection; the wrappers still put the selected Nix compatibility
driver before external library paths.

Image labels record `tf.engine=zig`, `tf.ref`, `tf.inputs`, the locked Nixpkgs
revision and actual Nix engine/runtime paths and runtime derivation. They do not
invent a Dockerfile-derived `tf.patches` identity. If spill is enabled, the
existing launcher falls back to the Docker recipe hash when that label is absent;
qualification must supply distinct `TF_DS_RECIPE_PATCHES`/`TF_DS_ENGINE_ID`
identities for this Nix candidate or use a fresh disabled spill configuration.
Prepared rank caches and kit files are reused externally. CPU PyTorch preparation
continues through the validated existing image, since this candidate supplies no
PyTorch or safetensors environment.

After the runtime package passes Linux checks, build and inspect the optional
archive separately; loading it does not start a container:

```sh
nix build 'path:.#packages.aarch64-linux.tensorfold-runtime-image' --no-link --print-out-paths -L
archive=$(nix path-info 'path:.#packages.aarch64-linux.tensorfold-runtime-image')
docker load -i "$archive"
docker image inspect tensorfold-dsv41-nix:sm121-test
docker run --rm --network none tensorfold-dsv41-nix:sm121-test
docker run --rm --network none --entrypoint tensorfold-runtime-check tensorfold-dsv41-nix:sm121-test
```

The existing head supervisor can temporarily select that loaded image on both
nodes with preparation disabled for a separate controlled qualification, retaining
its normal mounts and two-rank command construction. The Nix package does not
modify `start.sh` or select an image for the service. External NCCL plugins and
host libraries require explicit container mounts and the runtime variables above.
Host-injected utilities such as `nvidia-smi` may depend on a distribution loader
absent from this minimal root; inspect the host directly for those diagnostics.
Neither image evaluation nor CPU capabilities establish GPU initialization,
two-rank transport or inference correctness.

## Runtime integration boundary

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

The controlled host test below exercised these dependencies and the two-rank
path. A Nix closure alone supplies neither host kernel modules nor devices.
The current NVIDIA image remains available and is the restored production image.

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
store. The separately built and tested runtime uses cuBLAS13.8.2.12,
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
was performed. Full scoped flake checks pass. The independent isolated Python
decoder check passed on Linux ARM. The runtime and image also built on Linux ARM and passed the controlled serving
test below. Preparation and optional modes remain outside that qualification.


## Controlled two-node runtime qualification (2026-11-14)

The runtime uses Python 3.14.10/Pillow 13.0.0 under `-I`; all ten decoder/protocol
fixtures matched the existing image. The optional OCI image built to
1,750,621,523 Docker-reported bytes, compared with 25,278,792,693 for the existing
full NVIDIA image. This smaller serving image excludes PyTorch/safetensors
preparation, model data and builder caches; it is not a like-for-like preparation
image or an inference speedup claim.

Nix glibc does not use the distribution's `ld.so.cache`. The NVIDIA container
hook injects host-matched NVML at `/usr/lib/aarch64-linux-gnu/libnvidia-ml.so.1`
on the tested ARM64 hosts. The image exposes only that DSO through a symlink in
`/run/nvidia-driver/lib`, appended through `TF_RUNTIME_EXTRA_LIBRARY_PATH`.
It does not add the host's whole libc directory. The declared compatibility
`libcuda` remains first. Both containers passed an explicit CUDA initialization,
GB10/SM121 device query, NCCL version query, NVML initialization/driver query and
four-device verbs enumeration. Host kernel driver remained 580.178.04.

The existing head supervisor temporarily ran this identical image on both ranks,
reusing the validated prepared artifacts (`PREPARE=0`). Tests used upstream
1M context/shared pool, four streams, drafts enabled, default read-ahead and no
fill overrides. Spill and KV sharding were disabled. The retained greedy baseline
was reused: **31/31 exact prompt/token/full-text matches**, with no request errors
or failed checks. JPEG/WebP/GIF vision checks all passed. A separate cold
298,533-token retrieval prompt answered correctly; prefill was 137.936 seconds
and total request time 139.3 seconds. These are individual samples, not a matched
performance comparison with the existing runtime.

Across 172 candidate-phase samples at roughly two-second intervals, minimum
MemAvailable was 6.787/9.302 GiB, swap usage zero. Neither container reported an
OOM; cursor-scoped kernel logs through restoration had no selected fault-pattern
matches. This is scoped evidence, not exhaustive stress or outage qualification.

NCCL selected its internal **NET/IB** provider on both rails after finding no
optional `libnccl-net.so`. Its logs explicitly reported **GPUDirect RDMA disabled**.
The existing HPC-X Spectrum-X plugin is absent. Transport/performance equivalence,
external plugins, durable spill identity, optional modes and full preparation
remain separate work. The existing launcher does not forward arbitrary wrapper
variables or mount external plugin directories automatically.

The original NVIDIA image, byte-identical private configuration and prepared
marker were restored on both nodes. The head supervisor is enabled/healthy with
zero restart count at the final check. This experiment changes neither NixOS nor
the host driver and is not a permanent service migration. Raw logs, addresses,
weights and private configuration are excluded from this branch.


## Matched runtime comparison (2026-11-14)

A subsequent NVIDIA → Nix → NVIDIA run compared the complete runtime alternatives
under the same production configuration: 524,288 context, shared1,572,864 pool,
four streams, drafts on, read-ahead disabled and existing fill tuning/guards.
Both images were already loaded on both hosts. Each phase restarted through the
same supervisor, warmed with a separate128-token request, then used identical
seed/salt/prompts. Filesystem caches were not purged. This compares differing
compiler/library stacks as well as packaging; it cannot isolate an effect of Nix.

| Metric | NVIDIA A1 / A2 | Nix B |
| --- | --- | --- |
| ~7.85k cold prompt, first token (s) | 3.334 /3.380 | 3.447 |
| ~62.8k cold prompt, first token (s) | 26.108 /26.186 | 26.532 |
| 287,455 cold prompt, first token (s) | 127.260 /127.727 | 128.031 |
| Short-prompt single-stream decode (tokens/s) | 61.147 /61.145 | 59.877 |
| Short-prompt four-stream aggregate (tokens/s) | 131.555 /131.441 | 131.650 |
| Short-prompt first token (s) | 0.1647 /0.1654 | 0.1698 |
| Service start → API health (s, ~2s polling) | 26.161 /28.158 | 26.151 |

Short/medium prefill cells are medians of two requests; long prefill has one
request per phase. Decode and concurrent cells are medians of three128-token
runs. Four-stream measurement uses the shared first-to-last token window;
per-stream rates do not simply sum to the aggregate. The first decode repetition
was slower in all phases (48.6–55.7tokens/s), so these small samples do not prove
a persistent2% single-stream regression. No statistical significance is claimed.
Long-context decode and four simultaneous long histories were not measured here.

All20 measured requests per phase reported zero cached tokens, expected output
lengths and matching prompt/output token counts and full text hashes across
A1/B/A2. Health-counter accounting matched precisely, with no other live requests.
Both variants selected internal NCCL IB on both rails and logged GPUDirect
RDMA disabled; the NVIDIA image loaded the Spectrum-X plugin but did not select
it. Loaded-library maps confirmed each intended compatibility/CUDA/NCCL/verbs set.
This establishes the observed selected path, not every optional transport mode.

Minimum sampled MemAvailable head/worker was7.455/9.976GiB in A1,
7.211/9.795GiB in B and7.212/9.757GiB in A2. Swap remained zero; no container OOM,
selected kernel fault or selected memory-guard action was observed. GPU temperature
snapshots ended at75–81°C; clocks were comparable, but continuous throttling and
energy were not measured. Neither a RAM saving nor a speed gain is demonstrated.

The useful measured difference remains the smaller declared serving closure/image;
full preparation remains separate. The production NVIDIA image/configuration and
prepared marker were restored and verified on both nodes, with the existing head
supervisor enabled/healthy. The Nix path remains optional.
