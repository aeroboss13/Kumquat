#!/bin/zsh
# Builds a self-contained, LGPL-only ffmpeg for embedding in the app (App Store and GitHub builds).
#   - no GPL or non-free components (no x264/x265): H.264/HEVC/AAC go through Apple's VideoToolbox/AudioToolbox
#   - LGPL/BSD codecs linked statically: LAME (MP3), Opus, Vorbis, VPX (VP8/VP9), WebP
#   - result depends only on system frameworks, so it runs inside the app sandbox
# Output: vendor/ffmpeg/bin/ffmpeg and vendor/ffmpeg/Acknowledgements.txt. Source: the official release tarball.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
VERSION=9.0.2
SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
BREW=$(brew --prefix)
# ffmpeg's configure breaks on paths with spaces, so build in the temp directory and copy the result back.
WORK=${TMPDIR:-/tmp}/kumquat-ffmpeg-build
WORK=${WORK//\/\//\/}
PREFIX=$WORK/install
OUT=$ROOT/vendor/ffmpeg

TARBALL=$(brew --cache)/downloads/$(ls "$(brew --cache)/downloads" | grep -- "--ffmpeg-$VERSION.tar.xz" | head -1)
if [[ ! -f "$TARBALL" ]]; then
  curl -fL -o "/tmp/ffmpeg-$VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  TARBALL=/tmp/ffmpeg-$VERSION.tar.xz
fi
echo "$SHA256  $TARBALL" | shasum -a 256 -c -

rm -rf "$WORK" && mkdir -p "$WORK"
tar -xf "$TARBALL" -C "$WORK"
SRC=$WORK/ffmpeg-$VERSION

# pkg-config files that point straight at the static archives, so nothing links a Homebrew dylib.
PC=$WORK/pkgconfig; STATIC=$WORK/static; mkdir -p "$PC" "$STATIC"
ln -sf "$BREW/lib/libmp3lame.a" "$STATIC/libmp3lame.a"
pc() { # name version libs...
  local name=$1 version=$2; shift 2
  printf 'Name: %s\nDescription: %s\nVersion: %s\nCflags: -I%s/include\nLibs: %s\n' "$name" "$name" "$version" "$BREW" "$*" > "$PC/$name.pc"
}
pc ogg 1.3.5 "$BREW/lib/libogg.a"
pc vorbis 1.3.7 "$BREW/lib/libvorbis.a $BREW/lib/libogg.a"
pc vorbisenc 1.3.7 "$BREW/lib/libvorbisenc.a $BREW/lib/libvorbis.a $BREW/lib/libogg.a"
pc opus 1.5.2 "$BREW/lib/libopus.a"
sed -i '' "s|^Cflags: .*|Cflags: -I$BREW/include/opus|" "$PC/opus.pc"   # opus headers live in include/opus
pc vpx 1.15.0 "$BREW/lib/libvpx.a"
pc libwebp 1.5.0 "$BREW/lib/libwebp.a $BREW/lib/libsharpyuv.a"
pc libwebpmux 1.5.0 "$BREW/lib/libwebpmux.a $BREW/lib/libwebp.a $BREW/lib/libsharpyuv.a"
pc libsharpyuv 1.5.0 "$BREW/lib/libsharpyuv.a"

cd "$SRC"
PKG_CONFIG_LIBDIR="$PC" PKG_CONFIG_PATH="" ./configure \
  --prefix="$PREFIX" \
  --arch=arm64 --target-os=darwin --cc=clang \
  --extra-cflags="-mmacosx-version-min=15.0 -I$BREW/include" \
  --extra-ldflags="-mmacosx-version-min=15.0 -L$STATIC" \
  --pkg-config=pkg-config --pkg-config-flags=--static --extra-libs=-liconv \
  --disable-autodetect --disable-gpl --disable-nonfree --disable-version3 \
  --enable-static --disable-shared --disable-doc --disable-ffplay --disable-network --disable-debug \
  --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib --enable-iconv \
  --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx --enable-libwebp
make -j"$(sysctl -n hw.ncpu)"
make install >/dev/null
rm -rf "$OUT" && mkdir -p "$OUT/bin"
cp "$PREFIX/bin/ffmpeg" "$OUT/bin/"
strip -x "$OUT/bin/ffmpeg"
cp "$SRC/COPYING.LGPLv2.1" "$OUT/LICENSE.txt"

echo "--- linked libraries (must be system only):"
otool -L "$OUT/bin/ffmpeg" | tail -n +2
echo "--- license:"
"$OUT/bin/ffmpeg" -hide_banner -L | head -3

# Licence notices shipped inside the app (LGPL and BSD both require them).
{
  echo "Kumquat includes the following open-source software."
  echo
  echo "== FFmpeg $VERSION — GNU Lesser General Public License v2.1 or later"
  echo "Source: https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  echo "Built unmodified as a separate helper executable by scripts/build-ffmpeg.sh in"
  echo "https://github.com/aeroboss13/Kumquat — run that script to rebuild or replace it."
  echo "Configuration: $("$OUT/bin/ffmpeg" -hide_banner -buildconf 2>/dev/null | tr -s ' \n' ' ')"
  echo
  cat "$SRC/COPYING.LGPLv2.1"
  for entry in "LAME (MP3 encoder):lame:COPYING" "Opus:opus:COPYING" "Vorbis:libvorbis:COPYING" "Ogg:libogg:COPYING" \
               "libvpx (VP8/VP9):libvpx:LICENSE" "libwebp:webp:COPYING"; do
    name=${entry%%:*}; rest=${entry#*:}; formula=${rest%%:*}; file=${rest#*:}
    echo; echo; echo "== $name $(brew list --versions $formula | cut -d' ' -f2)"; echo
    cat "$(brew --prefix $formula)/$file"
  done
} > "$OUT/Acknowledgements.txt"
rm -f "$OUT/LICENSE.txt"
echo "--- wrote $OUT/Acknowledgements.txt ($(wc -l < "$OUT/Acknowledgements.txt") lines)"
