#!/usr/bin/env bash
# Dựng bản FFmpeg mà CrabbyCut dùng trên Windows: FFmpeg n8.1.1 + các bản vá trong patches/ffmpeg
# (bộ lọc CUDA crabgeo_cuda / crabblend_cuda và các vá fftools/hwcontext đi kèm), bản shared, GPL v3.
#
# Chạy trong MSYS2 UCRT64 (gói cần cài: msys2-packages.txt):
#   ./build.sh [bước ...]     bước: check fetch configure make install package; mặc định = all
#
# Biến môi trường:
#   WORK=<thư mục>    nơi đặt mã nguồn tải về, thư mục build, install, dist (mặc định ./work)
#   FFMPEG_SRC=<dir>  dùng cây nguồn có sẵn (bản fork đang phát triển, bản vá đã nằm trong commit)
#                     thay cho clone n8.1.1 + áp patches/ffmpeg. Bản dựng mang hậu tố
#                     "-crabbycut-dev" và bước package từ chối đóng gói nó.
#   JOBS=<n>          số luồng make (mặc định nproc)
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAME=$(tr -d '[:space:]' < "$HERE/CRABBYCUT_VERSION")   # vd. n8.1.1-crabbycut.1
REPO_URL=https://github.com/tamphamdesigner92-tb/ffmpeg-for-CrabbyCut
FFMPEG_TAG=n8.1.1
FFMPEG_URL=https://github.com/FFmpeg/FFmpeg.git
# 13.x đòi driver NVIDIA >= 610, mà GTX 9xx/10xx dừng ở nhánh driver R580 -> mất NVENC.
NVCODEC_TAG=n12.2.72.0
NVCODEC_URL=https://github.com/FFmpeg/nv-codec-headers.git
WORK=${WORK:-$HERE/work}
SRC=${FFMPEG_SRC:-$WORK/ffmpeg}
BUILD=$WORK/build
DEPS=$WORK/deps
PREFIX=$WORK/install
DIST=$WORK/dist
JOBS=${JOBS:-$(nproc)}
SYSBIN=/ucrt64/bin
WINSYS=$(cygpath -u "${SYSTEMROOT:-C:\\Windows}")/System32
PKG=ffmpeg-$NAME-win64-gpl-shared

# DLL có trong System32 nhưng VẪN phải kèm theo: libplacebo (avfilter nạp tĩnh) nhập tĩnh
# vulkan-1.dll, mà máy không có driver Vulkan thì không có tệp này -> ffmpeg.exe không chạy nổi
# (bản Gyan nạp Vulkan động nên không gặp). Kèm bộ nạp Vulkan thì máy đó vẫn chạy, chỉ phép dò
# tonemap libplacebo của CrabbyCut thất bại và lùi về zscale.
BUNDLE_ANYWAY='^vulkan-1\.dll$'
# DLL hệ thống được phép nhập tĩnh (có sẵn trên Windows 10+). Thêm phụ thuộc hệ thống mới thì
# phải xem lại ở đây: một DLL của driver (nvcuda.dll, amfrt64.dll...) nhập tĩnh là ffmpeg chết
# trên mọi máy không có driver đó.
SYSTEM_DLLS='^(api-ms-win-[a-z0-9-]+|kernel32|advapi32|user32|gdi32|shell32|shlwapi|ole32|oleaut32|ws2_32|bcrypt|bcryptprimitives|ntdll|userenv|dwrite|usp10|rpcrt4|version|avicap32|cfgmgr32)\.dll$'
# Gói chỉ có header nhưng được biên dịch vào bản dựng (ghi công + giấy phép trong zip).
HEADER_PKGS=(mingw-w64-ucrt-x86_64-amf-headers mingw-w64-ucrt-x86_64-vulkan-headers)

