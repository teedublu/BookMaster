{pkgs}: {
  deps = [
    pkgs.qemu
    pkgs.libguestfs
    pkgs.ffmpeg-full
  ];
}
