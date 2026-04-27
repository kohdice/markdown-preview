{
  description = "Markdown Preview";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      zig-overlay,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ zig-overlay.overlays.default ];
        };
        zig = pkgs.zigpkgs."0.16.0";
      in
      {
        devShells.default = pkgs.mkShell {
          name = "markdown-preview";

          nativeBuildInputs = with pkgs; [
            goreleaser
            hyperfine
            zig
          ];
        };
      }
    );
}
