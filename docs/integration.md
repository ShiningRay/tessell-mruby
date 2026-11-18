# 接入指南：给 Tessell 应用加 mruby 脚本层

- 适用版本：tessell_mruby 0.2.0（兼容矩阵见 [COMPATIBILITY.md](COMPATIBILITY.md)；API 已正式冻结）
- 前提：已读过 [api-freeze.md](api-freeze.md)（API 面）与 [design.md](design.md) §3（线程契约）
- 参考实现：`examples/log-explorer/host_app.cr`（本指南的每一步都能在那里对上号）

## 0. 适用判断

满足以下全部条件再接：

1. 应用已有 Tessell 的 `UI.build → UI.apply` 帧循环（raw DSL 或 Kit）。
2. 需要的是**可选的**用户脚本 / 插件 / 热重载，而不是把主模型换成 Ruby。
3. 脚本来源可信（mruby 无执行配额，死循环会占住 UI 线程）。

## 1. 依赖声明

```yaml
# shard.yml
dependencies:
  tessell:
    github: ShiningRay/tessell
    version: "~> 0.4"
  mrb:
    github: ShiningRay/mrb.cr
    version: "~> 0.2"      # 固定 minor；升级需重跑门禁（见 COMPATIBILITY.md）
  tessell_mruby:
    github: ShiningRay/tessell-mruby
    version: "~> 0.2"
```

构建前置：需要 mruby 静态库。`shards install` 后在 `lib/mrb` 内执行其 `make`
（需 ruby + gcc + 网络）；或像 `scripts/build.sh` 那样从同级 `../mrb.cr/lib`
checkout 拷贝 `libmruby.a/.lib + mrb_shim.o/.obj` 到 `lib/mrb/lib/`。
Windows 链接名（.a/.lib 双后缀）由 mrb.cr 的 Makefile 归一化，无需额外处理。

## 2. 最小接入（约 40 行）

```crystal
require "tessell"
require "tessell_mruby"   # github: ShiningRay/tessell-mruby

class ScriptHost
  getter root : Tessell::Node
  getter pool : Tessell::UI::Pool
  getter runtime : TessellMRuby::Runtime?

  def initialize(@script_path : String)
    @root = Tessell::Node.new("root", Tessell::Rect.new(0, 0, 800, 600))
    @pool = Tessell::UI::Pool.new
    @builder_buf = Array(Tessell::UI::Decl).new(256)
    @measurer = MyMeasurer.new          # 任意 Tessell::Text::Measurer 实现
    setup
  end

  private def setup
    rt = TessellMRuby::Runtime.new(TessellMRuby::Config.new(allow_hot_reload: true))
    rt.on_error = ->(err : TessellMRuby::ScriptError) { @error_bar = err }
    register_host_data(rt)              # §3
    rt.load_file(@script_path)          # 失败抛 ScriptError（含 file:line）
    rt.eval(HOST_GLUE)                  # §3 的 Ruby glue
    rt.request_frame
    @runtime = rt
  rescue se : TessellMRuby::ScriptError
    # 脚本缺失/损坏 → 应用照常跑内置 UI（脚本层必须可选）
  end

  # UI 线程每帧调用；返回本帧是否重建了声明
  def frame : Bool
    rt = @runtime
    rebuild = rt ? rt.needs_frame? : @needs_rebuild
    return false unless rebuild
    buf = @builder_buf; buf.clear
    if rt
      result = rt.run_frame             # 声明阶段（错误隔离；失败时 decls = 上帧 good）
      buf.concat(result.decls)
    end
    append_host_bars(buf)               # HUD / 错误条（宿主区 decl，见 §5）
    Tessell::UI.apply(buf, @root, @pool)
    Tessell::UI.apply_auto_layout(buf, @pool, viewport_rect, @measurer)
    dirty = Array(Tessell::Node).new(64)
    Tessell::Node.collect_dirty(@root, dirty)
    Tessell::UI.consume(dirty)
    true
  end

  def close
    @runtime.try(&.close)               # events → handles → state.close 固定顺序
  end
end
```

要点：
- **所有 Runtime 调用都在 UI 线程**（Tessell 的 Isolated 执行上下文 / 窗口循环线程）。
  `MRuby::State` 非线程安全，业务线程只允许传不可变快照（design §3）。
- 声明阶段失败时 `run_frame` 返回的 `decls` 是上一帧的 good 缓冲——直接 apply 即可，
  UI 保持上帧画面，错误进错误条。不需要 try/rescue。

## 3. 宿主数据：Host.* glue 模式

宿主数据**只以 JSON-like 标量过桥**（`CallbackValue`：nil/bool/int/float/string）。
demo 的做法是宿主注册 `__` 前缀标量访问器，Ruby glue 在脚本侧拼装语义 API：

```crystal
rt.host_module("Host")
rt.host_method("Host", "__count", 1) { |args| store.counts(args[0].as_s).to_i64 }
rt.host_method("Host", "__row_time", 1) { |args| store.row_at(args[0].as_i64.to_i32).try(&.time) || "" }
```

