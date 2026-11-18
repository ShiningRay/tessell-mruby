# API 冻结（0.2.0 正式版）

- 状态：**正式冻结**（0.2.0，2026-11-18）。0.1.x → 0.2.0 的破坏性变更：
  无（全部为追加面）；后续变更规则见 §6。
- 范围：`TessellMRuby` 公开 API + 脚本可见的 `Tessell.*` DSL + 宿主 glue 惯例
- 原则：脚本侧只拿 JSON-like 值 + 整数句柄；`Node`/`UiKey`/指针不出桥

## 1. Crystal 侧（宿主）

```crystal
TessellMRuby.open(script : String? = nil, config : Config = Config.new) { |rt| ... }
#   load_file 失败抛 ScriptError；State 创建失败抛 InitError；ensure close。

rt.config : Config                     # 上限与开关（见 §4）
rt.load_file(path) / rt.eval(code)     # 脚本装载（错误 → ScriptError，含 file:line）
rt.load_plugins(dir) : PluginLoadResult  # 插件目录发现/加载（T2.5，单 State 顺序
                                        #   eval；清单 plugins.json 可选；逐插件
                                        #   错误隔离，failed 不阻断后续）
rt.run_frame : RunResult               # 声明阶段：RunResult#decls(Array(Decl))、
                                       #   #error(ScriptError?)、#script_ms；失败时 decls = good（上帧画面）
rt.dispatch_click(ukey) : DispatchResult  # 事件回调：#dispatched、#error、#script_ms
rt.request_frame / rt.needs_frame?     # 失效驱动（invalidate 会置位）
rt.reload(path)                        # 热重载：Ref 全释放 → 新 State → DSL/宿主
                                       #   模块/prelude 需重放（Runtime 已自动重放
                                       #   DSL 与 prelude；宿主模块须宿主重注册）
rt.close                               # events → handles → state.close 固定顺序
rt.live_objects : Int64                # G2/G6 基线
rt.script_timing / rt.callback_timing  # Timing（last/p99/max/count，容量 1024）
rt.on_error = ->(ScriptError)          # 错误钩子（错误条数据源）
rt.host_module(name) / rt.host_method(module, name, arity) { |args| }  # Host.* 注册；
                                       #   块内 Crystal 异常打 [tessell-host] 标签重抛（T2.2）
rt.window_title / window_width / window_height   # 脚本 Tessell.window 的元数据
rt.state : MRuby::State                # 高级用法（UI 线程内）
```

错误类型（T2.2 正式化）：

```crystal
se.kind : Kind        # Raise / TypeError / Host（0.1.0 冻结面）
se.code : Code        # RuntimeError / TypeError / ParseError / HostError /
                      #   DuplicateKey / LimitExceeded / StateError（0.2.0 新增，
                      #   识别口径 = 消息 [tessell-*] 机器标签，宿主可按 code
                      #   决定禁用/重试/展示策略）
se.location           # "file:line"（顶层运行期异常行号待上游 #2/#4）
```

宿主帧循环（demo `host_app.cr` 为参考实现）不变，见 integration.md §2。

## 2. 脚本 DSL（`Tessell.*`）

block 形态（主路径；顶层只执行一次，window block = 帧过程）：

```ruby
state = { theme: :dark, filter: :all }   # 顶层局部变量被闭包持有，跨帧存活

Tessell.window "name", w, h do           # 每脚本一次；block 即帧过程
  Tessell.column "root" do               # ⚠ 必须有单一外层容器：
    Tessell.row "toolbar" do ... end     #   各区域是独立 auto 布局根时会被
    Tessell.text "key", "text"           #   viewport 原点分别求解并叠在 y=0
    Tessell.row "cards", 8.0, 12 do      # T2.4 布局参数：gap, padding（位置参数）
    Tessell.column "list", gap: 4, padding: [6, 8, 6, 8] do   # 或 kwargs
      Tessell.button "key", "label" do   # Row(a11y=Button) + 文本子节点 + 回调
        ...
        Tessell.invalidate_all           # 改完状态必须失效，下一帧重声明
      end
    end
  end
end
```

布局参数（0.2.0，T2.4）：
- `row/column/node/begin_row/begin_column/begin_node` 接受可选 `gap, padding`；
- padding：单个数字 = 四边，或 `[left, top, right, bottom]` 四元素数组；
- 非负校验，违规 → `[tessell-type]` TypeError；
- 不传参时产出与 0.1.0 逐位一致（gap 0 / padding 全 0）。

