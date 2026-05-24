{
  description = "cavemacs — Emacs front-end for the caveman-code agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        cavemacs = { trivialBuild, fetchurl, transient }:
          trivialBuild {
            pname = "cavemacs";
            version = "0.0.20";
            src = ./.;
            packageRequires = [ transient ];
            meta = {
              description = "Emacs front-end for the caveman-code agent";
              homepage = "https://github.com/spencerharmon/cavemacs";
            };
          };

        mkPkg = epkgs: epkgs.callPackage cavemacs {};
      in {
        packages = {
          cavemacs = mkPkg pkgs.emacsPackages;
          default = mkPkg pkgs.emacsPackages;
        };

        # emacsWithPackages-friendly overlay output
        overlays.default = final: prev: {
          emacsPackagesFor = emacs:
            (prev.emacsPackagesFor emacs).overrideScope (efinal: eprev: {
              cavemacs = efinal.callPackage cavemacs {};
            });
        };

        # Convenience: `nix run` launches emacs with cavemacs loaded
        apps.default = {
          type = "app";
          program = let
            emacsWith = (pkgs.emacsPackagesFor pkgs.emacs).emacsWithPackages
              (epkgs: [ (mkPkg epkgs) ]);
          in "${emacsWith}/bin/emacs";
        };

        devShells.default = pkgs.mkShell {
          packages = [ pkgs.emacs ];
        };
      });
}