```ruby
# HOST_GLUE（rt.eval 注入；冻结的脚本可见 API）
module Host
  def self.count(level)
    Host.__count(level.to_s)
  end
  def self.each_visible(filter, &blk)     # 虚拟化：脚本只遍历可见窗口 ~30 行
    n = Host.__visible_count(filter.to_s)
    i = 0
    while i < n
      blk.call({ id: Host.__row_id(i), time: Host.__row_time(i) })
      i += 1
    end
  end
end
```

原则：重活（过滤、切片、计数）在宿主；脚本每帧只做声明与轻量拼装。

## 4. 脚本形状（冻结）

见 api-freeze.md §2。两条硬规则：

1. **顶层只执行一次**；`Tessell.window(...) { ... }` 的 block 是帧过程，顶层局部变量
   （`state = {...}`）被闭包持有跨帧存活。改完内部状态必须 `Tessell.invalidate_all`。
2. **所有区域包在单一外层容器内**（如 `Tessell.column "root" do ... end`）——
   各区域是独立 auto 布局根时会被 viewport 原点分别求解并全部叠在 y=0。

无 block 的 `Tessell.window` 进入静态降级形态（`begin_*/end_node`/`on_click`/`set_text`），
语义等价、写法线性，适合生成型脚本。

## 5. 错误条与 HUD（宿主区）

错误条 / HUD 是宿主自己追加的 decl（与脚本 key 空间分离，用非 FNV 输出的 magic
`UiKey.root.child(...)`）：

```crystal
HUD_KEY = Tessell::UI::UiKey.root.child(0x5e55e11_0000_0001_u64)

if err = @error_bar
  buf << Tessell::UI::Decl.new(ERR_KEY, Tessell::UI::UiKey.root,
    Tessell::UI::DeclKind::Text, "script error: #{err.location}: #{err.raw_message}",
    err_rect, Tessell::Layout::Direction::Vertical, 0_u32, false, ...)
end
```

`ScriptError` 提供 `kind`（Raise/TypeError/Host）、`script_class`、`script_file`、
`script_line`、`location`。已知缺口：顶层运行期异常的行号为 nil（mrb.cr 未暴露
C 层 backtrace，见 issue #2）；声明阶段与回调路径 file:line 齐全。

## 6. 输入与回调

点击经 Router 命中后**沿祖先链找最近回调**（脚本回调挂在按钮容器上，命中常落在
其文本子节点）：

```crystal
def dispatch_click_up(node : Tessell::Node, rt : TessellMRuby::Runtime) : Nil
  n = node
  while n
    if key = key_for_node(n)                    # pool.map 反查 UiKey
      d = rt.dispatch_click(key)
      if d.dispatched
        rt.request_frame                        # 事件帧强制重建
        @error_bar = d.error if d.error
        return
      end
    end
    n = n.parent
  end
end
```

`dispatch_click` 与 `run_frame` 一样是错误隔离的：脚本异常转 `DispatchResult#error`，
进程不受影响。单帧回调预算 `config.max_callbacks_per_frame`（默认 64）。

## 7. 热重载

```crystal
def reload_script(path : String, rt : TessellMRuby::Runtime) : Nil
  rt.reload(path)            # Ref 全释放 → 新 State → DSL 重注册
  register_host_data(rt)     # ⚠ 宿主模块也要重注册（新 State 是空的）
  rt.eval(HOST_GLUE)
  rt.request_frame
rescue se : TessellMRuby::ScriptError
  @error_bar = se            # 失败：good 缓冲不动，旧 UI 保持
end
```

文件监听（demo 用 250ms mtime 轮询线程 + Channel 通知 UI 线程）放**默认执行上下文**，
UI 线程只消费信号。焦点/滚动位置由宿主持有、按 UiKey 恢复——跨重载节点身份由
脚本字符串 key 稳定派生保证（G2 实测 50 次重载 key 全程一致）。

## 8. 打包与预算

- exe 增量实测 1.19MB（静态 libmruby 4.9MB 经死码消除），启动增量 ~3.6ms。
- 统一 `--release`：本机 binutils 2.47 快照的 debug 链接有 ld 崩溃问题（go-no-go §3.8）。
- 帧预算：空闲帧零脚本调用（G3 delta_work=0）；脚本帧 p99 实测 ~0.2ms（30 行规模），
  单回调 p99 < 0.02ms——不会触碰 16.7ms 帧预算，除非脚本本身做重活（那是脚本的问题，
  体现在 script_timing，宿主可据此熔断）。

## 9. 不做清单（接入时同样遵守）

- 不把 `Node` / `UiKey` / 指针暴露给脚本（只给标量 + 整数句柄）。
- 不在非 UI 线程触碰 Runtime / Value / Ref。
- 不给脚本接不可信输入（无执行配额）；需要隔离时走独立进程。
- 不让脚本成为主应用模型；零分配门禁口径不含脚本帧。
