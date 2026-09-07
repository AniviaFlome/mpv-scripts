{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  packages = with pkgs; [
    lua-language-server
    stylua
    luajit
    ffmpeg
    socat
    tesseract
    ccache
    (python313.withPackages (ps: with ps; [
      rapidocr-onnxruntime
      easyocr
      paddleocr
      imagesize
      pypdfium2
    ]))
  ];
}
