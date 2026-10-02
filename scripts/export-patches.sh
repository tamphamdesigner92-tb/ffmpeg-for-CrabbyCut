#!/usr/bin/env bash
# Sinh lại patches/ffmpeg (+ series) từ nhánh của bản fork đang phát triển.
#   scripts/export-patches.sh <thư mục fork> [<gốc>=n8.1.1]
# Bản fork = clone FFmpeg ở <gốc> + mỗi thay đổi của CrabbyCut là một commit trên đó.
# PATCH_AUTHOR='"Tên" <email>' thay dòng From: của mọi bản vá (để mọi bản vá ghi cùng một danh tính
# tác giả, bất kể commit trong bản fork được tạo bằng cấu hình git nào).
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FORK=${1:?cần đường dẫn bản fork}
BASE=${2:-n8.1.1}
OUT=$HERE/patches/ffmpeg
[[ -z $(git -C "$FORK" status --porcelain --untracked-files=no) ]] || { echo "bản fork còn thay đổi chưa commit" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# --zero-commit: dòng "From <hash>" thành 0000..., bản vá không đổi khi chỉ commit được dựng lại.
git -C "$FORK" format-patch --zero-commit --no-signature --numbered-files -o "$tmp" "$BASE..HEAD" > /dev/null
rm -f "$OUT"/[0-9][0-9][0-9][0-9].patch
mapfile -t subjects < <(git -C "$FORK" log --reverse --format=%s "$BASE..HEAD")
{
  echo "# Bản vá áp lên FFmpeg $BASE, theo đúng thứ tự dưới đây (build.sh đọc tệp này)."
  echo "# Sinh lại bằng scripts/export-patches.sh từ nhánh của bản fork."
  for i in "${!subjects[@]}"; do
    name=$(printf '%04d.patch' $((i + 1)))
    if [[ -n ${PATCH_AUTHOR:-} ]]; then
      awk -v a="From: $PATCH_AUTHOR" 'NR == 2 && /^From: / { print a; next } { print }' "$tmp/$((i + 1))" > "$OUT/$name"
    else
      mv "$tmp/$((i + 1))" "$OUT/$name"
    fi
    echo "$name  ${subjects[$i]#CrabbyCut: }"
  done
} > "$OUT/series"
cat "$OUT/series"
