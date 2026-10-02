// crabgeo_cuda so với chuỗi CPU tương ứng của sidecar (PSNR theo từng mặt phẳng, khung tệ nhất).
// FFMPEG_BIN=<thư mục chứa ffmpeg.exe> CRABBYCUT_FIXTURES=<...> node tests/geo_check.js [regex tên ca]
// Chỉ in số đo (không có ngưỡng đạt/trượt). Số tham chiếu (2026-10-02, GTX 1060): nv12_copy trùng md5
// từng khung; dscf_4k_1080 so bản chuẩn GPU 53,3 dB / CPU 44,6; p010_yeucon 52,3 / 54,7; png_alpha ~77 dB.
const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const die = (msg) => { console.error(msg); process.exit(2); };
const DEV = process.env.FFMPEG_BIN || die('đặt FFMPEG_BIN = thư mục chứa ffmpeg.exe cần kiểm (vd. work/install/bin)');
const OUT = path.join(require('os').tmpdir(), 'crabbycut-ffmpeg-tests');
const FIX = process.env.CRABBYCUT_FIXTURES || die('đặt CRABBYCUT_FIXTURES = test_temp/bench_export của repo CrabbyCut (cần payload Bin_Tom_-_Tap_3, test_crab, yeu_con_1)');
fs.mkdirSync(OUT, { recursive: true });
const env = { ...process.env, PATH: `${DEV};C:\\Windows\\System32` };
const ff = (args) => spawnSync(path.join(DEV, 'ffmpeg.exe'), ['-hide_banner', '-nostdin', '-v', 'error', ...args], { encoding: 'utf8', env, maxBuffer: 1 << 26 });
const only = process.argv[2] ? new RegExp(process.argv[2]) : null;

function run(name, inputArgs, cpuVf, gpuVf, fmt, opts = {}) {
  if (only && !only.test(name)) return;
  const cpu = path.join(OUT, `geo_${name}_cpu.mkv`);
  const gpu = path.join(OUT, `geo_${name}_gpu.mkv`);
  const gold = opts.goldVf ? path.join(OUT, `geo_${name}_gold.mkv`) : null;
  let r = ff(['-y', ...inputArgs, '-vf', cpuVf, '-an', '-c:v', 'ffv1', cpu]);
  if (r.status) { console.log(`${name}: CPU lỗi ${r.stderr.slice(-300)}`); return; }
  const hw = opts.hwdec === false ? ['-init_hw_device', 'cuda=cu', '-filter_hw_device', 'cu']
    : ['-init_hw_device', 'cuda=cu', '-filter_hw_device', 'cu', '-hwaccel', 'cuda', '-hwaccel_device', 'cu', '-hwaccel_output_format', 'cuda'];
  const t0 = Date.now();
  r = ff(['-y', ...hw, ...inputArgs, '-vf', `${gpuVf},hwdownload,format=${fmt}`, '-an', '-c:v', 'ffv1', gpu]);
  const ms = Date.now() - t0;
  if (r.status) { console.log(`${name}: GPU lỗi ${r.stderr.slice(-400)}`); return; }
  const cmp = (a, b) => {
    const p = spawnSync(path.join(DEV, 'ffmpeg.exe'), ['-hide_banner', '-nostdin', '-i', a, '-i', b, '-lavfi', '[0:v][1:v]psnr', '-f', 'null', '-'], { encoding: 'utf8', env });
    const m = p.stderr.match(/PSNR y:([\d.inf]+) u:([\d.inf]+) v:([\d.inf]+) average:([\d.inf]+) min:([\d.inf]+)/);
    return m ? `Y ${m[1]} U ${m[2]} V ${m[3]}${m[4] ? " A " + m[4] : ""} (TB ${m[5]}, tệ nhất ${m[6]})` : p.stderr.slice(-200);
  };
  let line = `${name}: GPU/CPU ${cmp(gpu, cpu)}`;
  if (opts.exact) {
    const h = (f) => ff(['-i', f, '-f', 'framemd5', '-']).stdout.split(/\r?\n/).filter((l) => l && !l.startsWith('#')).map((l) => l.split(',').pop().trim());
    const a = h(cpu), b = h(gpu);
    line += ` | md5 trùng ${a.filter((x, i) => x === b[i]).length}/${a.length}`;
  }
  if (gold) {
    r = ff(['-y', ...inputArgs, '-vf', opts.goldVf, '-an', '-c:v', 'ffv1', gold]);
    if (!r.status) line += `\n    so bản chuẩn: GPU ${cmp(gpu, gold)}\n                  CPU ${cmp(cpu, gold)}`;
  }
  console.log(line + `  [GPU ${ms} ms]`);
}

