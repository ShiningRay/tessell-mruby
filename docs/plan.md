# 计划：Tessell mruby 脚本层

- 状态：**阶段 0（计划冻结）**，尚未实现
- 上游：`ShiningRay/tessell`（GUI 核心）、`ShiningRay/mrb.cr`（mruby 绑定）
- 目标平台：Windows 优先（MSYS2 UCRT64 / Crystal `x86_64-w64-windows-gnu`）

## 1. 背景

Tessell 的 M0–M4 已收口（Windows 本机 263 spec 全绿、15 项门禁 PASS、分发包裸 PATH 可跑），架构定案是"宏 + 编译期类型 + 无 Ruby 式运行时动态分派"（`docs/architecture.md:29`）。因此任何脚本能力都必须满足三个约束：

1. **可选**：不用脚本的用户不付任何代价（依赖、构建、包体、启动时间）。
2. **不夺权**：脚本不成为 UI 主循环与数据模型，热路径仍在 Crystal。
3. **可回滚**：脚本层出问题，应用能整体关掉它继续跑。

mruby 满足这些约束：静态库约 4.9 MB、无外部运行时、单线程 State、可预编译 RITE 字节码、值与宿主边界可收窄到 JSON-like + 整数句柄。

## 2. 目标 / 非目标

### 目标（P0–P1）

- 应用启动时可选加载一个 mruby 脚本，脚本能声明 UI 并响应事件。
- 脚本与 UI **同线程**（Tessell 的 `ui_context` Isolated 线程），不引入跨线程 `State`。
- 脚本异常被隔离：不 panic、不崩进程，UI 继续跑，错误可见。
- 支持热重载：改 `.rb` 后重建脚本状态，句柄、焦点、滚动位置不丢。
- 包体增量可控（≤ 2.5 MB exe，见 G5），启动增量 ≤ 50 ms。
- 不破坏 Tessell 的空闲帧零分配口径（脚本未触发的帧照旧走 A/B 判据）。

### 非目标（明确不做）

- **CRuby / MRI 嵌入**，以及 gem 生态兼容。需要 Ruby 生态时应另立"C ABI 共享库 + 官方 gem"项目。
- 不可信代码沙箱。mruby 无执行配额，死循环会占满 UI 线程；本仓库只服务可信插件，不可信输入必须独立进程。
- 让脚本接管 `UI.apply` / `Pool` / retained 树。脚本只产出 `Decl` 与回调表。
- P0 阶段支持 macOS / Linux（Tessell 本身 macOS No-Go、Linux 未验证）。
- 脚本自定义渲染后端、直接操作 DrawList。

## 3. 成功判据（Go / No-Go）

P0 结束只回答一个问题：**值不值得继续做成 shard？** 判据：

- G1–G6 全部通过（见 §6）；
- 未 fork mrb.cr（上游缺口以 issue/PR 收敛）；
- P0 的 API 形状被至少一个真实 demo 验证（counter + 一处列表/长文本场景）；
- 若任一硬门禁失败，退回"应用内内置"（代码留在使用方仓库），不强行抽 shard。

## 4. 前置条件与版本矩阵

| 组件 | 版本 / 来源 | 说明 |
| --- | --- | --- |
| tessell | `~> 0.1`（github） | 需要 `Decl` / `UiKey` / `Pool` / Isolated UI 线程 |
| mrb.cr | `~> 0.1`，固定 commit | 不 fork；升级需重跑门禁 |
| mruby | 4.0.0（`831da26b9021de0369d17b71b5667e2941a1a32d`） | `build_config/mrb_cr.rb` 构建 |
| Crystal | ≥ 1.21，实测 1.22.1 | target `x86_64-w64-windows-gnu` |
| gcc | MSYS2 UCRT64 16.2.0 | Windows 已实测可构建 mruby + shim |

上游待办（阻塞 P0 的只有 T0.5）：

