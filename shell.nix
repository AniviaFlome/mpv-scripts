{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    mpv
    lua-language-server
    stylua
  ];
}