die() { echo "build.sh: $*" >&2; exit 1; }
log() { echo "== $*"; }
# Gọi ffmpeg vừa cài, lấy trọn đầu ra (không nối ống vào grep -q/head: với pipefail, bên đọc đóng
# ống sớm là cả lệnh tính thất bại).
ff() { "$PREFIX/bin/ffmpeg.exe" -hide_banner "$@" 2>&1; }
ff_version() { local v; v=$(ff -version); echo "${v%%$'\n'*}"; }

step_check() {
  [[ ${MSYSTEM:-} == UCRT64 ]] || die "phải chạy trong MSYS2 UCRT64 (MSYSTEM=UCRT64), đang là '${MSYSTEM:-}'"
  local missing
  missing=$(grep -v '^#' "$HERE/msys2-packages.txt" | xargs pacman -T || true)
  [[ -z $missing ]] || die "thiếu gói MSYS2:"$'\n'"$missing"$'\n'"cài: pacman -S --needed $(echo $missing)"
  log "check: đủ gói MSYS2"
}

step_fetch() {
  mkdir -p "$WORK"
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
    # version.sh của FFmpeg lấy chuỗi phiên bản từ tệp VERSION nếu có (như tarball phát hành).
    printf '%s\n' "$NAME" > "$SRC/VERSION"
  fi
  local nv=$WORK/nv-codec-headers
  [[ -d $nv/.git ]] || git clone --depth 1 --branch "$NVCODEC_TAG" "$NVCODEC_URL" "$nv"
  git -C "$nv" reset -q --hard HEAD
  git -C "$nv" clean -qfdx
  # Cài vào WORK/deps (không đụng /ucrt64): configure tìm thấy qua PKG_CONFIG_PATH.
  make -C "$nv" install PREFIX="$DEPS" >/dev/null
  log "fetch: FFmpeg $(git -C "$SRC" describe --tags --always) + nv-codec-headers $NVCODEC_TAG"
}

step_configure() {
  mkdir -p "$BUILD"
  local extra=()
  [[ -n ${FFMPEG_SRC:-} ]] && extra+=(--extra-version=crabbycut-dev)
  (
    cd "$BUILD"
    PKG_CONFIG_PATH="$DEPS/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}" \
    "$SRC/configure" --prefix="$PREFIX" "${extra[@]}" \
      --enable-gpl --enable-version3 --enable-shared --disable-static \
      --disable-autodetect --disable-doc --disable-debug --disable-ffplay \
      --enable-zlib --enable-bzlib --enable-lzma \
      --enable-d3d11va --enable-d3d12va --enable-dxva2 \
      --enable-ffnvcodec --enable-cuda-llvm --enable-cuvid --enable-nvdec --enable-nvenc \
      --enable-amf --enable-libvpl \
      --enable-vulkan --enable-libshaderc --enable-libplacebo \
      --enable-libzimg --enable-libfreetype --enable-libfribidi --enable-libharfbuzz \
      --enable-fontconfig --enable-libass \
      --enable-libdav1d --enable-libx264 --enable-libx265 --enable-libvmaf --enable-libmp3lame
  ) | tail -n 30
  # Header NVIDIA phải là bản vừa cài vào deps, không phải bản nào đó còn nằm trong /ucrt64/include
  # (sửa header đó mà không make clean từng làm ffmpeg sập).
  grep -q 'deps/include' "$BUILD/ffbuild/config.mak" || die "configure không dùng nv-codec-headers trong $DEPS"
  log "configure: xong"
}

step_make() {
  make -C "$BUILD" -j"$JOBS"
  log "make: xong"
}

