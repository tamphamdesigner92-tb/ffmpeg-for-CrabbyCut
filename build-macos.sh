#!/usr/bin/env bash
# Dựng bản FFmpeg mà CrabbyCut dùng trên macOS (Apple Silicon) — CÙNG mã nguồn với bản Windows của
# build.sh: FFmpeg n8.1.1 + patches/ffmpeg, bản shared, GPL v3, cùng chuỗi phiên bản
# (`ffmpeg version n8.1.1-crabbycut.N`). Hai máy chạy cùng một FFmpeg thì CrabbyCut cho cùng kết
# quả trên cả hai — ffmpeg Homebrew (8.1, rồi 9.x sau một lần `brew upgrade`) làm tròn khác 8.1.1
# và thiếu zscale, đã làm đỏ 3 test chỉ trên Mac.
#
# KHÁC BẢN WINDOWS Ở ĐÂU (và chỉ ở đó):
#   - Tăng tốc phần cứng: VideoToolbox/AudioToolbox/CoreImage thay cho CUDA/NVENC/AMF/QSV/D3D.
#     Bộ lọc crabgeo_cuda/crabblend_cuda của bản vá chỉ bật khi có ffnvcodec nên không được biên
#     dịch; phần vá fftools/hwdownload vẫn có trong bản dựng (cùng cây nguồn).
#   - Không có libplacebo (cần Vulkan, trên Mac là MoltenVK): CrabbyCut tự lùi về zscale — đúng
#     đường mà máy Windows không có driver Vulkan vẫn đi.
#   - Không có yadif_videotoolbox (cần trình biên dịch Metal của Xcode đầy đủ; CrabbyCut không dùng).
#   - zlib/bzip2 lấy của macOS (thư viện hệ thống, luôn có); mọi thư viện khác dựng TĨNH từ mã nguồn,
#     CÙNG PHIÊN BẢN với gói MSYS2 mà bản Windows kèm theo (bảng ở README.txt trong zip Windows),
#     rồi liên kết vào các dylib của FFmpeg. Gói chỉ phụ thuộc thư viện hệ thống (bước install kiểm),
#     chạy được trên mọi Mac Apple Silicon từ macOS 11, không cần Homebrew.
#
# Chạy trên Mac Apple Silicon có Command Line Tools và các công cụ build:
#   brew install cmake meson ninja autoconf automake libtool pkgconf
#   ./build-macos.sh [bước ...]   bước: check fetch deps configure make install package; mặc định = all
#
# Biến môi trường (như build.sh):
#   WORK=<thư mục>    nơi đặt mã nguồn tải về, build, install, dist (mặc định ./work-macos)
#   FFMPEG_SRC=<dir>  dùng cây nguồn có sẵn thay cho clone n8.1.1 + áp bản vá (bản dev, không đóng gói)
#   JOBS=<n>          số luồng build (mặc định = số nhân)
#   RELEASE_TAG=<tag> tag/Release chứa zip này (mặc định = CRABBYCUT_VERSION). Tag phải trỏ tới commit
#                     có CHÍNH kịch bản này — README.txt trong zip dẫn tới đó làm mã nguồn tương ứng.
#
# Viết cho bash 3.2 (bash có sẵn của macOS): không mảng kết hợp, không mapfile, mảng có thể rỗng
# thì mở bằng ${a[@]+"${a[@]}"}.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAME=$(tr -d '[:space:]' < "$HERE/CRABBYCUT_VERSION")   # vd. n8.1.1-crabbycut.2
REPO_URL=https://github.com/tamphamdesigner92-tb/ffmpeg-for-CrabbyCut
FFMPEG_TAG=n8.1.1
FFMPEG_URL=https://github.com/FFmpeg/FFmpeg.git
ARCH=arm64
MIN_MACOS=11.0          # Mac Apple Silicon nào cũng từ macOS 11
WORK=${WORK:-$HERE/work-macos}
SRC=${FFMPEG_SRC:-$WORK/ffmpeg}
TARBALLS=$WORK/tarballs
DEPSRC=$WORK/depsrc
DEPS=$WORK/deps
BUILD=$WORK/build
PREFIX=$WORK/install
DIST=$WORK/dist
JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
PKG=ffmpeg-$NAME-macos-$ARCH-gpl-shared
RELEASE_TAG=${RELEASE_TAG:-$NAME}