- [mrb.cr#1](https://github.com/ShiningRay/mrb.cr/issues/1)：block / `Proc` / `yield` / `funcall` 绑定（`panel do ... end`、`on_click { }` 的前提）。
- 同 issue：Windows 链接名归一化（`.a/.o` ↔ `.lib/.obj`）、lockfile 可写目录、bison/gperf 文档。
- P0 不等上游：先用 `begin_*` / `end_*` 降级 API 跑通事件闭环，block 版本随上游就绪切换。

## 5. 阶段计划

### P0：Spike（2 周，约 9.5 人日）

| 编号 | 任务 | 交付物 | 人日 |
| --- | --- | --- | --- |
| T0.1 | 骨架与构建脚本 | `scripts/build.ps1` 封装 mrb.cr 的 `make` + 链接名归一化；CI 冒烟 | 0.5 |
| T0.2 | Runtime | 在 UI 线程持有 `MRuby::State`；`eval` / `load_file` / RITE 加载；错误边界 | 1.5 |
| T0.3 | Handles | `Int32`（id + generation）句柄表；`resolve` / `create` / `release`；失效返回 nil | 0.5 |
| T0.4 | Bridge（声明侧） | `Tessell.*` host 方法写 `Decl` 栈；`text/label/button/row/column`；覆盖 a11y 字段 | 2.0 |
| T0.5 | 事件与回调 | `on_click` 等回调注册（Ref 持 Proc）；`begin/end` 降级 + block 版本 | 2.0 |
| T0.6 | Demo + 门禁 | `examples/log-explorer/`（规格见 [demo.md](demo.md)）；G1–G6 自动化脚本；性能/内存基线 | 2.0 |
| T0.7 | 文档与结论 | Go/No-Go 报告、API 冻结草案、上游 issue 清单 | 1.0 |

**P0 硬性产出**：`TessellMRuby.open("ui.rb") { ... }` 能跑通 Log Explorer（counter 降级为 smoke 用例）；脚本改一行后热重载生效；脚本 `raise` 只污染一个错误条；`--demo-gates` 可无人值守输出 G1–G6 的 JSON。

### P1：独立 shard（2 周，约 5–8 人日）

- 模块化与公开 API（`Runtime` / `Handles` / `Bridge` / `ScriptError`）。
- CI：`windows-latest` + `msys2/setup-msys2`（UCRT64）跑构建 + 门禁；Linux/macOS 仅编译检查（不承诺运行）。
- 文档：接入指南、脚本 API 参考、与 tessell 版本兼容矩阵。
- 发布 `0.1.0`（git tag + shard 可消费）；失败则回滚到"应用内内置"。

### P2：稳定（无固定排期）

- 脚本 API 冻结、错误码、RITE 预编译管线、插件发现/加载器、性能基线跟踪、跨平台评估。

## 6. 六项门禁

| 编号 | 判据 | 测量方式 |
| --- | --- | --- |
| G1 异常隔离 | 脚本 `raise`、类型错误、宿主方法异常均不崩进程；UI 存活 ≥ 60 s；错误含 `file:line` | demo 注入 4 类故障，观察进程与 UI |
| G2 热重载 | 改 `.rb` 后 ≤ 500 ms 生效；句柄、焦点、滚动位置不丢；旧 `Proc` 全部释放 | 连续 50 次热重载 + `live_objects` 回归 |
| G3 空闲零分配 | 脚本未触发的帧：Tessell 判据 A `delta_work < 1000` 且 B `<= 256` | 沿用 tessell 现有探针，脚本帧单列 |
| G4 事件延迟 | 端到端输入→下一帧 < 1 帧；脚本回调 p99 < 1 ms | 1000 次合成点击，记录分位 |
| G5 包体/启动 | exe 增量 ≤ 2.5 MB；启动增量 ≤ 50 ms | 对比带/不带脚本层的同 demo |
| G6 稳定性 | 200 次点击 + 50 次热重载无崩溃、无句柄泄漏、无 `Ref` 泄漏 | 长跑脚本 + `mrb_cr_live_objects` 基线 |

脚本帧的分配与耗时**单独记录**，不并入 Tessell 的 A/B 口径——这是叙事一致性的关键（见 `docs/design.md` §10）。

## 7. 时间线

| 周 | 内容 |
| --- | --- |
| W1 | T0.1–T0.4：骨架、Runtime、Handles、声明侧 Bridge |
| W2 | T0.5–T0.7：事件闭环、demo、G1–G6、Go/No-Go 报告 |
| W3–W4 | P1：模块化、CI、文档、0.1.0 发布 |
| W5+ | P2 视使用情况推进 |

## 8. 风险登记

| 风险 | 概率 | 影响 | 缓解 |
| --- | --- | --- | --- |
| R1 mruby 无执行配额，脚本死循环卡死 UI | 高 | 高 | 只接可信插件；单次回调预算 + 超时记录；长任务走 worker/独立进程；文档写明 |
| R2 上游 block/`Proc` 绑定延迟 | 中 | 高 | `begin/end` 降级 API 先闭环；P0 不阻塞于上游；必要时先提 PR |
| R3 GC / 生命周期错误（`Proc` 泄漏、close 顺序） | 中 | 高 | `Ref` 统一注册表；close 顺序固定；`live_objects` 基线；热重载批量释放 |
| R4 与"零分配 / 无动态分派"叙事冲突 | 高 | 中 | 脚本层严格可选；口径单列；architecture 文档增补一节 |
| R5 版本矩阵爆炸（Crystal × mruby × mrb.cr × tessell） | 中 | 中 | 固定矩阵 + CI；mrb.cr 固定 commit；升级需全门禁 |
| R6 包体 / 启动超标 | 中 | 中 | gembox 裁剪（仅 core + compiler + error）、`-Os`、strip；必要时 RITE 预编译减小编译器依赖 |
| R7 只有 Windows 一条腿 | 高 | 低 | 明确声明 P0/P1 仅 Windows；P2 再评估 macOS/Linux |
| R8 热重载残留（旧句柄、旧回调、焦点丢失） | 中 | 中 | generation 防 ABA；重载时快照焦点/滚动并按 `UiKey` 恢复 |

## 9. 工作量汇总

| 阶段 | 人日 | 说明 |
| --- | --- | --- |
| P0 | 8–10 | 含门禁与 Go/No-Go |
| P1 | 5–8 | 模块化、CI、文档、发布 |
| P2 | 待估 | 冻结 API 后按需求排 |

## 10. 交付物

- P0：Log Explorer demo（规格见 [`demo.md`](demo.md)）、G1–G6 报告、API 冻结草案、Go/No-Go 结论。
- P1：`tessell_mruby` 0.1.0、接入文档、CI 工作流、兼容矩阵。
- 全程：上游 mrb.cr 的 issue/PR（不 fork）。

## 11. 开放问题

1. 脚本跑在 UI 线程（同步、简单）还是独立 worker（可超时、但 UI 更新要排队）？P0 先同步，P1 依据 G4 数据定。
2. 脚本是否需要对象模型（`Widget` 实例）还是纯函数式 DSL（当前方案）？
3. a11y 的 `name` / `value` 是否允许脚本直接设置，还是必须走翻译层？
4. 脚本错误的呈现：内置错误条、日志文件、还是交给宿主回调？
5. RITE 预编译是否进 P0（影响包体与启动），还是 P1 再做？
