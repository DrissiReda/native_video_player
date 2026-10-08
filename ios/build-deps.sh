#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ -d AV1Deps ] && exit 0
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
fetch() {
  curl -fsSL --retry 3 -o "$W/src.tar.xz" "$1"
  echo "$2  $W/src.tar.xz" | shasum -a 256 -c -
  tar -xJf "$W/src.tar.xz" -C "$W"
}
fetch https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz 733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
fetch https://downloads.videolan.org/videolan/dav1d/1.5.4/dav1d-1.5.4.tar.xz 686616b7c69eb88d44459391ab25cac13b6647a3b288835c5784e71c1514a5c5
for sdk in iphoneos iphonesimulator; do
  target=arm64-apple-ios11.0
  [ $sdk = iphonesimulator ] && target=$target-simulator
  sysroot=$(xcrun --sdk $sdk --show-sdk-path)
  out=$W/$sdk
  printf "[binaries]\nc = ['clang', '-target', '%s', '-isysroot', '%s']\nar = 'ar'\n[host_machine]\nsystem = 'darwin'\nsubsystem = 'ios'\ncpu_family = 'aarch64'\ncpu = 'aarch64'\nendian = 'little'\n" "$target" "$sysroot" > "$W/$sdk.ini"
  meson setup "$W/dav1d-$sdk" "$W/dav1d-1.5.4" --cross-file "$W/$sdk.ini" --prefix "$out" --libdir lib \
    --default-library=static --buildtype=release -Denable_tools=false -Denable_tests=false
  ninja -C "$W/dav1d-$sdk" install
  mkdir "$W/ffmpeg-$sdk"
  (cd "$W/ffmpeg-$sdk" && PKG_CONFIG_LIBDIR="$out/lib/pkgconfig" "$W/ffmpeg-7.1.1/configure" --prefix="$out" \
    --enable-cross-compile --target-os=darwin --arch=arm64 --cc="clang -target $target -isysroot $sysroot" \
    --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-network \
    --disable-avdevice --disable-avfilter --enable-libdav1d --enable-decoder=libdav1d,aac,opus \
    --enable-parser=av1,aac,opus --enable-demuxer=mov,matroska --enable-protocol=file &&
    make -j"$(sysctl -n hw.ncpu)" install)
  libtool -static -o "$W/$sdk.a" "$out"/lib/*.a
done
mkdir "$W/AV1Deps"
xcodebuild -create-xcframework -library "$W/iphoneos.a" -library "$W/iphonesimulator.a" -output "$W/AV1Deps/AV1Deps.xcframework"
cp -R "$W/iphoneos/include" "$W/AV1Deps/include"
mv "$W/AV1Deps" AV1Deps