# Thư viện ngoài: tên|phiên bản|nguồn|sha256 (nguồn git: git+<repo>#<commit>, sha256 để trống).
# Phiên bản = phiên bản gói MSYS2 trong bản Windows cùng NAME. Đổi phiên bản ở đây thì đổi cả ở đó.
DEP_TABLE='
xz|5.8.4|https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.xz|4ce24038fd4221e0d13bc1a2de7a4db56e90b92b3bf75321f6c14be73f65de4b
libpng|1.6.59|https://github.com/pnggroup/libpng/archive/refs/tags/v1.6.59.tar.gz|2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5
expat|2.8.5|https://github.com/libexpat/libexpat/releases/download/R_2_8_5/expat-2.8.5.tar.xz|1e727b8933ec51a77a9a9d9afcf8e688bce45d907c13e36ab7393fe36e703182
freetype|2.14.3|https://downloads.sourceforge.net/project/freetype/freetype2/2.14.3/freetype-2.14.3.tar.xz|36bc4f1cc413335368ee656c42afca65c5a3987e8768cc28cf11ba775e785a5f
fribidi|1.0.17|https://github.com/fribidi/fribidi/releases/download/v1.0.17/fribidi-1.0.17.tar.xz|6949dcde27d41cebad1fd741fcafc36d55a1020d2d872d4a6eb3914caabbada2
harfbuzz|14.5.0|https://github.com/harfbuzz/harfbuzz/releases/download/14.5.0/harfbuzz-14.5.0.tar.xz|b7132e148358a45185c9feafd049dbaf243649d3c44414b3534d9c95d18592b9
fontconfig|2.18.3|https://gitlab.freedesktop.org/api/v4/projects/890/packages/generic/fontconfig/2.18.3/fontconfig-2.18.3.tar.xz|4f7b554a38cdf78c033f666c8871f3749e14a094f65a07f630c91ed0b43d35e3
libunibreak|7.0|https://github.com/adah1972/libunibreak/releases/download/libunibreak_7_0/libunibreak-7.0.tar.gz|8c9a6e121736cd0d5c890ae3ae96f3f4010a19aa040f1dbded833a62a87717d3
libass|0.17.5|https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz|2dca25c0e0c837ddf00b52011b3f82cac1e4ddd3ad018227806b0c2288864acc
zimg|3.0.6|git+https://github.com/sekrit-twc/zimg.git#f819b14e8f39d1282400b0d9543e8ef73c1b2bbd|
x264|0.165.r3222.b35605a|git+https://code.videolan.org/videolan/x264.git#b35605ace3ddf7c1a5d67a2eb553f034aef41d55|
x265|4.3|https://github.com/Multicorewareinc/x265/releases/download/4.3/x265_4.3.tar.gz|83c53e4c8bbb8f1e33ed59e10a7d621d1d7801ca853910c3eb41f038b8ffb121
dav1d|1.5.4|https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2|2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011
lame|3.100|https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz|ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
vmaf|3.2.1|https://github.com/Netflix/vmaf/archive/refs/tags/v3.2.1.tar.gz|5df7386911bc15fd1ca783132528748d219768ae4fc5f8e0b61184f041648092
'

die() { echo "build-macos.sh: $*" >&2; exit 1; }
log() { echo "== $*"; }
ff() { "$PREFIX/bin/ffmpeg" -hide_banner "$@" 2>&1; }
ff_version() { local v; v=$(ff -version); echo "${v%%$'\n'*}"; }
dep_rows() { grep -v '^[[:space:]]*$' <<< "$DEP_TABLE"; }
dep_field() { dep_rows | awk -F'|' -v n="$1" -v i="$2" '$1 == n { print $i }'; }

