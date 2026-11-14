# 设计：Tessell mruby 脚本层

- 状态：阶段 0 冻结稿，实现按 `docs/plan.md` 的 P0 推进
- 一句话：脚本只产出**声明**与**回调**；retained 树、布局、渲染、输入路由仍全部由 Crystal 拥有。

## 1. 依赖方向（硬约束）

```
tessell (GUI core)  ←  tessell_mruby  →  mrb (bindings) → libmruby.a
```

- `tessell` 的 `src/tessell.cr` 不出现 `require "mrb"`；`shard.yml` 不声明 `mrb`。
- `mrb.cr` 不知道窗口、`Decl`、`UiKey`；不为 GUI 加任何分支。
- 只有本仓库同时依赖两者。任何一侧想反向依赖，都是设计错误。

## 2. 模块划分

```
src/tessell_mruby.cr            # 入口：open(script) { |runtime| ... }
src/tessell_mruby/
  version.cr
  runtime.cr      # State 生命周期、eval/load_file、错误边界、重载
  handles.cr      # Int32 句柄表（id + generation）
  bridge.cr       # host 方法注册：Tessell.window/column/text/button...
  decls.cr        # 脚本调用 → Decl 数组 → UI.apply；缓冲区复用
  events.cr       # 输入事件 → 回调表 → Proc 调用 → 置 dirty
  errors.cr       # ScriptError（file:line）、HostError、InitError
  config.cr       # 字符串上限、回调预算、是否允许热重载
```

## 3. 线程与 State 模型

- `MRuby::State` 单属主、非线程安全，必须与 Tessell 的 UI 主循环同线程：在 `Tessell.ui_context` 的 Isolated 线程上创建、调用、关闭。
- 业务线程不得触碰 `State` / `Value` / `Ref`。跨线程只传不可变快照（Tessell 既有约定）与整数句柄。
- 句柄是整数，可跨线程传递，但**只允许在 UI 线程解析**为 `Node` / `UiKey`。
- 长任务：host 方法只入队（`Tessell.post`），不阻塞当前帧；是否给脚本独立 worker 线程留给 P1 决策（见 plan §11）。

## 4. 值边界

- 入参与返回值只允许 JSON-like：`nil / bool / int / float / string / array / hash`，外加**句柄整数**。
- 不把 `Node`、`UiKey`、指针、Crystal 对象暴露给脚本；句柄是唯一引用方式。
- 字符串按 UTF-8 拷贝，默认上限 1 MB（`config.max_string_bytes`），超限即脚本异常，避免脚本侧失控分配。
- 手段：复用 mrb.cr 现有的显式转换，不做隐式 `to_crystal` 魔法；转换失败是明确错误。

## 5. 句柄表

```
Handle = Int32  # 高 8 位 generation，低 24 位 id；0 保留为无效
```

- `Handles#create(key : UiKey, node : Node) : Handle`
- `Handles#resolve(h : Handle) : Node?` —— generation 不匹配或 id 越界返回 nil，脚本侧收到明确异常而非踩内存。
- `Handles#release(h)`：节点被移除或热重载时调用；`UiKey` 保持不变，句柄映射到 `UiKey` 而非 `Node` 实例，`Pool` 复用重建节点不换句柄。
- freelist 复用 id；generation 单调递增防 ABA。
- 上限（默认 100k）保护：超过即拒绝创建并报错。

## 6. DSL 映射

### 6.1 目标形态（block 版本，依赖 mrb.cr#1）

```ruby
Tessell.window "main", 800, 600 do
  Tessell.column "root", spacing: 8 do
    Tessell.text "title", "Count: #{state[:count]}"
    Tessell.button "inc", "Increment" do
      state[:count] += 1
      Tessell.invalidate "title"
    end
  end
end
```

### 6.2 降级形态（P0 先跑通）

```ruby
Tessell.window "main", 800, 600
Tessell.begin_column "root"
Tessell.text "title", "Count: 0"
Tessell.button "inc", "Increment"
Tessell.end
```

两阶段：

1. **声明阶段**：host 方法把 `Decl` 追加到 `decls` 缓冲区（容量复用，`decls.clear` 保持容量），结束后整批 `UI.apply`。
2. **事件阶段**：回调只改脚本内部 state 并调用 `Tessell.invalidate(key)`，下一帧重新走声明阶段。

脚本不持有 `Decl` 副本，也不参与 `Node.collect_dirty` / `UI.consume`。

### 6.3 key 约定

- 脚本给的字符串 key 在 `parent` 作用域内派生 `UiKey`（沿用 `UiKey.child(local)`），跨帧稳定。
- 同父下重复 key 即脚本错误（渲染期报错并高亮该节点），不做"最后一个赢"的静默覆盖。

## 7. 事件流

```
OS input → Tessell Router/hit_test → Focus
        → bridge: 查句柄 → 回调表
        → mrb_protect { yield proc }   # 回调预算检查
        → 脚本更新 state + invalidate
        → 下一帧：声明阶段重建 Decl → UI.apply → collect_dirty → consume
```

