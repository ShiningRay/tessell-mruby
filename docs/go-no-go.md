# P0 Go / No-Go 报告：Tessell mruby 脚本层

- 日期：2026-11-18
- 结论：**Go** —— P0 六项门禁全 PASS，API 形状经 Log Explorer 真实 demo 验证，值得抽成独立 shard 进入 P1。
- 环境：Windows 11 x64，MSYS2 UCRT64 gcc 16.2.0，Crystal 1.22.1，mrb.cr 0.2.1（上游 commit `87236b3`），tessell 0.4.1（`72bbe15`），mruby 4.0.0（`831da26b`）。
- 复现：`powershell -File scripts/build.ps1`（构建 → 26 spec → G1–G6 → `artifacts/gates.json`）；或 `bin/log_explorer.exe --demo-gates --json`。

## 1. 六项门禁实测（`--demo-gates --json`，无人值守）

| 门禁 | 判据 | 实测 | 结果 |
| --- | --- | --- | --- |
| G1 异常隔离 | 4 类故障不崩进程；UI 存活；错误含 file:line | 解析错误（file+line ✓）、声明阶段 raise（file+line ✓）、回调 raise（file+line ✓）、宿主异常（class+file ✓）；连续 208 帧存活；good 缓冲保持（ui_kept=true） | **PASS** |
| G2 热重载 | ≤500ms 生效；key 稳定；live_objects 不增长 | 50 次连续 reload p99 **1.18ms**（max 同值）；UiKey 全程稳定；gc_full 后 live growth = **0**；新文案生效 | **PASS** |
| G3 空闲零分配 | delta_work < 1000 且 ≤ 256 | 1000 个空闲帧 delta_work = **0**（headless，脚本未触发帧无任何脚本调用） | **PASS** |
| G4 事件延迟 | 端到端 < 1 帧（16.7ms）；回调 p99 < 1ms | 1000 次经 Router 命中测试的真实点击链路：e2e p99 **2.57ms**、max 3.6ms；回调 p99 **0.014ms** | **PASS** |
| G5 包体/启动 | exe 增量 ≤ 2.5MB；启动增量 ≤ 50ms | exe 增量 **1.19MB**（7.08MB vs 内置基线 5.89MB）；进程内启动增量 **3.6ms**（脚本层 State 创建+load+首帧 vs 内置首帧） | **PASS** |
| G6 稳定性 | 200 点击 + 50 reload 无崩溃；无句柄/Ref 泄漏 | 200 点击 + 50 重载无崩溃；live_objects 233→233（peak 711）；handles 稳定；events registered-released 差值 = **0** | **PASS** |

脚本帧的分配与耗时单列（HUD 与 G4 口径），未并入 tessell 零分配叙事（design §10 口径一致）。

以上六项门禁同样在 **GitHub Actions windows-latest（MSYS2 UCRT64）独立机器上全 PASS**
（run 44209949056：reload p99 0.51ms、e2e p99 2.24ms、exe 增量 1.19MB、live 233→233；
26 spec 全绿；gates.json 与 demo 双 exe 进 CI 工件）。CI 教训：2026 msys2 包名前缀
统一为 `mingw-w64-ucrt-x86_64-*`，shards 是独立包，FT/HB/brotli 是 tessell 文本栈
的链接依赖（见 .github/workflows/ci.yml）。

### 演示证据（demo.md §10 三段）

`bin/log_explorer.exe --window --demo-capture examples/log-explorer/ui.rb` 脚本化产出
（已入库 `docs/assets/`）：

1. **demo.gif**：120 帧（每 3 帧一抽、5fps 循环）三段全程 —— 初始 UI → Harm 注入
   （错误条出现、UI 存活）→ 改脚本标题热重载（`[reloaded]`、reloads 计数增长）。
2. **demo_1_initial.png**：脚本声明的完整 UI（toolbar/KPI/30 行日志/HUD）。
3. **demo_2_error.png**：点击 Harm 后 —— 底部红色错误条 `script error:
   examples/log-explorer/ui.rb:35: RuntimeError: injected failure from Harm button`，
   上方 UI 原样存活（G1）。
