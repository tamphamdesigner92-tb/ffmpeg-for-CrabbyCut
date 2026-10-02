# Đăng ký bộ lọc CUDA mới của CrabbyCut vào configure / libavfilter/allfilters.c / libavfilter/Makefile
# của một cây nguồn FFmpeg (chạy lại được: bộ lọc đã có thì bỏ qua).
#   python tools/register_filters.py <thư mục nguồn FFmpeg> <tên> [<tên> ...]   vd. crablut_cuda
# Bộ lọc cần vf_<tên>.c + vf_<tên>.cu (kernel, clang dịch ra PTX khi --enable-cuda-llvm).
# Sau đó configure lại (./build.sh configure make install).
import os
import sys


def insert_after(src, path, anchor, addition, marker, group):
    """Chèn `addition` sau `anchor` và sau mọi dòng ngay sau nó có chứa `group`
    (các bộ lọc crab* đăng ký trước), để thứ tự đăng ký giữ đúng thứ tự thêm."""
    full = os.path.join(src, path)
    with open(full, encoding='utf-8', newline='') as f:
        s = f.read()
    if marker in s:
        return f'{path}: đã có'
    eol = '\r\n' if '\r\n' in s else '\n'
    anchor = anchor.replace('\n', eol)
    addition = addition.replace('\n', eol)
    i = s.find(anchor)
    if i < 0:
        raise SystemExit(f'{path}: không thấy mốc {anchor!r}')
    j = i + len(anchor)
    while True:
        k = s.find(eol, j)
        if k < 0 or group not in s[j:k]:
            break
        j = k + len(eol)
    s = s[:j] + addition + s[j:]
    with open(full, 'w', encoding='utf-8', newline='') as f:
        f.write(s)
    return f'{path}: đã thêm'


def main():
    if len(sys.argv) < 3:
        raise SystemExit('dùng: python tools/register_filters.py <thư mục nguồn FFmpeg> <tên> [<tên> ...]')
    src = sys.argv[1]
    for name in sys.argv[2:]:
        up = name.upper()
        print(insert_after(src, 'configure', 'overlay_cuda_filter_deps_any="cuda_nvcc cuda_llvm"\n',
                           f'{name}_filter_deps="ffnvcodec"\n{name}_filter_deps_any="cuda_nvcc cuda_llvm"\n',
                           f'{name}_filter_deps=', 'crab'))
        print(insert_after(src, 'libavfilter/allfilters.c', 'extern const FFFilter ff_vf_overlay_cuda;\n',
                           f'extern const FFFilter ff_vf_{name};\n', f'ff_vf_{name};', 'ff_vf_crab'))
        key = f'OBJS-$(CONFIG_{up}_FILTER)'
        pad = ' ' * max(1, 45 - len(key))
        print(insert_after(src, 'libavfilter/Makefile', '# video filters\n',
                           f'{key}{pad}+= vf_{name}.o framesync.o vf_{name}.ptx.o cuda/load_helper.o\n',
                           f'CONFIG_{up}_FILTER', 'CONFIG_CRAB'))


if __name__ == '__main__':
    main()
