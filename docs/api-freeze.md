# API 冻结草案（P0 实测版）

- 状态：P0 验收后的冻结候选，P1 按此文评审后正式冻结
- 范围：`TessellMRuby` 公开 API + 脚本可见的 `Tessell.*` DSL + 宿主 glue 惯例
- 原则：脚本侧只拿 JSON-like 值 + 整数句柄；`Node`/`UiKey`/指针不出桥

## 1. Crystal 侧（宿主）

```crystal
TessellMRuby.open(script : String? = nil, config : Config = Config.new) { |rt| ... }
#   load_file 失败抛 ScriptError；State 创建失败抛 InitError；ensure close。

rt.config : Config                     # 上限与开关（见 §4）
rt.load_file(path) / rt.eval(code)     # 脚本装载（错误 → ScriptError，含 file:line）
rt.run_frame : RunResult               # 声明阶段：RunResult#decls(Array(Decl))、
                                       #   #error(ScriptError?)、#script_ms；失败时 decls = good（上帧画面）
rt.dispatch_click(ukey) : DispatchResult  # 事件回调：#dispatched、#error、#script_ms
rt.request_frame / rt.needs_frame?     # 失效驱动（invalidate 会置位）
rt.reload(path)                        # 热重载：Ref 全释放 → 新 State → DSL/宿主模块需重注册
rt.close                               # events → handles → state.close 固定顺序
rt.live_objects : Int64                # G2/G6 基线
rt.script_timing / rt.callback_timing  # Timing（last/p99/max/count，容量 1024）
rt.on_error = ->(ScriptError)          # 错误钩子（错误条数据源）
rt.host_module(name) / rt.host_method(module, name, arity) { |args| }  # Host.* 注册
rt.window_title / window_width / window_height   # 脚本 Tessell.window 的元数据
rt.state : MRuby::State                # 高级用法（UI 线程内）
```

宿主帧循环（demo `host_app.cr` 为参考实现）：

```
每帧：pump 后台快照 → 输入经 Router.handle → pointer_up 目标沿祖先链找回调
      → needs_frame? 时 rt.run_frame → UI.apply(decls, root, pool)
      → UI.apply_auto_layout(decls, pool, viewport, measurer)
      → Node.collect_dirty → 渲染 → UI.consume
```

## 2. 脚本 DSL（`Tessell.*`）

block 形态（主路径；顶层只执行一次，window block = 帧过程）：

```ruby
state = { theme: :dark, filter: :all }   # 顶层局部变量被闭包持有，跨帧存活

Tessell.window "name", w, h do           # 每脚本一次；block 即帧过程
  Tessell.column "root" do               # ⚠ 必须有单一外层容器：
    Tessell.row "toolbar" do ... end     #   各区域是独立 auto 布局根时会被
    Tessell.text "key", "text"           #   viewport 原点分别求解并叠在 y=0
    Tessell.button "key", "label" do     # Row(a11y=Button, focusable) + 文本子节点
      ...                                #   + 点击回调
      Tessell.invalidate_all             # 改完状态必须失效，下一帧重声明
    end
  end
end
```

静态降级形态（无块式脚本；顶层线性发射一次）：

```ruby
Tessell.window "name", w, h              # 无 block = 进入静态模式
Tessell.begin_column "c" ... Tessell.end_node   # begin_row/begin_column/begin_node
Tessell.on_click "key" do ... end        # 持久回调（key 必须已声明）
Tessell.set_text "key", "new"            # 原地改文本（回调内可用）
```

通用：

```ruby
Tessell.invalidate "key" / Tessell.invalidate_all   # 失效
Tessell.handle "key" : Int32                        # 句柄（失效句柄 resolve 为 nil）
Tessell.node "key" do ... end                       # DeclKind::Node
```

约束与错误（全部以 mruby 异常呈现，带 file:line）：
- 参数类型不符 → TypeError（消息带 `[tessell-type]`）；字符串超 `max_string_bytes` → TypeError。
- 同帧重复 key、块外声明、混用两种形态、window 重复调用、句柄/声明超限 → 脚本异常。
- `Tessell.end` 不可用（Ruby 关键字），降级形态用 `Tessell.end_node`。

## 3. 宿主数据惯例（demo `Host.*` 模式）

宿主数据以**标量访问器**过桥，Ruby glue 在脚本侧拼装 demo.md §4 的 API：

```ruby
# glue（宿主 rt.eval 注入）：
def self.count(level);  Host.__count(level.to_s); end
def self.each_visible(filter, &blk)      # 宿主可见窗口切片，脚本只遍历 ~30 行
  n = Host.__visible_count(filter.to_s)
  i = 0
  while i < n
    blk.call({ id: Host.__row_id(i), time: Host.__row_time(i),
               level: Host.__row_level(i), msg: Host.__row_msg(i) })
    i += 1
  end
end
```

- 虚拟化在宿主（切片），脚本只看可见窗口；`snapshot/visible_rows` 由 glue 拼装。
- 过滤状态以脚本 `state` 为准，`__visible_count` 顺带同步宿主切片。

## 4. Config 默认值

| 项 | 默认 | 说明 |
| --- | --- | --- |
| max_string_bytes | 1 MiB | 单字符串上限 |
| max_handles | 100_000 | 句柄表容量 |
| max_decl_nodes | 20_000 | 单次声明阶段 Decl 上限 |
| max_callbacks_per_frame | 64 | 单帧回调预算 |
| callback_budget_ms | 1.0 | 超限记录告警（不中断） |
| allow_hot_reload | true | reload 开关 |

## 5. P0 未冻结 / 留给 P1

- 句柄出参扩展（脚本侧对象模型）、Symbol 出参、`Tessell.*` 布局参数（gap/padding 的 DSL 化，当前靠 auto layout 默认值）。
- 脚本错误的自动禁用/重试策略；错误条呈现位置的可配置。
- worker 线程模型（plan §11 开放问题 1，依 G4 数据不需要——同步回调 p99 0.014ms）。