# Chép (đệ quy) các DLL của MSYS2 mà tệp trong $1 nhập tĩnh.
collect_dlls() {
  local bin=$1 changed=1 f dll
  while (( changed )); do
    changed=0
    for f in "$bin"/*.exe "$bin"/*.dll; do
      for dll in $(objdump -p "$f" | awk '/DLL Name:/{print $3}'); do
        [[ -e $bin/$dll || ! -e $SYSBIN/$dll ]] && continue
        if [[ -e $WINSYS/$dll ]] && ! grep -qiE "$BUNDLE_ANYWAY" <<< "$dll"; then continue; fi
        cp "$SYSBIN/$dll" "$bin/"
        changed=1
      done
    done
  done
}

# Mọi DLL nhập tĩnh mà không nằm cạnh exe phải là DLL hệ thống trong danh sách cho phép.
check_imports() {
  local bin=$1 f dll bad=
  for f in "$bin"/*.exe "$bin"/*.dll; do
    for dll in $(objdump -p "$f" | awk '/DLL Name:/{print $3}'); do
      [[ -e $bin/$dll ]] && continue
      grep -qiE "$SYSTEM_DLLS" <<< "$dll" || bad+="$dll (của $(basename "$f"))"$'\n'
    done
  done
  [[ -z $bad ]] || die "phụ thuộc hệ thống ngoài danh sách SYSTEM_DLLS:"$'\n'"$bad"
}

step_install() {
  make -C "$BUILD" install >/dev/null
  collect_dlls "$PREFIX/bin"
  check_imports "$PREFIX/bin"
  log "install: $(ff_version)"
}

pkg_of() { pacman -Qqo "$1" 2>/dev/null || true; }
pkg_licenses() { pacman -Qi "$1" | sed -n 's/^Licenses *: *//p'; }

# Giấy phép của gói MSYS2 $1 vào thư mục $2 (các tệp trong /ucrt64/share/licenses của gói).
copy_pkg_licenses() {
  local files
  files=$(pacman -Qlq "$1" | grep '/share/licenses/.*[^/]$' || true)
  [[ -z $files ]] && return 0
  mkdir -p "$2"
  while read -r f; do cp "$f" "$2/"; done <<< "$files"
}

step_package() {
  [[ -z ${FFMPEG_SRC:-} ]] || die "không đóng gói bản dựng từ FFMPEG_SRC (bản dev) — chạy lại không có FFMPEG_SRC"
  local out=$DIST/$PKG ver
  ver=$(ff_version)
  [[ $ver == "ffmpeg version $NAME "* ]] || die "phiên bản lạ: $ver"
  local f help
  for f in crabgeo_cuda crabblend_cuda zscale libplacebo drawtext lut3d xfade tpad sendcmd; do
    help=$(ff -h "filter=$f" || true)
    [[ $help == *"Filter $f"* ]] || die "thiếu bộ lọc $f"
  done
  for f in h264_nvenc hevc_nvenc libx264 prores_ks aac libmp3lame; do
    help=$(ff -h "encoder=$f" || true)
    [[ $help == *"Encoder $f"* ]] || die "thiếu encoder $f"
  done

  rm -rf "$out" "$DIST/$PKG.zip" "$DIST/$PKG.zip.sha256"
  mkdir -p "$out/bin" "$out/licenses/ffmpeg" "$out/licenses/nv-codec-headers"
  # Chỉ tệp trong bin/: bộ cài CrabbyCut chép nguyên các tệp của thư mục chứa ffmpeg.exe.
  cp "$PREFIX"/bin/*.exe "$PREFIX"/bin/*.dll "$out/bin/"
  cp "$HERE/LICENSE" "$out/LICENSE.txt"
  cp "$SRC"/COPYING.* "$SRC/LICENSE.md" "$out/licenses/ffmpeg/"
  sed -n '1,/\*\//p' "$WORK/nv-codec-headers/include/ffnvcodec/dynlink_loader.h" > "$out/licenses/nv-codec-headers/LICENSE.txt"

  local rows= dll pkg short
  for dll in $(cd "$out/bin" && ls *.dll); do
    [[ -e $SYSBIN/$dll ]] || continue   # DLL của chính FFmpeg
    pkg=$(pkg_of "$SYSBIN/$dll")
    [[ -n $pkg ]] || die "không biết gói MSYS2 nào cài $dll"
    short=${pkg#mingw-w64-ucrt-x86_64-}
    copy_pkg_licenses "$pkg" "$out/licenses/$short"
    rows+=$(printf '  %-28s %-55s %s' "$dll" "$(pacman -Q "$pkg")" "$(pkg_licenses "$pkg")")$'\n'
  done
  local hdr=
  for pkg in "${HEADER_PKGS[@]}"; do
    short=${pkg#mingw-w64-ucrt-x86_64-}
    copy_pkg_licenses "$pkg" "$out/licenses/$short"
    hdr+=$(printf '  %-55s %s' "$(pacman -Q "$pkg")" "$(pkg_licenses "$pkg")")$'\n'
  done
  local patches= p _
  while read -r p _; do
    [[ -z $p || $p == \#* ]] && continue
    patches+="  $(sha256sum "$HERE/patches/ffmpeg/$p" | cut -c1-64)  patches/ffmpeg/$p"$'\n'
  done < "$HERE/patches/ffmpeg/series"

  cat > "$out/README.txt" <<EOF
FFmpeg $NAME — bản dựng cho CrabbyCut (Windows x64, shared, GPL v3)
FFmpeg $NAME — the FFmpeg build bundled with CrabbyCut (Windows x64, shared, GPL v3)

$ver
$(ff -version | sed -n '/^configuration: /p')

MÃ NGUỒN TƯƠNG ỨNG / CORRESPONDING SOURCE
  Kịch bản build + bản vá / build script + patches:
    $REPO_URL (tag $NAME)
  FFmpeg $FFMPEG_TAG (commit $(git -C "$SRC" rev-parse HEAD)):
    $FFMPEG_URL
  nv-codec-headers $NVCODEC_TAG (commit $(git -C "$WORK/nv-codec-headers" rev-parse HEAD)):
    $NVCODEC_URL
  Thư viện đi kèm lấy từ gói MSYS2 UCRT64 (bảng dưới). Mã nguồn từng gói:
  Bundled libraries come from MSYS2 UCRT64 packages (table below). Package sources:
    https://repo.msys2.org/mingw/sources/   (<gói>-<phiên bản>.src.tar.zst)
    https://github.com/msys2/MINGW-packages (PKGBUILD)

BẢN VÁ / PATCHES (sha256)
$patches
DLL ĐI KÈM / BUNDLED DLLS     gói MSYS2 / MSYS2 package                                giấy phép / licenses
$rows
HEADER BIÊN DỊCH VÀO / HEADERS COMPILED IN
  nv-codec-headers $NVCODEC_TAG                                MIT
$hdr
Văn bản giấy phép: LICENSE.txt (GPL v3, áp cho bản dựng này) và thư mục licenses/.
License texts: LICENSE.txt (GPL v3, applies to this build) and the licenses/ folder.
EOF

  (cd "$DIST" && "$WINSYS/tar.exe" -a -cf "$PKG.zip" "$PKG")
  local sha size
  sha=$(sha256sum "$DIST/$PKG.zip" | cut -c1-64)
  size=$(stat -c %s "$DIST/$PKG.zip")
  echo "$sha  $PKG.zip" > "$DIST/$PKG.zip.sha256"
  log "package: $DIST/$PKG.zip"
  cat <<EOF
Cho scripts/ffmpeg_pin.js của CrabbyCut (sau khi tải zip lên Release $NAME của $REPO_URL):
  id: '$NAME-win64-gpl-shared',
  url: '$REPO_URL/releases/download/$NAME/$PKG.zip',
  fileName: '$PKG.zip',
  sha256: '$sha',
  sizeBytes: $size,
  versionPrefix: 'ffmpeg version $NAME ',   // dấu cách cuối: .1 không được khớp .10
EOF
}

steps=("$@")
(( ${#steps[@]} )) || steps=(all)
for s in "${steps[@]}"; do
  case $s in
    all) step_check; step_fetch; step_configure; step_make; step_install; step_package ;;
    check|fetch|configure|make|install|package) "step_$s" ;;
    *) die "bước lạ: $s (check fetch configure make install package all)" ;;
  esac
done
