{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    lua-language-server
    stylua
    luajit
    ffmpeg
    socat
  ];
}