4. **demo_3_reload.png**：改脚本标题文案后热重载 —— 标题变 `[reloaded]`、HUD
   `reloads 1`、错误条清除、节点身份不换（G2）。

## 2. P0 硬性产出对账（plan §5）

| 产出 | 状态 |
| --- | --- |
| `TessellMRuby.open("ui.rb") { ... }` 跑通 Log Explorer | ✅（counter 已按 demo.md 降级为 smoke 用例，保留在 spec） |
| 脚本改一行后热重载生效 | ✅（G2：50 次连续重载，key/滚动由宿主持有不受影响） |
| 脚本 `raise` 只污染一个错误条 | ✅（G1：错误条来自宿主区 decl，good 缓冲不动） |
| `--demo-gates` 无人值守输出 G1–G6 JSON | ✅（`bin/log_explorer.exe --demo-gates --json`，exit code = 全过 ? 0 : 1） |
| 未 fork mrb.cr | ✅（0.2.1 直接消费；缺口走上游 issue，见 §5） |
| API 形状被真实 demo 验证 | ✅（examples/log-explorer：block 形态脚本 + Host.* glue + 虚拟化 + fallback） |

## 3. 实现要点与偏差（相对 plan/design 冻结稿）

1. **执行模型落定（design §6 的"两阶段"具体化）**：脚本顶层只执行一次；`Tessell.window(...) { ... }` 的 block 成为帧过程，声明阶段重复调用。顶层局部变量（`state = {...}`）被闭包持有跨帧存活——这是冻结脚本形状能工作的前提，已写进 bridge 注释。
2. **block 版本直接落地**：plan 预估上游 block/Proc 绑定未就绪需 `begin/end` 降级先行；实际 mrb.cr 0.2.0 已交付 block API，因此主路径直接用 block 形态，`begin_*/end_node`（`Tessell.end` 是 Ruby 关键字，改名 `end_node`）作为静态降级形态并存，`set_text` 支持降级脚本的文本更新。
3. **错误边界加了一层 Ruby wrapper**：mrb.cr 未暴露 C 层 backtrace，mruby 的 `Exception#backtrace` 只能从 Ruby 侧取。声明阶段与回调经 `__tessell_protect`（Ruby rescue → 回传 class/message/位置）调用，使运行期异常带 file:line。顶层运行期异常的行号仍拿不到（load 路径无 wrapper），file 可得——见 §5 上游缺口。解析错误走 compile 前置检查，file:line 精确。
4. **key 派生**：脚本字符串 key 在 parent 作用域内 FNV-1a → `UiKey.child`，缓存按 parent 分桶。同帧重复 key 在声明阶段即抛脚本异常（比 UI.apply 的 fail-fast 更早、位置更准）。
5. **双缓冲**：声明阶段写 front 缓冲，成功 commit 交换为 good；失败回滚——脚本帧报错时 UI 保持上一帧（G1 的"只污染一个错误条"）。
6. **事件分发**：Router 命中 → 目标节点沿祖先链找最近回调（按钮回调挂在容器 Row 上，命中常落在文本子节点）→ `Ref` 持有的 Proc 经 wrapper 调用。单帧回调预算（config.max_callbacks_per_frame）与超预算告警已具备，当前由宿主 UI 线程顺序消费。
7. **demo 布局**：脚本区域必须包在单一外层容器内（`Tessell.column "root"`）——独立 auto 根会被 viewport 原点各自求解并全部叠在 y=0。已写进 ui.rb 注释与 api-freeze。
8. **构建**：debug 构建在本机 binutils 2.47 快照（20260726）上触发 ld 崩溃（collect2 exit 5，无诊断输出；`--release` 稳定）。构建脚本与 CI 统一 `--release`。此为工具链问题，与脚本层无关，留观察。

## 4. 性能快照（本机，release 构建）