const binTom = path.join(FIX, 'Bin_Tom_-_Tap_3/temp/temp_input.mp4');
const dscf = path.join(FIX, 'test_crab/temp/DSCF3442.MOV');
const tcIn = path.join(FIX, 'test_crab/temp/temp_input.mp4');
const yeucon = path.join(FIX, 'yeu_con_1/temp/temp_input.mp4');
const LZ = 'flags=lanczos+accurate_rnd+full_chroma_int+full_chroma_inp';

run('nv12_copy', ['-t', '2', '-i', binTom], 'format=yuv420p', 'crabgeo_cuda=format=yuv420p', 'yuv420p', { exact: true });
run('dscf_4k_1080', ['-t', '1', '-i', dscf], 'scale=w=1920:h=1080:out_color_matrix=bt709:out_range=tv,format=yuv420p',
  'crabgeo_cuda=w=1920:h=1080', 'yuv420p', { goldVf: `scale=w=1920:h=1080:${LZ}:out_color_matrix=bt709:out_range=tv,format=yuv420p` });
// clip 0 của Test.crab: crop 2304x756@768,702 -> 3498x1148 -> cửa sổ 1920x1080 tại 789,34
run('tc_clip0', ['-t', '1', '-i', tcIn],
  'crop=w=2304:h=756:x=768:y=702:exact=1,scale=w=3498:h=1148:out_color_matrix=bt709:out_range=tv:in_h_chr_pos=0:out_h_chr_pos=256,crop=w=1920:h=1080:x=789:y=34:exact=1,format=yuv420p',
  'crabgeo_cuda=crop_x=768:crop_y=702:crop_w=2304:crop_h=756:w=3498:h=1148:ow=1920:oh=1080:x=-789:y=-34', 'yuv420p',
  { goldVf: `crop=w=2304:h=756:x=768:y=702:exact=1,scale=w=3498:h=1148:${LZ}:out_color_matrix=bt709:out_range=tv,crop=w=1920:h=1080:x=789:y=34:exact=1,format=yuv420p` });
run('p010_yeucon', ['-t', '1', '-i', yeucon], 'scale=w=1080:h=1920:out_color_matrix=bt709:out_range=tv,format=yuv420p',
  'crabgeo_cuda=w=1080:h=1920', 'yuv420p', { goldVf: `scale=w=1080:h=1920:${LZ}:out_color_matrix=bt709:out_range=tv,format=yuv420p` });
// lớp phủ PNG chữ của Bin Tom: RGBA -> yuva420p, đệm 4 px trong suốt, màu mép theo alpha
const png = fs.readdirSync(path.join(FIX, 'Bin_Tom_-_Tap_3/temp/editing_assets/generated_text')).find((d) => d.startsWith('anim_item_text'));
const pngDir = path.join(FIX, 'Bin_Tom_-_Tap_3/temp/editing_assets/generated_text', png);
const alphaCpu = 'scale=max(2\\,ceil(iw/2)*2):max(2\\,ceil(ih/2)*2),format=rgba,pad=w=iw+4:h=ih+4:x=0:y=0:color=black@0,split[p][q];'
  + '[p]scale=out_color_matrix=bt709:out_range=tv,format=yuva444p[p8];'
  + '[q]scale=out_color_matrix=bt709:out_range=tv,format=yuva444p16le,premultiply=inplace=1,scale=w=iw/2:h=ih/2:flags=area,unpremultiply=inplace=1,scale=sws_dither=none,format=yuva444p[c8];'
  + '[p8][c8]mergeplanes=map0s=0:map0p=0:map1s=1:map1p=1:map2s=1:map2p=2:map3s=0:map3p=3:format=yuva420p';
run('png_alpha', ['-framerate', '30', '-start_number', '0', '-i', path.join(pngDir, 'frame_%04d.png').replace(/\\/g, '/'), '-frames:v', '20'],
  alphaCpu, 'hwupload_cuda,crabgeo_cuda=w=ceil(iw/2)*2:h=ceil(ih/2)*2:ow=w+4:oh=h+4:x=0:y=0:format=yuva420p:bg=transparent:alpha_chroma=1',
  'yuva420p', { hwdec: false });
