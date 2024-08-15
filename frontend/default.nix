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
pkgs.runCommand "frontend" { } ''
  # linking npm dependencies into the build directory
  ln -sf ${node_modules}/node_modules node_modules
  # copying the source files into the build directory
  cp -r ${src}/. .
  export PATH="${node_modules}/node_modules/.bin:$PATH"
  # bundling with webpack into the output
  webpack --env=mode=production --output-path $out
  # copying the html entry point into the output
  cp ${./index.html} $out/index.html
''
