# Optional Nix shell that exposes PortAudio to sounddevice (ctypes).
# Usage: nix-shell  (then: uv sync && uv run python main.py …)
{ pkgs ? import <nixpkgs> { } }:
pkgs.mkShell {
  packages = [
    pkgs.uv
    pkgs.portaudio
  ];
  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.portaudio ];
}