# MÔI TRƯỜNG BUILD KÍN: chỉ thấy thư viện của WORK/deps và của macOS. Homebrew nằm ngay trên máy
# build — một gói Homebrew lọt vào (qua pkg-config, cmake hay biến môi trường) là bản dựng chạy
# được ở đây rồi chết trên máy người dùng. Phép kiểm liên kết ở bước install là chốt chặn cuối.
build_env() {
  unset CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH LIBRARY_PATH PKG_CONFIG_PATH DYLD_LIBRARY_PATH \
    DYLD_FALLBACK_LIBRARY_PATH CMAKE_PREFIX_PATH
  export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig
  export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
  export CFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -O2 -fPIC -I$DEPS/include"
  export CXXFLAGS=$CFLAGS
  export CPPFLAGS="-I$DEPS/include"
  export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MIN_MACOS -L$DEPS/lib"
}

step_check() {
  [[ $(uname -s) == Darwin ]] || die "chỉ chạy trên macOS (bản Windows: build.sh)"
  [[ $(uname -m) == "$ARCH" ]] || die "cần Mac $ARCH, máy này là $(uname -m)"
  local t missing=
  for t in clang cmake meson ninja autoreconf glibtoolize pkg-config git curl shasum xxd gperf otool vtool zip; do
    command -v "$t" >/dev/null || missing+=" $t"
  done
  [[ -z $missing ]] || die "thiếu công cụ:$missing"$'\n'"cài: brew install cmake meson ninja autoconf automake libtool pkgconf"
  log "check: đủ công cụ (SDK macOS $(xcrun --show-sdk-version))"
}

