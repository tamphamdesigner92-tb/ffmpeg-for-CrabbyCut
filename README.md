# ffmpeg-for-CrabbyCut

Bản FFmpeg mà [CrabbyCut](https://github.com/tamphamdesigner92-tb/CrabbyCut) tải về khi cài trên
Windows: **FFmpeg n8.1.1** cộng các bộ lọc CUDA riêng của CrabbyCut, để máy có GPU NVIDIA xuất
video hoàn toàn trên GPU (NVDEC giải mã → co/cắt/đổi màu và ghép lớp phủ trên GPU → NVENC mã hoá).
Máy không có NVIDIA vẫn dùng bản này như một FFmpeg bình thường (CUDA được nạp động).

Repo chỉ chứa **kịch bản build + bản vá**; mã nguồn FFmpeg được tải về lúc build. Bản dựng sẵn
(zip) nằm ở mục [Releases](https://github.com/tamphamdesigner92-tb/ffmpeg-for-CrabbyCut/releases).

> **English.** Build script and patches for the FFmpeg build that CrabbyCut downloads on Windows:
> FFmpeg n8.1.1 plus CrabbyCut's own CUDA filters (`crabgeo_cuda`, `crabblend_cuda`) so exports can
> stay on the GPU end to end. `./build.sh` (MSYS2 UCRT64) clones FFmpeg `n8.1.1` and
> nv-codec-headers `n12.2.72.0`, applies `patches/ffmpeg/*`, builds a shared GPL v3 build and
> packages it with every DLL it needs plus license texts and a manifest of exact library versions.
> This repository together with the upstream sources it names is the corresponding source of the
> binaries published under Releases.

## Trong repo

| Đường dẫn | Là gì |
|---|---|
| `build.sh` | Dựng từ đầu: kiểm gói → tải nguồn → áp bản vá → configure → make → install → đóng zip |
| `CRABBYCUT_VERSION` | Tên bản phát hành (`n8.1.1-crabbycut.N`) = chuỗi `ffmpeg -version` = tên tag/Release |
| `patches/ffmpeg/` | Bản vá áp lên FFmpeg n8.1.1, thứ tự trong `series` |
| `msys2-packages.txt` | Gói MSYS2 cần cài |
| `scripts/export-patches.sh` | Sinh lại `patches/ffmpeg` từ nhánh của bản fork đang phát triển |
| `tools/register_filters.py` | Đăng ký bộ lọc CUDA mới vào configure / allfilters.c / Makefile |
| `tests/blend_exact.js` | `crabblend_cuda` phải trùng từng bit với `overlay=format=yuv420` (CPU) |
| `tests/geo_check.js` | `crabgeo_cuda` so với chuỗi lọc CPU tương ứng (cần dữ liệu thử của CrabbyCut) |

## Bản vá làm gì

- **`crabgeo_cuda`** — một bộ lọc thay cho chuỗi `crop/scale/format/pad/crop/scale` của đường CPU:
  cắt vùng nguồn (toạ độ lẻ, số thực), co (bicubic như swscale / bilinear / nearest), đặt vào khung
  ra có nền đen hoặc trong suốt, đổi ma trận/dải màu (bt601/bt709, tv/pc), ra `yuv420p`, `yuv444p`,
  `yuva420p`, `nv12`, `p010le`; ảnh RGBA lấy màu 4:2:0 trung bình theo alpha (`alpha_chroma=1`).
  Từ `n8.1.1-crabbycut.2`: LUT 3D `.cube` áp lên nội dung sau phép co (`lut=`, thêm `lut2=` +
  `mix=<biểu thức theo t>` để trộn hai LUT theo keyframe cường độ) — nội suy ba chiều như `lut3d`
  `interp=trilinear`, tính float từ khung nguồn 10-bit chứ không qua RGB 8-bit.
- **`crabblend_cuda`** — trộn lớp phủ đúng phép nguyên của `vf_overlay` ở chế độ alpha thẳng (trùng
  từng bit với bản CPU), `x`/`y`/`opacity` là biểu thức tính theo từng khung (keyframe độ mờ).
- Cả hai mặc định `sync=1`: chờ GPU xong từng khung rồi mới đưa đi. Không chờ thì bản xuất có khung
  rách / lớp phủ lệch thời gian khi nhiều lượt xuất chạy song song (đo 2026-10-02).
- `fftools`: không dựng lại cả đồ thị lọc khi khung chỉ đổi `hw_frames_ctx` mà định dạng và cỡ giữ
  nguyên (NVDEC khởi tạo lại sau khi tua) — trước đây `trim`/`concat` mất trạng thái.
- `hwdownload` nhận khung từ vùng nhớ tương thích; `hwcontext_cuda` chép đủ hàng màu cuối khi chiều
  cao lẻ và chờ GPU khi tải lên.

## Build

1. Cài [MSYS2](https://www.msys2.org/), mở shell **UCRT64**, cài gói:
   ```bash
   pacman -S --needed $(grep -v '^#' msys2-packages.txt)
   ```
2. Dựng (cần mạng để clone FFmpeg và nv-codec-headers; ~10–20 phút trên máy 8 nhân):
   ```bash
   ./build.sh                      # = check fetch configure make install package
   WORK=/d/ffbuild ./build.sh      # đặt thư mục làm việc ở chỗ khác (mặc định ./work)
   ./build.sh make install         # chạy lại từng bước
   ```
3. Kết quả: `work/dist/ffmpeg-<bản>-win64-gpl-shared.zip` + `.sha256`. Zip có `bin/` (ffmpeg.exe,
   ffprobe.exe và mọi DLL cần), `LICENSE.txt`, `licenses/`, và `README.txt` ghi commit FFmpeg, mã
   băm bản vá, phiên bản từng gói MSYS2 của các DLL đi kèm.

Kịch bản dừng lại nếu một DLL ngoài danh sách DLL hệ thống được nhập tĩnh — vd. DLL của driver
(`nvcuda.dll`) nhập tĩnh là ffmpeg không chạy được trên máy không có driver đó. Bộ nạp Vulkan
(`vulkan-1.dll`) được kèm theo dù Windows có thể đã có: `libplacebo` nhập tĩnh nó, máy không có
driver Vulkan sẽ không có tệp này.

Nhánh nv-codec-headers dừng ở 12.2: bản 13.x đòi driver NVIDIA ≥ 610, mà GTX 9xx/10xx dừng ở R580.

## Phát hành bản mới

1. Tăng `CRABBYCUT_VERSION` (`n8.1.1-crabbycut.2`, ...).
2. Dựng sạch: `rm -rf work && ./build.sh`.
3. Giải nén zip, chạy bộ test xuất video của CrabbyCut với `bin/` của zip đứng đầu PATH, ở chế độ
   GPU tự động và `CRABBYCUT_EXPORT_GPU=0` (xem `docs/APP_INTERNALS.md` của CrabbyCut).
4. Commit, tag đúng tên trong `CRABBYCUT_VERSION`, push; tạo Release cho tag đó và tải zip lên.
5. Sửa `scripts/ffmpeg_pin.js` của CrabbyCut theo các dòng `build.sh` in ra cuối bước package.

## Phát triển bộ lọc

- Bản fork: clone FFmpeg `n8.1.1`, tạo nhánh, `git am patches/ffmpeg/*.patch` theo thứ tự `series`.
- Dựng từ bản fork (không áp bản vá, phiên bản mang hậu tố `-crabbycut-dev`, không đóng gói được):
  ```bash
  FFMPEG_SRC=/d/fork WORK=/d/ffdev ./build.sh fetch configure make install   # ra /d/ffdev/install/bin
  ```
- Bộ lọc mới: viết `libavfilter/vf_<tên>.c` + `vf_<tên>.cu`, rồi
  `python tools/register_filters.py <fork> <tên>` và `./build.sh configure make install`.
- Kiểm: `FFMPEG_BIN=/d/ffdev/install/bin node tests/blend_exact.js`.
- Commit vào bản fork, rồi `scripts/export-patches.sh <fork>` để cập nhật `patches/ffmpeg`
  (`PATCH_AUTHOR='"Tên" <email>'` để mọi bản vá ghi cùng một danh tính tác giả).
- Bẫy đã gặp: lượt chạy sập thường "nhanh" hơn — đo A/B phải xem mã thoát từng lượt; mọi bộ lọc CUDA
  mới phải chờ GPU từng khung (như `sync=1`), không thì khung rách khi chạy song song.

## Giấy phép

Bản dựng bật `--enable-gpl --enable-version3` (x264, x265) nên **bản nhị phân phát hành theo GPL v3**
([`LICENSE`](LICENSE)). Mã trong bản vá theo giấy phép của tệp FFmpeg mà nó sửa hoặc thêm vào
(LGPL 2.1 trở lên cho libavfilter/libavutil/fftools). Không bật `--enable-nonfree`.
