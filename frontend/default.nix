{ pkgs, self }:
let
  src = ./.;
  npmlock2nix = pkgs.callPackage self.inputs.npmlock2nix-repo { };
  # nix package that contains all npm dependencies
  node_modules = npmlock2nix.v2.node_modules {
    inherit src;
    nodejs = pkgs.nodejs;
  };
in
pkgs.runCommand "frontend"
{ buildInputs = [ pkgs.nodejs ]; }
  ''
    # linking npm dependencies into the build directory
    ln -sf ${node_modules}/node_modules node_modules
    # copying the source files into the build directory
    cp -r ${src}/. .
    # bundling with webpack into the output
    npm run build -- --output-path $out
    # copying the html entry point into the output
    cp ${./index.html} $out/index.html
  ''
