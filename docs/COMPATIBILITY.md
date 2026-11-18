# 兼容矩阵（design §12：独立维护）

- 更新：2026-11-18（tessell_mruby 0.1.0）
- 规则：任何一个依赖升级都必须重跑**全部**六项门禁 + spec（plan §4）；
  门禁脚本 `bin/log_explorer.exe --demo-gates --json`，exit code = 全过 ? 0 : 1。

## 1. 已验证矩阵

| tessell_mruby | tessell | mrb.cr | mruby | Crystal | 工具链 | 验证平台 | 门禁 | 备注 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 0.1.0 | 0.4.1 | 0.2.1 | 4.0.0 (`831da26b`) | 1.22.1 | MSYS2 UCRT64 gcc 16.2.0 | Windows 11 x64（本机） | G1–G6 全 PASS | 本机实测，报告见 go-no-go.md |
| 0.1.0 | 0.4.1 | 0.2.1 | 4.0.0（CI 内 make） | 1.22.x（msys2 最新） | MSYS2 UCRT64 gcc（CI 最新） | windows-latest（GitHub Actions） | G1–G6 全 PASS | run 44209949056；reload p99 0.51ms、e2e p99 2.24ms |
| 0.1.0 | 0.4.1 | 0.2.1 | —（不链接） | ubuntu-latest / macos-latest 最新 | — | Linux / macOS | 仅编译检查 | `crystal build/spec --no-codegen`；**不承诺运行**（R7） |

## 2. 升级规则

1. **mrb.cr**：固定 minor（`~> 0.2`）消费，不 fork。升级前先看其 CHANGELOG 对
   block/Proc、错误报告（backtrace）、dump debug info 的改动——这三处是本层
   错误隔离口径的依赖面（上游缺口见 go-no-go §5 / issue #2–#5）。升级后重跑门禁。
2. **tessell**：本层依赖 `Decl` / `UiKey` / `Pool` / `UI.apply(_auto_layout)` /
   `Router` / `HitTest` / auto 布局内核。tessell minor 升级若改 `Decl` 字段序或
   `UiKey.child` 派生算法，节点身份会跨版本漂移（脚本缓存无影响，跨版本不迁移状态）。
3. **Crystal**：`>= 1.21`（与 tessell 一致）；实测 1.22.1。Execution Contexts
   Isolated 是线程契约的基础，不回退到 1.16 以下。
4. **mruby**：由 mrb.cr 的 build_config 锁定（`831da26b`，4.0.0）。自行换 gembox
   会改变包体与可用 Ruby 语法面（如 `Hash#merge` 是否在内），需重测脚本。

## 3. 平台支持口径

| 平台 | 构建 | 运行 | 门禁 | 说明 |
| --- | --- | --- | --- | --- |
| Windows 10/11 x64（MSYS2 UCRT64） | ✅ | ✅ | ✅ G1–G6 | 唯一承诺平台（plan §2 / R7） |
| Linux x64 | ✅ 编译检查 | ❌ 未验证 | ❌ | `--no-codegen`；Win32 FFI/FT 路径未跑 |
| macOS arm64/x64 | ✅ 编译检查 | ❌ 未验证 | ❌ | 同上 |

注意：demo 的 `win_host.cr` 是纯 Win32/WGL FFI，类型检查跨平台通过但运行只在
Windows 有意义；宿主接入方若自带跨平台 host（如 tessell 的 SDL2 宿主成熟后），
脚本层本体（Runtime/Decls/Bridge/Events）没有 Windows 依赖，P2 再评估。

## 4. 已知行为边界（非 bug，口径内）

- 顶层运行期异常 `script_line` 为 nil（mrb.cr 未暴露 C 层 backtrace，issue #2）；
  声明阶段 / 回调路径 file:line 齐全。
- `compile + load_irep` 往返丢行号（issue #3）——本层因此走 `load_file` 内存编译路径。
- 符号（Symbol）参数无出参转换；脚本侧用 `to_s` 或字符串字面量（issue 追踪中，
  优先级低）。
- debug 构建在 binutils 2.47 快照（20260726）上 ld 崩溃；`--release` 稳定。
