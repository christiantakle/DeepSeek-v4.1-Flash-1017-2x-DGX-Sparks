{ pkgs, engine, runtime, engineRef, inputsRef, nixpkgsRef }:
let
  inherit (pkgs) lib;
  # Wrappers have their own leading PATH entry so the engine's unwrapped worker
  # in /bin can never take precedence. Retain tools used by launcher cleanup.
  root = pkgs.buildEnv {
    name = "tensorfold-runtime-image-root";
    paths = [ runtime (lib.lowPrio engine) runtime.python pkgs.bash pkgs.coreutils pkgs.findutils ];
    pathsToLink = [ "/bin" ];
  };
  imageConfig = {
    Entrypoint = [ ];
    Cmd = [ "tensorfold-native" "capabilities" "--json" ];
    WorkingDir = "/workspace";
    Env = [
      "PATH=${runtime}/bin:${runtime.python}/bin:/bin"
      "HOME=/tmp"
      "NVIDIA_VISIBLE_DEVICES=all"
      "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
      "TF_RUNTIME_EXTRA_LIBRARY_PATH=/run/nvidia-driver/lib"
    ];
    Labels = {
      "org.opencontainers.image.title" = "TensorFold Nix runtime candidate";
      "org.opencontainers.image.description" = "Nix-built ARM64 runtime candidate, launched with Docker and external prepared model data";
      "tf.engine" = "zig";
      "tf.ref" = engineRef;
      "tf.inputs" = inputsRef;
      "tf.nix.nixpkgs" = nixpkgsRef;
      "tf.nix.builder" = "dockerTools.buildLayeredImage";
      "tf.nix.runtime" = builtins.unsafeDiscardStringContext runtime.outPath;
      "tf.nix.runtime-drv" = builtins.unsafeDiscardStringContext runtime.drvPath;
      "tf.nix.engine" = builtins.unsafeDiscardStringContext engine.outPath;
    };
  };
in
assert pkgs.stdenv.hostPlatform.system == "aarch64-linux";
pkgs.dockerTools.buildLayeredImage {
  name = "tensorfold-dsv41-nix";
  tag = "sm121-test";
  architecture = "arm64";
  # The locked layered-image API calls its root input `contents`; copyToRoot
  # belongs to dockerTools.buildImage. No NVIDIA base, VM or runAsRoot is used.
  contents = [ root pkgs.dockerTools.usrBinEnv ];
  extraCommands = ''
    mkdir -p opt workspace tmp run/nvidia-driver/lib
    ln -s ${engine} opt/tensorfold
    # NVIDIA's GPU hook injects the host-matched NVML here on Linux ARM64.
    # Expose only that driver library, never a whole host libc directory.
    ln -s /usr/lib/aarch64-linux-gnu/libnvidia-ml.so.1 run/nvidia-driver/lib/libnvidia-ml.so.1
  '';
  fakeRootCommands = ''
    chmod 1777 tmp
  '';
  config = imageConfig;
  passthru = { inherit imageConfig; };
  meta = {
    description = "Optional Nix-built TensorFold ARM64 Docker runtime image candidate";
    platforms = [ "aarch64-linux" ];
  };
}
