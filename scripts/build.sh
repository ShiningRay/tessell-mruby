#!/usr/bin/env bash
# CI / msys2 构建入口（与 build.ps1 同逻辑；PowerShell 起的子进程拿不到
# msys2 PATH，CI 直接在 msys2 shell 里跑本脚本）。
#
# 1. shards install
# 2. mrb 链接产物：优先拷贝同级 ../mrb.cr/lib，否则在 lib/mrb 内 make
# 3. --release 构建 demo 双 exe（debug 链接在 binutils 2.47 快照上 ld 崩溃，
#    见 docs/go-no-go.md；本地与 CI 统一 release）
# 4. crystal spec --release
# 5. G1-G6 门禁 → artifacts/gates.json
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
echo "== tessell-mruby build in $root"

mkdir -p bin artifacts

echo "== shards install"
shards install

echo "== mrb artifacts"
mrb_lib="lib/mrb/lib"
missing=0
for f in libmruby.a libmruby.lib mrb_shim.o mrb_shim.obj; do
  [ -f "$mrb_lib/$f" ] || missing=1
done
if [ "$missing" = 1 ]; then
  mkdir -p "$mrb_lib"
  sibling="$(dirname "$root")/mrb.cr/lib"
  if [ -f "$sibling/libmruby.a" ] && [ -f "$sibling/mrb_shim.o" ]; then
    echo "== copying mrb artifacts from sibling checkout $sibling"
    cp "$sibling/libmruby.a" "$sibling/libmruby.lib" "$sibling/mrb_shim.o" \
       "$sibling/mrb_shim.obj" "$mrb_lib/"
  else
    echo "== building mruby inside lib/mrb (make: ruby + gcc + network required)"
    (cd lib/mrb && make)
  fi
fi
for f in libmruby.a libmruby.lib mrb_shim.o mrb_shim.obj; do
  [ -f "$mrb_lib/$f" ] || { echo "missing mrb artifact $f" >&2; exit 1; }
done

echo "== building demo exes (release)"
crystal build --release examples/log-explorer/main.cr -o bin/log_explorer.exe
crystal build --release examples/log-explorer/main_builtin.cr -o bin/log_explorer_builtin.exe

echo "== crystal spec --release"
crystal spec --release

echo "== G1-G6 gates"
./bin/log_explorer.exe --demo-gates --json > artifacts/gates.json
cat artifacts/gates.json

echo "== build OK"
