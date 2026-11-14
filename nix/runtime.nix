{ pkgs, engine }:
let
  inherit (pkgs) lib;
  cuda = pkgs.cudaPackages_13_4;
  python = pkgs.python3.withPackages (ps: [ ps.pillow ]);
  # Explicitly select the forward-compat driver; do not substitute host libcuda.
  libraries = [ cuda.cuda_compat cuda.libcublas cuda.nccl pkgs.rdma-core ];
  # NVIDIA's forward-compatibility package keeps its driver DSOs in compat/,
  # unlike the ordinary libraries' lib/ outputs.
  libraryPath = "${cuda.cuda_compat}/compat:${lib.makeLibraryPath [ cuda.libcublas cuda.nccl pkgs.rdma-core ]}";
  providerPath = "${pkgs.rdma-core}/lib/libibverbs";
  pythonCheck = pkgs.runCommand "tensorfold-runtime-python-check" { } ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    # Deliberately poison Python's ambient path: the engine launches -I.
    export PYTHONPATH="$TMPDIR/missing"
    ${python}/bin/python3 -I ${./runtime-python-check.py} > "$out"
  '';
in
assert pkgs.stdenv.hostPlatform.system == "aarch64-linux";
pkgs.stdenvNoCC.mkDerivation {
  pname = "tensorfold-runtime-sm121";
  inherit (engine) version;
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  strictDeps = true;

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/share/tensorfold-runtime"
    cat > "$out/share/tensorfold-runtime/environment" <<'EOF'
    # Sourced by the entrypoints below; no host configuration is embedded.
    export PATH=${python}/bin''${PATH:+:$PATH}
    export LD_LIBRARY_PATH=${libraryPath}
    # Opt-in external plugin and dependencies, appended after the pinned libs.
    # Existing LD_LIBRARY_PATH is deliberately replaced to avoid silent mixing.
    if [ -n "''${TF_NCCL_PLUGIN_DIR:-}" ]; then
      if [ ! -d "$TF_NCCL_PLUGIN_DIR" ]; then
        echo "TF_NCCL_PLUGIN_DIR must name an existing directory" >&2
        exit 2
      fi
      export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$TF_NCCL_PLUGIN_DIR"
    fi
    if [ -n "''${TF_RUNTIME_EXTRA_LIBRARY_PATH:-}" ]; then
      export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$TF_RUNTIME_EXTRA_LIBRARY_PATH"
    fi
    EOF
    cat > "$out/bin/tensorfold-native" <<EOF
    #!${pkgs.runtimeShell}
    set -eu
    . "$out/share/tensorfold-runtime/environment"
    exec ${engine}/native/bin/tensorfold-native "\$@"
    EOF
    cat > "$out/bin/tf-dsv41-lanes" <<EOF
    #!${pkgs.runtimeShell}
    set -eu
    . "$out/share/tensorfold-runtime/environment"
    exec ${engine}/bin/tf-dsv41-lanes "\$@"
    EOF
    cat > "$out/bin/tensorfold-runtime-check" <<EOF
    #!${pkgs.runtimeShell}
    set -eu
    . "$out/share/tensorfold-runtime/environment"
    exec ${python}/bin/python3 -I "$out/share/tensorfold-runtime/python-check.py"
    EOF
    cp ${./runtime-python-check.py} "$out/share/tensorfold-runtime/python-check.py"
    chmod +x "$out/bin/"*
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    # No GPU is expected here; capabilities may report an unavailable CUDA device.
    test -x "$out/bin/tf-dsv41-lanes"
    test -e ${cuda.cuda_compat}/compat/libcuda.so.1
    test -e ${lib.getLib cuda.libcublas}/lib/libcublas.so.13
    test -e ${lib.getLib cuda.libcublas}/lib/libcublasLt.so.13
    test -e ${lib.getLib cuda.nccl}/lib/libnccl.so.2
    test -e ${pkgs.rdma-core}/lib/libibverbs.so.1
    test -e ${pkgs.rdma-core}/lib/libmlx5.so.1
    test -e ${providerPath}/libmlx5-rdmav65.so
    test -e ${pkgs.rdma-core}/etc/libibverbs.d/mlx5.driver
    PYTHONPATH="$TMPDIR/missing" "$out/bin/tensorfold-runtime-check"
    "$out/bin/tensorfold-native" capabilities --json > "$TMPDIR/capabilities.json"
    test -s "$TMPDIR/capabilities.json"
    runHook postInstallCheck
  '';

  passthru = {
    inherit python pythonCheck libraryPath providerPath;
    runtimeLibraries = libraries;
    cudaBuild = {
      inherit (cuda.backendStdenv) cudaCapabilities cudaForwardCompat;
      inherit (cuda.flags) gencodeString;
    };
    versions = {
      cuda_compat = cuda.cuda_compat.version;
      cublas = cuda.libcublas.version;
      nccl = cuda.nccl.version;
      gdrcopy = cuda.gdrcopy.version;
      rdma-core = pkgs.rdma-core.version;
      python = pkgs.python3.version;
      pillow = pkgs.python3Packages.pillow.version;
    };
  };
  meta = engine.meta // {
    description = "Optional TensorFold runtime candidate with pinned CUDA compatibility, collectives, RDMA and Pillow";
    mainProgram = "tensorfold-native";
  };
}
