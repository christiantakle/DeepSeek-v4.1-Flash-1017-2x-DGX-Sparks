# Build-stage experiment

This branch explores build maintenance separately from the runtime dependency
refresh. It retains the pinned NVIDIA image, engine and inputs revisions,
compiler archive, CPU/GPU targets, Python dependencies and serving artifacts.
It does not change model weights or serving parameters.

The Dockerfile uses ordinary heredoc script blocks and these stages:

- `base`: the existing NVIDIA image.
- `compiler`: the checksum-verified Zig compiler.
- `engine-builder`: the patched serving engine and installed tools/notices.
- `inputs-builder`: derives from `engine-builder`, serializing the two all-core
  builds; adds the rank-cache binary, three Python tools and inputs license.
- `runtime`: starts from `base`, copies the full `/opt/tensorfold` install tree,
  then installs the existing pinned safetensors and Pillow dependencies.

The final image excludes the added Zig compiler, checkouts, patches and Zig
caches. NVIDIA's base still includes its CUDA compiler and PyTorch. This is
not a minimal serving image. Python dependency changes affect only the final
stage, avoiding recompilation of native artifacts.

BuildKit persists the shared global Zig cache and separate serving/inputs
local caches outside image layers. Cache mounts use `sharing=locked`; caches
are disposable and must not be treated as required build inputs. Build-host
storage can increase even as the final image becomes smaller. The upstream
CUDA build records `nvcc --version` as an input to its fatbin steps.

The existing `scripts/prepare.sh` context and image hashing cover the change.
The experiment requires a builder supporting Dockerfile heredocs and cache
mounts. No Podman migration or compatibility qualification is included.

For a build-only measurement, use the same context and pinned arguments as
`prepare.sh` with an isolated experimental image tag. Make an actual source or
patch change to invalidate its build layers while preserving compiler caches.
A `--no-cache` or `--no-cache-filter` build may also reset cache mounts, so it
is not a reliable warm-cache benchmark. Ordinary unchanged builds can reuse
entire layers. Never run these all-core builds alongside a loaded inference
model on a Spark.

The intended gains are shorter rebuilds and fewer build-only files in the
final artifact. Heredocs improve maintainability; no inference speedup is
expected. Retaining the approximately 24.7 GB NVIDIA base limits size savings.
The separation also provides a boundary for a later Nix build experiment;
this branch does not implement one.

## Initial ARM64 Spark measurements (2026-11-14)

One run per case, using an already available NVIDIA base:

| Case | Wall time |
| --- | ---: |
| First build with new compiler-cache IDs | 203 s |
| Forced no-cache stages (resets mounts here; not a warm-cache result) | 245 s |
| Normal rebuild after adding a comment-only `build.zig` patch | 125 s |
| Return to unchanged final context, using whole-layer cache | 1 s |

The small patch result is 78 seconds shorter than the first build, but is not
an old-Dockerfile comparison, an arbitrary source-change benchmark or a
repeatable performance guarantee. The cache probe is absent from the final
context and final image.

Final image size is 24,856,153,689 bytes, versus 25,278,792,693 for the previous
image: 422,639,004 bytes (about 423 MB / 1.67%) smaller. These are Docker's
reported image sizes, not compressed transfer sizes or recovered inference
memory. BuildKit retains intermediate stages and compiler caches separately.

Validation: 32 existing script tests passed on the workstation. Both source
checkouts fetched at the pinned revisions and all patches applied during the
Spark builds. The final image passed the existing 10 decoder/protocol cases
and preparation dtype fixture. All 29 installed file paths and modes are
retained; non-binary files match the prior image. Twelve native binaries have
different hashes, so bit-identical rebuilds are not established. The checked
native server, lanes and rank-cache binaries resolve their shared libraries.
Entrypoint, command, environment, working directory and user match the prior
image; Pillow, safetensors and PyTorch versions match as well. No full model
inference or two-node qualification was performed on this experimental image.
The previously qualified serving image remains deployed.