| 指标 | 值 | 目标 |
| --- | --- | --- |
| 脚本声明阶段 p99（30 行 × 3 列 + 工具栏） | ~0.2ms | < 2ms |
| 单次回调 p99 | ~0.014ms | < 1ms |
| 空闲帧脚本调用 | 0 | 0 |
| 空闲帧分配（GC bytes 窗口） | 0 | < 1000 / ≤ 256 |
| 10k 行滚动帧 p99（每帧 wheel → 重声明 → apply） | 2.72ms（max 3.39，1000 帧） | < 16.7ms（60fps） |
| exe 增量（静态 libmruby 4.9MB 经链接死码消除） | 1.19MB | ≤ 2.5MB |
| 启动增量 | ~3.6ms | ≤ 50ms |
| 热重载单次 | ~1.2ms | ≤ 500ms |

## 5. 上游 mrb.cr 缺口（不 fork，走 issue）

1. **C 层 backtrace 未暴露**：`mrb_cr_exception` 系列没有 backtrace 读取；mruby 4 的 `Exception#backtrace` 需要 Ruby 层 wrapper 才能拿到。建议 shim 增加 `mrb_cr_exception_backtrace`（返回位置字符串数组），宿主可去掉 `__tessell_protect` 并补齐顶层运行期异常的行号。
2. **compile + load_irep 丢 debug info**：`mrb_cr_compile_irep` 走 `mrb_dump_irep(..., 0)`，dump 未带 `MRB_DUMP_DEBUG_INFO`，经 irep 往返执行的代码无行号。建议 dump 加 debug 标志或提供 `load_irep_with_debug`。
3. **`eval_with_filename` 未公开**：load 侧无法用带文件名的 eval 包裹执行；公开后顶层异常可走与回调一致的 wrapper 路径。
4. **符号值无出参转换**：`CallbackValue` 出参不含 Symbol（`Value#symbol?` 有、转换无）；宿主读 Symbol 参数需脚本侧 `to_s` 或比对符号对象。低优先级。
5. **lib/ 产物未随 shard 分发**：消费方 `shards install` 后必须自行 `make`（ruby + gcc + 网络）；建议仓库附 release 产物或在 shard.yml 支持 postinstall（Windows 链接名归一化 Makefile 已处理 `.a/.lib` 双后缀）。

## 6. 风险登记更新（相对 plan §8）

| 风险 | 状态 |
| --- | --- |
| R1 无执行配额 | 维持：只接可信插件；回调预算只观测不中断；文档已写明 |
| R2 上游 block 延迟 | **解除**（0.2.0 已交付） |
| R3 GC/生命周期 | 缓解有效：Ref 注册表 + 固定 close 顺序 + live_objects 基线，G6 实测零泄漏 |
| R4 零分配叙事冲突 | 缓解有效：脚本帧单列，G3 证明空闲帧零调用零分配 |
| R5 版本矩阵 | 固定 mrb.cr 0.2.1 + tessell 0.4.1 + Crystal 1.22.1 + mruby 4.0.0；CI 锁定 |
| R6 包体/启动 | 实测 1.19MB / 3.6ms，余量充足 |
| R7 单平台 | 维持：P0/P1 仅 Windows，CI 只跑 windows |
| R8 热重载残留 | 缓解有效：UiKey 稳定派生 + 宿主持有滚动/焦点状态；50 次重载 key 全程一致 |

## 7. P1 建议（按 plan §5 P1 清单细化）

1. 模块化与公开 API 冻结（见 api-freeze.md），补 `Runtime::Timing` 等 HUD 接口文档。
2. CI 增加 Linux/macOS 编译检查（不承诺运行）。
3. RITE 预编译管线（依赖上游缺口 2 修复；收益是启动与包体，当前 3.6ms/1.19MB 已达标，非阻塞）。
4. 脚本 API 参考（`Tessell.*` + `Host.*` glue 模式）与接入指南。
5. 视觉层：`DeclKind` 目前只有 Node/Text/Row/Column，按钮视觉靠 a11y 字段；如需底色/圆角需 tessell 渲染层先暴露 rect 声明（plan §2 非目标，不阻塞）。
