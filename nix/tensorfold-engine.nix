{ pkgs }:
let
  inherit (pkgs) lib;
  cuda = pkgs.cudaPackages_13_4;
  zig = pkgs.zig_0_17;
  engineRef = "fbbc97132cd004237d9887b8d3185896efaedc5c";
  inputsRef = "59402086381a42c74d53053443224eec2790b4c5";
  source = rev: hash: pkgs.fetchzip {
    url = "https://github.com/bertholomus/TensorFold/archive/${rev}.tar.gz";
    inherit hash;
  };
  engineSrc = source engineRef "sha256-tMAd08/ddFb7+VP++r1jcxHn1LY32xVw/DE6R46KQh0=";
  inputsSrc = source inputsRef "sha256-ueQmnkeww6KrNvCoO0ePQLvka2VQ6GJPHOn/fR7ok9s=";
  orderedPatches = dir:
    map (name: dir + "/${name}")
      (lib.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir dir)));
  enginePatches = orderedPatches ../zig/patches;
  inputsPatches = orderedPatches ../zig/patches-inputs;

  # The engine loads the driver dynamically. Header preparation needs no driver
  # compatibility library (and must not select one for a future runtime).
  cudaHeaders = cuda.cuda_cudart.override { cuda_compat = null; };
  cudaIncludeFlags = lib.concatMapStringsSep " "
    (p: "-I${lib.getOutput "include" p}/include")
    [ cudaHeaders cuda.cuda_crt cuda.cccl ];

  prepareCheckout = name: src: patches: ''
    mkdir -p "$NIX_BUILD_TOP/${name}"
    cp -R ${src}/. "$NIX_BUILD_TOP/${name}/"
    chmod -R u+w "$NIX_BUILD_TOP/${name}"
    pushd "$NIX_BUILD_TOP/${name}"
    for patch in ${lib.escapeShellArgs patches}; do
      echo "applying $patch"
      git apply --check "$patch"
      git apply "$patch"
    done
    # This is the recipe's sole compiler-pin adjustment, never a blanket bypass.
    test "${zig.version}" = 0.17.1
    test "$(cat .zig-version)" = 0.17.0
    printf '0.17.1\n' > .zig-version
    popd
  '';
  prepareSources = prepareCheckout "engine" engineSrc enginePatches
    + prepareCheckout "inputs" inputsSrc inputsPatches;