fetch_dep() {
  local name=$1 url=$2 sha=$3 dir=$DEPSRC/$1
  rm -rf "$dir"
  if [[ $url == git+* ]]; then
    local repo=${url#git+} commit
    commit=${repo##*#}; repo=${repo%#*}
    # Không --depth 1: x264 đếm commit để đặt phiên bản (0.165.r3222). blob:none vẫn nhẹ.
    git clone -q --filter=blob:none "$repo" "$dir"
    git -C "$dir" checkout -q "$commit"
    git -C "$dir" submodule -q update --init --recursive
  else
    local file=$TARBALLS/${url##*/}
    [[ $name == libpng || $name == vmaf ]] && file=$TARBALLS/$name-$(dep_field "$name" 2).tar.gz
    [[ -s $file ]] || curl -fsSL --retry 3 -o "$file" "$url"
    local got; got=$(shasum -a 256 "$file" | cut -c1-64)
    [[ $got == "$sha" ]] || die "SHA-256 của $file lệch: $got (cần $sha)"
    mkdir -p "$dir"
    tar -xf "$file" -C "$dir" --strip-components=1
  fi
}

step_fetch() {
  mkdir -p "$WORK" "$TARBALLS" "$DEPSRC"
  if [[ -z ${FFMPEG_SRC:-} ]]; then
    [[ -d $SRC/.git ]] || git clone --depth 1 --branch "$FFMPEG_TAG" "$FFMPEG_URL" "$SRC"
    # Luôn về đúng n8.1.1 sạch rồi áp lại bản vá: bản dựng không phụ thuộc lần chạy trước.
    git -C "$SRC" reset -q --hard HEAD
    git -C "$SRC" clean -qfdx
    [[ $(git -C "$SRC" rev-parse HEAD) == $(git -C "$SRC" rev-parse "$FFMPEG_TAG^{commit}") ]] \
      || die "$SRC không ở $FFMPEG_TAG — xoá thư mục đó rồi chạy lại"
    local patch _
    while read -r patch _; do
      [[ -z $patch || $patch == \#* ]] && continue
      git -C "$SRC" apply --whitespace=nowarn "$HERE/patches/ffmpeg/$patch"
      log "fetch: đã áp $patch"
    done < "$HERE/patches/ffmpeg/series"
    printf '%s\n' "$NAME" > "$SRC/VERSION"
  fi
  local name ver url sha
  while IFS='|' read -r name ver url sha; do
    fetch_dep "$name" "$url" "$sha"
    log "fetch: $name $ver"
  done < <(dep_rows)
  log "fetch: FFmpeg $(git -C "$SRC" describe --tags --always)"
}

# --- dựng từng thư viện (tĩnh, PIC) vào $DEPS -------------------------------------------------

meson_dep() {   # <thư mục nguồn> [tuỳ chọn meson...]
  local src=$1; shift
  rm -rf "$src/_build"
  meson setup "$src/_build" "$src" --prefix="$DEPS" --libdir=lib --buildtype=plain \
    --default-library=static -Db_staticpic=true --wrap-mode=nofallback "$@"
  ninja -C "$src/_build" -j"$JOBS"
  ninja -C "$src/_build" install
}

cmake_dep() {   # <thư mục nguồn> <thư mục build> [tuỳ chọn cmake...]
  local src=$1 bld=$2; shift 2
  rm -rf "$bld"
  # CMAKE_POLICY_VERSION_MINIMUM: CMake 4 từ chối CMakeLists khai cmake_minimum_required < 3.5 (x265).
  cmake -S "$src" -B "$bld" -G Ninja -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_PREFIX_PATH="$DEPS" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "$@"
  cmake --build "$bld" -j"$JOBS"
}

autotools_dep() {   # <thư mục nguồn> [tuỳ chọn configure...]
  local src=$1; shift
  ( cd "$src" && ./configure -q --prefix="$DEPS" --disable-shared --enable-static --with-pic \
      --disable-dependency-tracking "$@" && make -j"$JOBS" && make install )
}

# zlib/bzip2 của macOS không có tệp .pc, mà libpng/freetype khai `Requires.private: zlib` — thiếu
# thì `pkg-config --static freetype2` báo lỗi và configure của FFmpeg coi như không có freetype.
write_system_pc() {
  local sdk zv; sdk=$(xcrun --show-sdk-path)
  zv=$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$sdk/usr/include/zlib.h")
  mkdir -p "$DEPS/lib/pkgconfig"
  printf 'Name: zlib\nDescription: zlib của macOS\nVersion: %s\nLibs: -lz\nCflags:\n' "$zv" > "$DEPS/lib/pkgconfig/zlib.pc"
  printf 'Name: bzip2\nDescription: bzip2 của macOS\nVersion: 1.0.8\nLibs: -lbz2\nCflags:\n' > "$DEPS/lib/pkgconfig/bzip2.pc"
}

build_xz() {
  autotools_dep "$DEPSRC/xz" --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
    --disable-lzma-links --disable-scripts --disable-doc --disable-nls
}
build_libpng() {
  cmake_dep "$DEPSRC/libpng" "$DEPSRC/libpng/_build" -DPNG_SHARED=OFF -DPNG_STATIC=ON \
    -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
  cmake --install "$DEPSRC/libpng/_build"
}
build_expat() {
  cmake_dep "$DEPSRC/expat" "$DEPSRC/expat/_build" -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF \
    -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_SHARED_LIBS=OFF
  cmake --install "$DEPSRC/expat/_build"
}
build_freetype() {
  meson_dep "$DEPSRC/freetype" -Dpng=enabled -Dzlib=system -Dbzip2=enabled -Dbrotli=disabled \
    -Dharfbuzz=disabled -Dtests=disabled
}
build_fribidi() { meson_dep "$DEPSRC/fribidi" -Ddocs=false -Dbin=false -Dtests=false; }
build_harfbuzz() {
  meson_dep "$DEPSRC/harfbuzz" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
    -Dchafa=disabled -Dicu=disabled -Dpng=disabled -Dzlib=disabled -Dgraphite2=disabled \
    -Dcoretext=disabled -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled \
    -Dtests=disabled -Ddocs=disabled -Dintrospection=disabled -Dutilities=disabled -Dbenchmark=disabled
}
build_fontconfig() {
  meson_dep "$DEPSRC/fontconfig" -Ddoc=disabled -Dnls=disabled -Dtests=disabled -Dtools=disabled \
    -Dcache-build=disabled -Diconv=disabled -Dxml-backend=expat
  # Tệp cấu hình nằm ở đường dẫn của MÁY BUILD, máy người dùng không có. Xoá luôn ở đây để máy build
  # cũng đi đúng đường của máy người dùng: fontconfig dùng cấu hình dự phòng dựng sẵn (thư mục font
  # mặc định của macOS). CrabbyCut luôn đưa `fontfile=` cho drawtext; libass tìm font qua CoreText.
  rm -rf "$DEPS/etc/fonts"
}
build_libunibreak() { autotools_dep "$DEPSRC/libunibreak"; }
build_libass() {
  # CoreText + fontconfig + libunibreak tự bật khi có.
  autotools_dep "$DEPSRC/libass" --disable-test --disable-compare --disable-profile --disable-fuzz
}
build_zimg() {
  ( cd "$DEPSRC/zimg" && ./autogen.sh )
  autotools_dep "$DEPSRC/zimg"
  # zimg.pc khai `-lstdc++` — macOS không còn libstdc++ (chỉ libc++), configure của FFmpeg sẽ coi
  # như không có zimg. -lc++ đã có sẵn trong --extra-libs.
  sed -i '' 's/-lstdc++//' "$DEPS/lib/pkgconfig/zimg.pc"
}
build_x264() {
  # Mọi độ sâu bit (8 + 10) như gói MSYS2; x264 tự thêm -O3 sau CFLAGS.
  ( cd "$DEPSRC/x264" && ./configure --prefix="$DEPS" --enable-static --enable-pic --disable-cli \
      --disable-opencl --bit-depth=all && make -j"$JOBS" && make install-lib-static )
}
build_x265() {
  # Một libx265.a chứa cả ba độ sâu 8/10/12 bit, đúng cách gói MSYS2 (và Homebrew) dựng.
  local src=$DEPSRC/x265/source b=$DEPSRC/x265/_build
  cmake_dep "$src" "$b/12" -DHIGH_BIT_DEPTH=ON -DMAIN12=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF -DENABLE_SHARED=OFF
  cmake_dep "$src" "$b/10" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_CLI=OFF -DENABLE_SHARED=OFF
  rm -rf "$b/8"; mkdir -p "$b/8"
  cp "$b/10/libx265.a" "$b/8/libx265_main10.a"
  cp "$b/12/libx265.a" "$b/8/libx265_main12.a"
  # cmake_dep xoá thư mục build -> cấu hình 8 bit tự gọi, giữ hai .a vừa chép.
  cmake -S "$src" -B "$b/8" -G Ninja -DCMAKE_INSTALL_PREFIX="$DEPS" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$ARCH" -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DLINKED_10BIT=ON -DLINKED_12BIT=ON -DEXTRA_LINK_FLAGS=-L. \
    -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF
  cmake --build "$b/8" -j"$JOBS"
  ( cd "$b/8" && mv libx265.a libx265_main.a \
      && libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a )
  cmake --install "$b/8"
}
build_dav1d() {
  meson_dep "$DEPSRC/dav1d" -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false
}
build_lame() {
  # config.guess/config.sub của lame 3.100 (2017) không biết arm64-apple-darwin.
  cp "$(ls -d "$(brew --prefix automake)"/share/automake-*/ | head -1)"config.{guess,sub} "$DEPSRC/lame/"
  # Bảng ký hiệu xuất còn tên một hàm đã xoá -> trình liên kết của Apple báo lỗi (Homebrew vá y vậy).
  sed -i '' '/^lame_init_old$/d' "$DEPSRC/lame/include/libmp3lame.sym"
  autotools_dep "$DEPSRC/lame" --disable-frontend --disable-gtktest
}
build_vmaf() {
  meson_dep "$DEPSRC/vmaf/libvmaf" -Denable_tests=false -Denable_docs=false -Denable_tools=false
}

step_deps() {
  build_env
  mkdir -p "$DEPS"
  write_system_pc
  mkdir -p "$WORK/logs"
  local name ver url _ logf stamp
  while IFS='|' read -r name ver url _; do
    # Dựng lại được từng phần: dấu ghi phiên bản + nguồn, khớp thì bỏ qua; đổi phiên bản trong
    # DEP_TABLE là dựng lại (xoá $DEPS/.done-<tên> để ép dựng lại một thư viện).
    stamp="$ver|$url"
    [[ -e $DEPS/.done-$name && $(cat "$DEPS/.done-$name") == "$stamp" ]] && { log "deps: $name (đã có)"; continue; }
    log "deps: $name $ver"
    logf=$WORK/logs/$name.log
    # Chạy nền rồi `wait`, KHÔNG viết `build_x > log || die`: hàm gọi trong ngữ cảnh `||` thì bash
    # tắt `set -e` cho cả thân hàm — một bước hỏng giữa chừng sẽ bị bỏ qua và chạy tiếp.
    "build_$name" > "$logf" 2>&1 &
    wait $! || { tail -n 40 "$logf" >&2; die "dựng $name hỏng — xem $logf"; }
    printf '%s' "$stamp" > "$DEPS/.done-$name"
  done < <(dep_rows)
}

step_configure() {
  build_env
  mkdir -p "$BUILD"
  local extra=()
  [[ -n ${FFMPEG_SRC:-} ]] && extra+=(--extra-version=crabbycut-dev)
  (
    cd "$BUILD"
    # --shlibdir=bin + --install-name-dir=@loader_path: dylib nằm CẠNH ffmpeg/ffprobe và được tìm
    # theo thư mục của chính tệp đang nạp — chép nguyên bin/ đi đâu cũng chạy (như bin/ của Windows).
    # --pkg-config-flags=--static: thư viện ngoài là .a, phải kéo theo cả phụ thuộc riêng của chúng.
    # -lc++: x265, zimg, harfbuzz viết bằng C++, .pc của chúng không khai thư viện chuẩn C++.
    "$SRC/configure" --prefix="$PREFIX" --shlibdir="$PREFIX/bin" --install-name-dir=@loader_path \
      ${extra[@]+"${extra[@]}"} \
      --arch="$ARCH" --cc=clang --cxx=clang++ --pkg-config-flags=--static \
      --extra-cflags="-mmacosx-version-min=$MIN_MACOS -I$DEPS/include" \
      --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -L$DEPS/lib" --extra-libs=-lc++ \
      --enable-gpl --enable-version3 --enable-shared --disable-static \
      --disable-autodetect --disable-doc --disable-debug --disable-ffplay \
      --enable-pthreads --enable-zlib --enable-bzlib --enable-lzma \
      --enable-videotoolbox --enable-audiotoolbox --enable-appkit --enable-coreimage \
      --enable-libzimg --enable-libfreetype --enable-libfribidi --enable-libharfbuzz \
      --enable-fontconfig --enable-libass \
      --enable-libdav1d --enable-libx264 --enable-libx265 --enable-libvmaf --enable-libmp3lame
  ) | tail -n 30
  log "configure: xong"
}

step_make() {
  make -C "$BUILD" -j"$JOBS" >/dev/null
  log "make: xong"
}

# Mọi phụ thuộc của tệp trong thư mục $1 phải là thư viện của macOS (/usr/lib, /System) hoặc một
# dylib nằm ngay trong $1. Một đường dẫn /opt/homebrew hay WORK/... lọt vào là gói chết trên máy
# người dùng. Kèm theo: macOS tối thiểu = $MIN_MACOS, chữ ký (ad-hoc của trình liên kết) còn nguyên.
check_bundle() {
  local dir=$1 f dep _ bad= minos
  for f in "$dir"/ffmpeg "$dir"/ffprobe "$dir"/*.dylib; do
    [[ -L $f ]] && continue
    while read -r dep _; do
      case $dep in
        @loader_path/*) [[ -e $dir/${dep#@loader_path/} ]] || bad+="$dep (của ${f##*/}: không có trong thư mục)"$'\n' ;;
        /usr/lib/*|/System/Library/*) ;;
        *) bad+="$dep (của ${f##*/})"$'\n' ;;
      esac
    done < <(otool -L "$f" | tail -n +2)
    minos=$(vtool -show-build "$f" | awk '/minos/ { print $2; exit }')
    [[ $minos == "$MIN_MACOS" ]] || bad+="${f##*/}: macOS tối thiểu $minos (cần $MIN_MACOS)"$'\n'
    codesign -v "$f" 2>/dev/null || bad+="${f##*/}: chữ ký hỏng"$'\n'
  done
  [[ -z $bad ]] || die "gói không tự đứng được:"$'\n'"$bad"
}

step_install() {
  make -C "$BUILD" install >/dev/null
  check_bundle "$PREFIX/bin"
  log "install: $(ff_version)"
}

step_package() {
  [[ -z ${FFMPEG_SRC:-} ]] || die "không đóng gói bản dựng từ FFMPEG_SRC (bản dev) — chạy lại không có FFMPEG_SRC"
  local out=$DIST/$PKG ver f
  ver=$(ff_version)
  [[ $ver == "ffmpeg version $NAME "* ]] || die "phiên bản lạ: $ver"

  rm -rf "$out" "$DIST/$PKG.zip" "$DIST/$PKG.zip.sha256"
  mkdir -p "$out/bin" "$out/licenses/ffmpeg"
  # Chỉ tệp thật, đúng tên mà ffmpeg/ffprobe tham chiếu (libavcodec.62.dylib): không symlink trong
  # zip, bộ giải nén nào cũng cho ra cùng một thư mục.
  cp "$PREFIX/bin/ffmpeg" "$PREFIX/bin/ffprobe" "$out/bin/"
  for f in "$PREFIX"/bin/lib*.dylib; do
    [[ ${f##*/} =~ ^lib[a-z]+\.[0-9]+\.dylib$ ]] && cp -L "$f" "$out/bin/"
  done
  check_bundle "$out/bin"

  # Kiểm trên chính tệp sẽ đóng gói, không phải trên $PREFIX.
  local bin=$out/bin/ffmpeg help
  [[ $("$bin" -hide_banner -version 2>&1 | head -1) == "$ver" ]] || die "ffmpeg trong gói không chạy được"
  for f in zscale drawtext lut3d xfade tpad sendcmd subtitles libvmaf scale_vt; do
    help=$("$bin" -hide_banner -h "filter=$f" 2>&1 || true)
    [[ $help == *"Filter $f"* ]] || die "thiếu bộ lọc $f"
  done
  for f in h264_videotoolbox hevc_videotoolbox libx264 libx265 prores_ks aac libmp3lame; do
    help=$("$bin" -hide_banner -h "encoder=$f" 2>&1 || true)
    [[ $help == *"Encoder $f"* ]] || die "thiếu encoder $f"
  done

  cp "$HERE/LICENSE" "$out/LICENSE.txt"
  cp "$SRC"/COPYING.* "$SRC/LICENSE.md" "$out/licenses/ffmpeg/"
  local rows= name v url _ src
  while IFS='|' read -r name v url _; do
    src=$DEPSRC/$name
    mkdir -p "$out/licenses/$name"
    for f in "$src"/COPYING* "$src"/LICENSE* "$src"/LICENCE* "$src"/docs/FTL.TXT "$src"/docs/GPLv2.TXT; do
      [[ -f $f ]] && cp "$f" "$out/licenses/$name/"
    done
    ls "$out/licenses/$name" | grep -q . || die "không thấy văn bản giấy phép của $name trong $src"
    rows+=$(printf '  %-12s %-22s %s' "$name" "$v" "${url#git+}")$'\n'
  done < <(dep_rows)
  local patches= p
  while read -r p _; do
    [[ -z $p || $p == \#* ]] && continue
    patches+="  $(shasum -a 256 "$HERE/patches/ffmpeg/$p" | cut -c1-64)  patches/ffmpeg/$p"$'\n'
  done < "$HERE/patches/ffmpeg/series"

  cat > "$out/README.txt" <<EOF
FFmpeg $NAME — bản dựng cho CrabbyCut (macOS $ARCH, shared, GPL v3)
FFmpeg $NAME — the FFmpeg build bundled with CrabbyCut (macOS $ARCH, shared, GPL v3)

$ver
$("$bin" -hide_banner -version 2>&1 | sed -n '/^configuration: /p')

Cùng mã nguồn FFmpeg với bản Windows $NAME; chỉ khác phần tăng tốc phần cứng (VideoToolbox).
Same FFmpeg source as the Windows $NAME build; only the hardware acceleration differs (VideoToolbox).
Chạy trên macOS $MIN_MACOS trở lên; chỉ phụ thuộc thư viện hệ thống của macOS.

MÃ NGUỒN TƯƠNG ỨNG / CORRESPONDING SOURCE
  Kịch bản build + bản vá / build script + patches (build-macos.sh):
    $REPO_URL (tag $RELEASE_TAG)
  FFmpeg $FFMPEG_TAG (commit $(git -C "$SRC" rev-parse HEAD)):
    $FFMPEG_URL
  Thư viện liên kết tĩnh, dựng từ mã nguồn gốc / statically linked libraries, built from upstream source:
$rows
  zlib, bzip2: thư viện hệ thống của macOS / macOS system libraries.

BẢN VÁ / PATCHES (sha256)
$patches
Văn bản giấy phép: LICENSE.txt (GPL v3, áp cho bản dựng này) và thư mục licenses/.
License texts: LICENSE.txt (GPL v3, applies to this build) and the licenses/ folder.
EOF

  # -X: không ghi uid/gid của máy build; quyền chạy (+x) vẫn nằm trong zip.
  (cd "$DIST" && zip -q -r -X "$PKG.zip" "$PKG")
  local sha size
  sha=$(shasum -a 256 "$DIST/$PKG.zip" | cut -c1-64)
  size=$(stat -f %z "$DIST/$PKG.zip")
  echo "$sha  $PKG.zip" > "$DIST/$PKG.zip.sha256"
  log "package: $DIST/$PKG.zip"
  cat <<EOF
Cho scripts/ffmpeg_pin.js của CrabbyCut, mục darwin (sau khi tải zip lên Release $RELEASE_TAG của $REPO_URL):
  id: '$NAME-macos-$ARCH-gpl-shared',
  url: '$REPO_URL/releases/download/$RELEASE_TAG/$PKG.zip',
  fileName: '$PKG.zip',
  sha256: '$sha',
  sizeBytes: $size,
  versionPrefix: 'ffmpeg version $NAME ',
  sourceUrl: '$REPO_URL/tree/$RELEASE_TAG',
EOF
}

steps=("$@")
(( ${#steps[@]} )) || steps=(all)
for s in "${steps[@]}"; do
  case $s in
    all) step_check; step_fetch; step_deps; step_configure; step_make; step_install; step_package ;;
    check|fetch|deps|configure|make|install|package) "step_$s" ;;
    *) die "bước lạ: $s (check fetch deps configure make install package all)" ;;
  esac
done
