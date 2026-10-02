// crabblend_cuda phải trùng từng bit với overlay=format=yuv420 (CPU) ở mọi ca không có độ mờ. Ca có độ
// mờ chỉ cần PSNR >= 60 dB: CPU nhân độ mờ vào alpha ở 4:4:4 rồi mới hạ mẫu, GPU nhân sau -> lệch ±1 mức.
// FFMPEG_BIN=<thư mục chứa ffmpeg.exe> node tests/blend_exact.js   (cần GPU NVIDIA; mã thoát 1 = có ca trượt)
const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const die = (msg) => { console.error(msg); process.exit(2); };
const DEV = process.env.FFMPEG_BIN || die('đặt FFMPEG_BIN = thư mục chứa ffmpeg.exe cần kiểm (vd. work/install/bin)');
const OUT = path.join(require('os').tmpdir(), 'crabbycut-ffmpeg-tests');
fs.mkdirSync(OUT, { recursive: true });
const env = { ...process.env, PATH: `${DEV};C:\\Windows\\System32` };
const ff = (args) => spawnSync(path.join(DEV, 'ffmpeg.exe'), ['-hide_banner', '-nostdin', '-v', 'error', ...args], { encoding: 'utf8', env });

// lớp phủ: testsrc 333x201 (lẻ cả hai chiều) + alpha = gradient + vòng tròn mép mềm
const ov = path.join(OUT, 'ov.mkv');
let r = ff(['-y', '-f', 'lavfi', '-i', 'testsrc=s=333x201:r=25:d=0.4', '-f', 'lavfi', '-i', 'gradients=s=333x201:r=25:d=0.4:c0=black:c1=white:x0=0:y0=0:x1=332:y1=200',
  '-filter_complex', '[1:v]format=gray,geq=lum=\'clip(lum(X,Y)*1.2-20+40*sin(X/9),0,255)\'[a];[0:v][a]alphamerge,format=yuva420p', '-c:v', 'ffv1', ov]);
if (r.status) throw new Error(r.stderr);
const main = path.join(OUT, 'main.mkv');
r = ff(['-y', '-f', 'lavfi', '-i', 'testsrc2=s=1280x720:r=25:d=0.4', '-pix_fmt', 'yuv420p', '-c:v', 'ffv1', main]);
if (r.status) throw new Error(r.stderr);

const run = (filter, gpu, out) => {
  const args = ['-i', main, '-i', ov];
  if (gpu) args.unshift('-init_hw_device', 'cuda=cu', '-filter_hw_device', 'cu');
  const res = ff([...args, '-filter_complex', filter, '-y', '-c:v', 'ffv1', out]);
  if (res.status) throw new Error(res.stderr);
  return out;
};
const md5 = (file) => ff(['-i', file, '-f', 'framemd5', '-']).stdout.split(/\r?\n/)
  .filter((l) => l && !l.startsWith('#')).map((l) => l.split(',').pop().trim());
const psnr = (a, b) => {
  const res = spawnSync(path.join(DEV, 'ffmpeg.exe'), ['-hide_banner', '-nostdin', '-i', a, '-i', b, '-lavfi', '[0:v][1:v]psnr', '-f', 'null', '-'], { encoding: 'utf8', env });
  const m = res.stderr.match(/average:([\d.]+|inf)/);
  return m ? (m[1] === 'inf' ? Infinity : Number(m[1])) : NaN;
};
const cases = [
  { name: 'giữa khung', x: 400, y: 200 },
  { name: 'lấn trái + x lẻ', x: -121, y: 51 },
  { name: 'lấn phải-dưới', x: 1100, y: 640 },
  { name: 'lấn mép trên', x: 300, y: -60 },
  { name: 'độ mờ 0.48', x: 500, y: 300, opacity: 0.48, minPsnr: 60 },
];
let fail = 0;
for (const [i, c] of cases.entries()) {
  const cpuOp = c.opacity ? `,format=yuva444p,colorchannelmixer=aa=${c.opacity},format=yuva420p` : '';
  const cpu = run(`[1:v]format=yuva420p${cpuOp}[o];[0:v][o]overlay=x=${c.x}:y=${c.y}:format=yuv420`, false, path.join(OUT, `blend_${i}_cpu.mkv`));
  const gpu = run(`[0:v]hwupload_cuda[m];[1:v]format=yuva420p,hwupload_cuda[o];[m][o]crabblend_cuda=x=${c.x}:y=${c.y}${c.opacity ? ':opacity=' + c.opacity : ''},hwdownload,format=yuv420p`, true, path.join(OUT, `blend_${i}_gpu.mkv`));
  const a = md5(cpu), b = md5(gpu);
  const same = a.filter((h, k) => h === b[k]).length;
  let ok = a.length > 0 && same === a.length && a.length === b.length;
  let note = `${same}/${a.length} khung trùng md5`;
  if (c.minPsnr) {
    const db = psnr(gpu, cpu);
    ok = a.length > 0 && a.length === b.length && db >= c.minPsnr;
    note += `, PSNR ${db} dB (cần >= ${c.minPsnr})`;
  }
  if (!ok) fail++;
  console.log(`${ok ? 'ĐẠT ' : 'TRƯỢT'}  ${c.name}: ${note}`);
}
process.exitCode = fail ? 1 : 0;