in
assert zig.version == "0.17.1";
assert pkgs.stdenv.hostPlatform.system == "aarch64-linux";
cuda.backendStdenv.mkDerivation {
  pname = "tensorfold-engine-sm121";
  version = "unstable-${builtins.substring 0 12 engineRef}";

  dontUnpack = true;
  strictDeps = true;
  nativeBuildInputs = [ zig cuda.cuda_nvcc pkgs.gitMinimal pkgs.binutils ];
  buildInputs = [ cudaHeaders cuda.cuda_crt cuda.cccl ];

  # Define every phase used by the Zig hook: its default safe build does not
  # reproduce this recipe. Nixpkgs' nvcc profile pins the supported GCC wrapper.
  patchPhase = ''
    runHook prePatch
    ${prepareSources}
    runHook postPatch
  '';
  configurePhase = ''
    runHook preConfigure
    export HOME="$TMPDIR/home"
    export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-global-cache"
    mkdir -p "$HOME" "$ZIG_GLOBAL_CACHE_DIR"
    export NVCC_PREPEND_FLAGS="''${NVCC_PREPEND_FLAGS:+$NVCC_PREPEND_FLAGS }${cudaIncludeFlags}"
    test "$(zig version)" = 0.17.1
    runHook postConfigure
  '';
  enableParallelBuilding = true;
  # Retain the recipe's fatbin flags; avoid the CUDA setup hook's extra compression.
  dontCompressFatbin = true;
  buildPhase = ''
    runHook preBuild
    buildEngine() {
      zig build -Dnvcc=${lib.getExe cuda.cuda_nvcc} -Dsm=121 \
        -Doptimize=ReleaseFast -j"$NIX_BUILD_CORES" \
        --cache-dir "$PWD/.zig-cache" --prefix "$1" install "''${@:2}"
    }
    # One derivation and sequential commands prevent two all-core builds racing.
    pushd "$NIX_BUILD_TOP/engine"
    buildEngine "$TMPDIR/engine-install" native
    popd
    test -x "$TMPDIR/engine-install/native/bin/tensorfold-native"
    test -x "$TMPDIR/engine-install/bin/tf-dsv41-lanes"
    pushd "$NIX_BUILD_TOP/inputs"
    buildEngine "$TMPDIR/inputs-install"
    popd
    test -x "$TMPDIR/inputs-install/bin/tf-dsv41-rank-cache"
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -a "$TMPDIR/engine-install/." "$out/"
    cp "$TMPDIR/inputs-install/bin/tf-dsv41-rank-cache" "$out/bin/"
    mkdir -p "$out/tools/inputs" "$out/share/doc/tensorfold"
    for f in make_token_map.py make_rope.py make_bias_vl.py; do
      case "$f" in
        make_token_map.py) dir=inputs ;;
        *) dir=kit ;;
      esac
      cp "$NIX_BUILD_TOP/inputs/tools/dsv41-zig/$dir/$f" "$out/tools/inputs/"
    done
    for f in LICENSE NOTICE ATTRIBUTION.md THIRD_PARTY_NOTICES.md LICENSES; do
      if [ -e "$NIX_BUILD_TOP/engine/$f" ]; then
        cp -a "$NIX_BUILD_TOP/engine/$f" "$out/share/doc/tensorfold/"
      fi
    done
    if [ -e "$NIX_BUILD_TOP/engine/tools/dsv41-zig/ATTRIBUTION.md" ]; then
      cp "$NIX_BUILD_TOP/engine/tools/dsv41-zig/ATTRIBUTION.md" \
        "$out/share/doc/tensorfold/DSV41-ATTRIBUTION.md"
    fi
    cp "$NIX_BUILD_TOP/inputs/LICENSE" "$out/share/doc/tensorfold/LICENSE-inputs-branch"
    runHook postInstall
  '';

  # A packaging check, requiring neither GPU nor model. No inference claim.
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    for binary in native/bin/tensorfold-native bin/tf-dsv41-lanes bin/tf-dsv41-rank-cache; do
      test -x "$out/$binary"
      readelf -h "$out/$binary" | grep -q 'Machine:.*AArch64'
      readelf -l "$out/$binary" | grep -q 'Requesting program interpreter: /nix/store/'
    done
    for tool in make_token_map.py make_rope.py make_bias_vl.py; do
      test -s "$out/tools/inputs/$tool"
    done
    test -s "$out/share/doc/tensorfold/LICENSE"
    test -s "$out/share/doc/tensorfold/LICENSE-inputs-branch"
    # The recipe runs this command without GPU access before starting either rank.
    "$out/native/bin/tensorfold-native" capabilities --json > "$TMPDIR/capabilities.json"
    test -s "$TMPDIR/capabilities.json"
    runHook postInstallCheck
  '';

  passthru = {
    inherit engineSrc inputsSrc engineRef inputsRef enginePatches inputsPatches;
    sourceCheck = pkgs.runCommand "tensorfold-patched-source-check" {
      nativeBuildInputs = [ pkgs.gitMinimal ];
    } ''
      ${prepareSources}
      mkdir -p "$out"
      printf '%s\n' '${engineRef}' '${inputsRef}' > "$out/revisions"
    '';
  };
  meta = {
    description = "Optional native TensorFold engine and input tools, CUDA SM121 build experiment";
    homepage = "https://github.com/bertholomus/TensorFold";
    license = lib.licenses.asl20;
    platforms = [ "aarch64-linux" ];
  };
}