裸 DSL sugar（0.2.0，T2.1，`Config.new(bare_dsl: true)` 开启，默认关）：

```ruby
state = { n: 0 }
window "name", w, h do                   # 15 个 DSL 名都可省略 Tessell. 前缀
  column "root" do text "t", "hi" end
end
```
- 实现为顶层委托 def（prelude），`Tessell.*` 规范形式始终可用且是规范 API；
- 已知口径：错误定位取 backtrace 中第一个脚本帧（跳过 prelude/glue 的
  `(eval)` 帧夹层）——嵌套块内 raise 定位到 DSL 调用点行而非 raise 行；
  规范形式定位到 raise 行；
- 脚本顶层同名 `def` 会遮蔽委托（Ruby 后定义优先）；kwargs 经 splat 转发
  按位置 Hash 打包，与 mruby 3.x+ 语义一致。

静态降级形态（无块式脚本；顶层线性发射一次）：

```ruby
Tessell.window "name", w, h              # 无 block = 进入静态模式
Tessell.begin_column "c", gap: 2         # begin_row/begin_column/begin_node
Tessell.on_click "key" do ... end        # 持久回调（key 必须已声明）
Tessell.set_text "key", "new"            # 原地改文本（回调内可用）
```

通用：

```ruby
Tessell.invalidate "key" / Tessell.invalidate_all   # 失效
Tessell.handle "key" : Int32                        # 句柄（失效句柄 resolve 为 nil）
Tessell.node "key" do ... end                       # DeclKind::Node
```

约束与错误（全部以 mruby 异常呈现，带 file:line 与 code）：
- 参数类型不符 / 字符串超 `max_string_bytes` → TypeError（`[tessell-type]`）。
- 同帧重复 key、回调重复注册 → DuplicateKey（`[tessell-dup-key]`）。
- decl/句柄/插件数上限 → LimitExceeded（`[tessell-limit]`）。
- 形态混用、调用时机违规、window 重复、on_click/set_text 未知 key →
  StateError（`[tessell-state]`）。
- 宿主方法内 Crystal 异常 → HostError（`[tessell-host]`）。
- 同帧重复 key 在声明阶段即抛脚本异常（比 UI.apply 的 fail-fast 更早）。
- `Tessell.end` 不可用（Ruby 关键字），降级形态用 `Tessell.end_node`。

## 3. 宿主数据惯例（demo `Host.*` 模式）

不变（见 integration.md §3）：宿主数据以标量访问器过桥，Ruby glue 在脚本侧
拼装语义 API；虚拟化切片在宿主，脚本只遍历可见窗口。

## 4. Config 默认值

| 项 | 默认 | 说明 |
| --- | --- | --- |
| max_string_bytes | 1 MiB | 单字符串上限 |
| max_handles | 100_000 | 句柄表容量 |
| max_decl_nodes | 20_000 | 单次声明阶段 Decl 上限 |
| max_callbacks_per_frame | 64 | 单帧回调预算 |
| callback_budget_ms | 1.0 | 超限记录告警（不中断） |
| allow_hot_reload | true | reload 开关 |
| bare_dsl | false | 裸 DSL prelude sugar（T2.1） |
| max_plugins | 64 | 单次 load_plugins 扫描上限（T2.5） |

## 5. 遗留（0.2.0 之后按需评估）

- Symbol 出参转换（上游 mrb.cr issue 追踪中，脚本侧 `to_s` 规避）。
- 错误自动禁用/重试策略（宿主可用 `code` 自行实现）。
- 顶层运行期异常行号、RITE 预编译：依赖上游 mrb.cr #2/#3/#4（仍 OPEN，
  触发条件与降级规则见 plan §5 条件项）。
- worker 线程模型：依 G4 数据确认不需要（同步回调 p99 < 0.03ms）。

## 6. 冻结后的变更规则

- **新增**（新方法/新 Config 字段/新 Code 值）：minor 版本，保持向后兼容。
- **修改语义**（既有 DSL/宿主方法的可观察行为变化）：先在 README/CHANGELOG
  公告废弃窗口，minor 内不破坏；破坏性变更进 major。
- 每次触碰依赖面（tessell/mrb.cr/mruby/Crystal）必须重跑全部门禁
  （COMPATIBILITY.md §2），G8 基线同步更新。