- 回调表：`Handle → Ref`（GC 注册的 `Proc`）。每个回调调用包 `mrb_protect`，异常转 `ScriptError` 并记录 `file:line`。
- 单帧最多执行 N 个回调（默认 64），超出的排队到下一帧，防止一次输入风暴把帧拖垮。
- 回调预算：默认 1 ms/次，超过记录告警（mruby 无法安全中断，只能观测）。

## 8. 错误与隔离

- 脚本 `raise` / 类型错误 / 宿主方法异常：分别映射为 `ScriptError` / `TypeError` / `HostError`，全部含 `file`、`line`。
- 宿主（Crystal）方法内异常：转 mruby `RuntimeError`（mrb.cr 现有能力），由脚本或宿主统一处理。
- 初始化失败（libmruby 缺失、版本不匹配、shim 未构建）：`InitError`，启动时显式失败并打印构建步骤，不允许静默降级。
- UI 层兜底：错误进入错误条 / 宿主回调；同一 key 的连续错误做去重与限流，避免刷屏。
- 脚本崩溃不触发 Tessell 的 panic；UI 线程继续，未受影响的节点照常渲染。

## 9. 生命周期与 GC

- 顺序：`events`（释放全部回调 `Ref`）→ `handles`（清表）→ `refs`（剩余 `Ref`）→ `state.close`。
- 重启/热重载：先释放旧回调 `Ref` 与句柄表，再 `State.open` 新实例；焦点/滚动位置按 `UiKey` 快照恢复。
- `Ref` 注册表由 Runtime 独占持有，禁止脚本/宿主任意 `unregister`。
- `arena`：每次脚本调用一个 arena，退出即 restore；需要跨调用的数据只允许留在 `Ref` 或拷贝到 Crystal 侧。
- 泄漏基线：`mrb_cr_live_objects` 在热重载前后不得单调增长（G2/G6）。

## 10. 零分配口径（叙事一致性）

- Tessell 的零分配判据 A/B **只对"脚本未触发的帧"生效**。
- 脚本帧单独记录：回调耗时、`Decl` 缓冲是否扩容、字符串分配次数。
- 优化目标：`Decl` 缓冲与 key 字符串缓存复用；稳态下脚本帧的分配次数应可预期（不承诺为 0）。
- 文档必须写清这条边界，避免"Tessell 承诺零分配"与"脚本层必然分配"被混为一谈。

## 11. 性能预算

| 指标 | 目标 |
| --- | --- |
| 空闲帧脚本调用次数 | 0 |
| 事件帧脚本调用次数 | ≤ 1 次声明 + ≤ 64 次回调 |
| 单次回调 p99 | < 1 ms |
| 单次声明阶段 p99 | < 2 ms（counter 规模） |
| 端到端输入 → 下一帧 | < 1 帧 |
| exe 增量 | ≤ 2.5 MB |
| 启动增量 | ≤ 50 ms |

## 12. 平台与构建

- 仅 Windows 先行：MSYS2 UCRT64 gcc + Crystal `x86_64-w64-windows-gnu`。
- 构建前置：在 mrb.cr 仓库执行其 `make`，产出 `lib/libmruby.a` 与 shim；本仓库 `scripts/build.ps1` 只做调用与链接名归一化（`.a/.o` ↔ `.lib/.obj`）。
- 不承诺 MSVC：未验证，且 mruby 的 MSVC 路径与本项目工具链不一致。
- CI：`windows-latest` + `msys2/setup-msys2`，跑构建 + 门禁；`COMPATIBILITY` 矩阵独立维护。
- 包体：gembox 仅 `mruby-compiler` + `mruby-error`（当前实测 `libmruby.a` 4.9 MB），按需 `-Os` + strip。

## 13. 测试策略

- 单元：`Handles`（ABA/失效/上限）、`Decls` 缓冲复用、错误映射、key 去重。
- 集成：counter demo 全链路；改 `.rb` 热重载；脚本注入故障。
- 门禁自动化（G1–G6）作为可重复脚本，数字进报告。
- 模糊：超长字符串、深层嵌套、重复 key、伪造句柄整数。

## 14. 与上游的边界

- `mrb.cr` 需要的能力（block/`Proc`/`yield`/`funcall`、Windows 链接名、lockfile 文档）全部走 issue #1，不在本仓库 fork。
- 若上游长期不接：本仓库可临时用 patch 分支验证，但发布版必须回到上游 API；这是 Go/No-Go 的一部分。

## 15. 开放问题

1. 句柄是 `Int32` 还是 `Int64`（跨语言 JSON 精度与数量上限权衡）。
2. 脚本线程模型（同步 UI 线程 vs worker + 队列）——P1 依 G4 数据定。
3. 是否需要"脚本对象模型"（每个 `Widget` 一个 mruby 对象）——当前否，先保持函数式 DSL。
4. 错误呈现与重试策略（错误条 / 日志 / 宿主回调，是否自动禁用出错脚本）。
5. RITE 预编译是否进 P0（影响启动与是否需要在目标机保留编译器）。
