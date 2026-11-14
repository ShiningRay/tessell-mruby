# Demo 规格：Log Explorer

- 状态：P0 验收物（替代"counter 截图"）
- 目的：用 60 秒证明三件事，而不是证明"能弹窗"
- 关联：`docs/plan.md` 的 T0.6 与六项门禁 G1–G6

## 1. 要回答的三个怀疑

1. **脚本层会不会拖垮 GUI？** —— Tessell 用户最在意，必须有屏幕上的数字。
2. **"改一行立刻生效"是不是真的？** —— Ruby 用户最在意，必须现场改文件。
3. **脚本崩了会不会带崩整个应用？** —— 所有人都会问，必须现场注入错误。

一个屏幕同时回答这三件事，就是本 demo 的设计约束。

## 2. 形态

单 exe + 一个 `ui.rb`；运行时优先加载脚本，脚本缺失或加载失败时回退到内置 UI（证明脚本层是"可选"的）。

```
┌──────────────────────────────────────────────────────────────┐
│ Log Explorer     [Theme: dark]  [Errors] [Warnings] [All]    │ ← toolbar（脚本声明）
├──────────────────────────────────────────────────────────────┤
│ 12,340 rows    Errors 231    Warnings 1,102    fps 60        │ ← KPI 卡片（脚本算）
├──────────────────────────────────────────────────────────────┤
│ 12:00:01  ERROR  upstream timeout                            │
│ 12:00:01  WARN   retry 2/3                                   │ ← 长列表（脚本生成行）
│ 12:00:02  INFO   reconnect ok                                │
├──────────────────────────────────────────────────────────────┤
│ script 0.31ms p99 · idle alloc 0 · reloads 3 · live 41       │ ← 常驻 HUD
└──────────────────────────────────────────────────────────────┘
```

分屏"自描述"模式（强烈建议，演示效果最好）：左半用只读 `text` 渲染当前 `ui.rb` 源码，右半是它渲染出的 UI；文件一变，两边同时刷新。观众不需要解释就能看懂"这个界面是那段 Ruby 写的"。

## 3. 脚本 API 面（P0 要冻结的这一批）

```ruby
# ui.rb —— 目标形态（block 版本，依赖 mrb.cr 的 block/yield 支持）
state = { theme: :dark, filter: :all }

Tessell.window "log-explorer", 1000, 700 do
  Tessell.row "toolbar" do
    Tessell.text  "title", "Log Explorer"
    Tessell.button "theme", "Theme: #{state[:theme]}" do
      state[:theme] = state[:theme] == :dark ? :light : :dark
      Tessell.invalidate_all
    end
    Tessell.button "f-errors", "Errors" do
      state[:filter] = :errors
      Tessell.invalidate "rows"
    end
  end

  Tessell.row "kpi" do
    Tessell.text "rows",     "rows #{Host.count(:all)}"
    Tessell.text "errors",   "errors #{Host.count(:errors)}"
    Tessell.text "warnings", "warnings #{Host.count(:warnings)}"
  end

  Host.each_visible(state[:filter]) do |row|
    Tessell.row("row-#{row[:id]}") do
      Tessell.text "time", row[:time]
      Tessell.text "lvl",  row[:level]
      Tessell.text "msg",  row[:message]
    end
  end
end
```

降级形态（上游 block 未就绪时）：用 `Tessell.begin_row` / `Tessell.end` 与预生成的 `Host.visible_rows(state)` 数组，语义等价，只是写法啰嗦；P0 允许先跑降级版，block 就绪后切换。

脚本侧只拿 **JSON-like 值 + 整数句柄**；不暴露 `Node`、`UiKey`、指针。字符串超 1 MB 报错（`config.max_string_bytes`）。

## 4. 宿主（Crystal）侧 API

- `Host.snapshot(:logs)`：返回不可变快照（`Array(Hash)`），由后台线程生成、Channel 投递，脚本只读。
- `Host.count(level)`：快照上的计数，避免脚本每次自己遍历。
- `Host.each_visible(filter)` / `Host.visible_rows(filter)`：按视口裁剪后的行切片（虚拟化的关键；行数 1 万，实际渲染约 30 行）。
- `Host.reloads`、`Host.fps`、`Host.frame_ms_p99`、`Host.script_ms_p99`、`Host.alloc_delta_idle`：HUD 数据源。
- 脚本异常统一进宿主错误条渲染，含 `file:line`。

