# Tessell mruby P0 构建脚本（plan T0.1）。
#
# 职责：
# 1. shards install
# 2. 准备 mrb 链接产物（lib/mrb/lib/{libmruby.a,libmruby.lib,mrb_shim.o,mrb_shim.obj}）：
#    - 优先从同级 checkout（..\mrb.cr\lib）拷贝（链接名归一化，两种后缀都备齐）；
#    - 否则在已安装的 mrb shard 内执行其 make（需要 ruby + gcc + 网络）。
# 3. --release 构建 demo 两个 exe（debug 构建在本机 binutils 2.47 快照上会
#    触发 ld 崩溃，见 docs/go-no-go.md；release 一律可用）。
# 4. crystal spec
# 5. G1-G6 门禁（--demo-gates --json），JSON 落 artifacts/gates.json。
#
# 用法：powershell -ExecutionPolicy Bypass -File scripts\build.ps1
$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
Write-Host "== tessell-mruby build in $root"

New-Item -ItemType Directory -Force -Path "$root\bin", "$root\artifacts" | Out-Null

# ---- 1) shards ----
Write-Host "== shards install"
shards install
if ($LASTEXITCODE -ne 0) { throw "shards install failed" }

# ---- 2) mrb 链接产物 ----
$mrbLib = Join-Path $root "lib\mrb\lib"
$needed = @("libmruby.a", "libmruby.lib", "mrb_shim.o", "mrb_shim.obj")
$missing = $needed | Where-Object { -not (Test-Path (Join-Path $mrbLib $_)) }
if ($missing.Count -eq 0) {
  Write-Host "== mrb artifacts present in $mrbLib"
} else {
  New-Item -ItemType Directory -Force -Path $mrbLib | Out-Null
  $sibling = Join-Path (Split-Path -Parent $root) "mrb.cr\lib"
  if ((Test-Path (Join-Path $sibling "libmruby.a")) -and (Test-Path (Join-Path $sibling "mrb_shim.o"))) {
    Write-Host "== copying mrb artifacts from sibling checkout $sibling"
    foreach ($f in $needed) {
      Copy-Item (Join-Path $sibling $f) (Join-Path $mrbLib $f) -Force
    }
  } else {
    Write-Host "== building mruby inside lib\mrb (make: ruby + gcc + network required)"
    Push-Location (Join-Path $root "lib\mrb")
    try { make } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "mrb.cr make failed" }
  }
}
foreach ($f in $needed) {
  if (-not (Test-Path (Join-Path $mrbLib $f))) { throw "missing mrb artifact $f" }
}

# ---- 3) demo exes ----
Write-Host "== building demo exes (release)"
crystal build --release examples/log-explorer/main.cr -o bin/log_explorer.exe
if ($LASTEXITCODE -ne 0) { throw "log_explorer build failed" }
crystal build --release examples/log-explorer/main_builtin.cr -o bin/log_explorer_builtin.exe
if ($LASTEXITCODE -ne 0) { throw "log_explorer_builtin build failed" }

# ---- 4) specs ----
Write-Host "== crystal spec"
crystal spec
if ($LASTEXITCODE -ne 0) { throw "specs failed" }

# ---- 5) gates ----
Write-Host "== G1-G6 gates"
Push-Location $root
try {
  & "$root\bin\log_explorer.exe" --demo-gates --json | Out-File -FilePath "$root\artifacts\gates.json" -Encoding utf8
} finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { throw "gates failed" }
Get-Content "$root\artifacts\gates.json"

Write-Host "== build OK"
exit 0
