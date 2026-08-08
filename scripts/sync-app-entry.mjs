import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const cwd = process.cwd();
const sourceIndex = path.resolve(cwd, 'index.html');
const simpleReaderHtml = path.resolve(cwd, 'simple-reader.html');
const standaloneHtml = path.resolve(cwd, '英语长难句交互阅读解析.html');
const localConfig = path.resolve(cwd, 'local-config.js');
const appServer = path.resolve(cwd, 'scripts/reader_app_server.py');
const cosyvoiceServer = path.resolve(cwd, 'scripts/cosyvoice_server.py');
const macAppLauncher = path.resolve(cwd, 'scripts/mac-app-launcher.sh');
const vendorDir = path.resolve(cwd, 'vendor');
// The primary generated directory contains the live bundled library plus the
// TPO import pack. A historical “final” directory may exist but is not a
// complete deployment source and can silently omit newly generated bundles.
const generatedReaderJsonDir = path.resolve(cwd, 'data/generated-reader-json');
const installedAppIndex = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/index.html'
);
const installedStandaloneHtml = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/英语长难句交互阅读解析.html'
);
const installedSimpleReaderHtml = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/simple-reader.html'
);
const installedAppLocalConfig = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/local-config.js'
);
const installedAppServer = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/reader_app_server.py'
);
const installedCosyvoiceServer = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/cosyvoice_server.py'
);
const installedAppLauncher = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/MacOS/launcher'
);
const installedAppVendorDir = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/vendor'
);
const installedGeneratedReaderJsonDir = path.resolve(
  os.homedir(),
  'Applications/英语长难句阅读器.app/Contents/Resources/data/generated-reader-json'
);

const syncTargets = [
  { label: '仓库单文件入口', target: standaloneHtml, required: true },
  { label: '已安装 App 入口', target: installedAppIndex, required: true },
  { label: '已安装 App 单文件入口', target: installedStandaloneHtml, required: false },
  { label: '已安装 App 简化阅读器', target: installedSimpleReaderHtml, required: false, source: simpleReaderHtml },
  { label: '已安装 App 私有配置', target: installedAppLocalConfig, required: false, source: localConfig },
  { label: '已安装 App 本地服务', target: installedAppServer, required: false, source: appServer },
  { label: '已安装 App CosyVoice 服务', target: installedCosyvoiceServer, required: false, source: cosyvoiceServer },
  { label: '已安装 App 启动器', target: installedAppLauncher, required: false, source: macAppLauncher }
];

if (!fs.existsSync(sourceIndex)) {
  console.error(`未找到源文件: ${sourceIndex}`);
  process.exit(1);
}

const results = [];

for (const item of syncTargets) {
  const sourcePath = item.source || sourceIndex;
  if (!fs.existsSync(sourcePath)) {
    if (item.required) {
      console.error(`缺少源文件: ${sourcePath}`);
      process.exit(1);
    }
    results.push({ ...item, status: 'skipped', reason: 'source file missing' });
    continue;
  }
  if (!fs.existsSync(path.dirname(item.target))) {
    if (item.required) {
      console.error(`缺少目标目录: ${path.dirname(item.target)}`);
      process.exit(1);
    }
    results.push({ ...item, status: 'skipped', reason: 'target directory missing' });
    continue;
  }

  fs.writeFileSync(item.target, fs.readFileSync(sourcePath));
  if (item.target.endsWith('launcher') || item.source?.endsWith('.sh')) {
    fs.chmodSync(item.target, 0o755);
  }
  results.push({ ...item, status: 'synced' });
}

if (fs.existsSync(vendorDir)) {
  fs.mkdirSync(installedAppVendorDir, { recursive: true });
  for (const name of fs.readdirSync(vendorDir)) {
    const sourcePath = path.join(vendorDir, name);
    const targetPath = path.join(installedAppVendorDir, name);
    if (fs.statSync(sourcePath).isFile()) {
      fs.writeFileSync(targetPath, fs.readFileSync(sourcePath));
      results.push({
        label: `已安装 App vendor/${name}`,
        target: targetPath,
        required: false,
        source: sourcePath,
        status: 'synced'
      });
    }
  }
}

if (fs.existsSync(generatedReaderJsonDir)) {
  fs.rmSync(installedGeneratedReaderJsonDir, { recursive: true, force: true });
  fs.mkdirSync(path.dirname(installedGeneratedReaderJsonDir), { recursive: true });
  fs.cpSync(generatedReaderJsonDir, installedGeneratedReaderJsonDir, { recursive: true });
  results.push({
    label: '已安装 App generated-reader-json',
    target: installedGeneratedReaderJsonDir,
    required: false,
    source: generatedReaderJsonDir,
    status: 'synced'
  });
}

console.log(JSON.stringify({
  source: sourceIndex,
  results
}, null, 2));