## 5. 三个必演场景（同时是门禁）

| 场景 | 操作 | 预期 | 门禁 |
| --- | --- | --- | --- |
| 热重载 | 在 VS Code 改主题色 / 行模板 / 按钮文案，保存 | 窗口不重启；焦点、滚动位置、行选择不丢；≤ 500 ms 生效 | G2 |
| 错误注入 | 点 `Harm` 按钮（或把 `Tessell.text` 拼错） | 底部红色错误条 + `file:line`；列表照常滚动；进程存活 ≥ 60 s | G1 |
| 脚本开关 | 点 `Script: on/off` | 关掉后内置 UI 接管；开回来空闲帧 `delta_work` 回到判据内 | G3 / G5 |

补充：连续 200 次点击 + 50 次热重载的 soak（G6），结束后 `live_objects` 不得单调增长。

## 6. HUD 指标（必须常驻）

| 指标 | 含义 | 目标 |
| --- | --- | --- |
| `fps` | 合成帧率 | ≥ 60（本机） |
| `frame_ms p99` | 帧耗时 | ≤ 16.7 ms |
| `script_ms p99` | 单次脚本回调耗时 | < 1 ms |
| `idle alloc` | 空闲帧 `delta_work` / 分配次数 | A `<1000` 且 B `<=256`；脚本帧单列 |
| `reloads` | 热重载次数 | 演示中 ≥ 3 |
| `live` | `mrb_cr_live_objects` | soak 前后无单调增长 |

技术观众不会信嘴，会看 HUD 的数字——这也是 demo 的核心资产。

## 7. 验收标准

- 三个场景全部可现场复现，且 HUD 数字与门禁报告一致；
- `--demo-gates` 模式可无人值守跑完 G1–G6 并输出 JSON（CI 用）；
- 10,000 行数据下滚动 60 fps，脚本回调 p99 < 1 ms；
- exe 增量 ≤ 2.5 MB，启动增量 ≤ 50 ms（与不带脚本层的同 demo 对比）；
- 脚本缺失时应用正常启动（fallback UI），日志明确提示"script not loaded"。

## 8. 不做清单

| 不做 | 原因 |
| --- | --- |
| 把 counter 当正式 demo | 只能证明 eval + 回调，证明不了性能与隔离 |
| 游戏（2048 / 贪吃蛇） | `DeclKind` 仅 `Node/Text/Row/Column`，需要新的绘制声明，范围会拖进渲染层 |
| 图表 / 实时曲线 | 同上，`polygon` 在 render 层但未暴露为声明 |
| 应用内代码编辑器 | Tessell 的 IME / 文本编辑未人工验证；用外部编辑器 + 热重载反而更贴 Ruby 工作流 |
| 嵌入 CRuby / gem 生态 | 方向已被否决（见 README"明确不做"） |

## 9. 构建与运行

```
# 1) 构建 mruby（一次性）
cd ../mrb.cr && make

# 2) 构建 demo
crystal build examples/log-explorer/main.cr -o log_explorer.exe

# 3) 运行（脚本可选）
./log_explorer.exe examples/log-explorer/ui.rb

# 4) 无人值守门禁
./log_explorer.exe --demo-gates --json
```

## 10. 交付物

- `examples/log-explorer/`：host 主程序、`ui.rb`、`builtin_ui.cr`（fallback）、`gates.cr`（G1–G6 自动化）。
- 60 秒 GIF / 视频（热重载 + 错误注入 + HUD 三段）。
- README 数字表：fps、frame p99、script p99、exe 增量、启动增量、soak 结果。
- `--demo-gates` 的 JSON 输出（进 CI 工件）。

## 11. 风险

| 风险 | 缓解 |
| --- | --- |
| 上游 block API 未就绪 | 先跑 `begin/end` 降级版；block 版随上游切换，接口不变 |
| 虚拟化在脚本侧做导致每帧分配 | 由宿主 `Host.visible_rows` 切片；脚本只遍历 ~30 行 |
| 热重载丢焦点/滚动 | 按 `UiKey` 快照焦点与滚动偏移，重载后恢复（G2 断言） |
| demo 范围膨胀成产品 | 固定三块区域 + 三个场景；新增需求进 P1，不进 P0 |
