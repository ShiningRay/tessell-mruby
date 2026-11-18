# 更新日志

本仓库遵循 [Keep a Changelog](https://keepachangelog.com/) 风格；API 变更规则见
[api-freeze.md](docs/api-freeze.md) §6。

## 0.2.0 — 2026-11-18

P2 核心交付（plan §5 T2.1/T2.2/T2.4/T2.5/T2.6）；**API 正式冻结**
（api-freeze.md）。无破坏性变更，全部为追加面。

### 新增

- **裸 DSL sugar**（T2.1）：`Config.new(bare_dsl: true)` 开启后脚本可省略
  `Tessell.` 前缀（顶层委托 prelude，`Tessell.*` 规范形式保持规范 API）；
  热重载自动重放。默认关。
- **布局参数 DSL 化**（T2.4）：`row/column/node/begin_*` 接受可选
  `gap, padding`（位置参数或 `gap:`/`padding:` kwargs；padding 单数字 =
  四边，或 `[left, top, right, bottom]`）；不传参产出与 0.1.0 逐位一致。
- **插件发现/加载器**（T2.5）：`rt.load_plugins(dir)`——单 State 顺序 eval
  （决策记录见 plugins.cr）、清单 `plugins.json` 可选（显式顺序 +
  name/version）、逐插件错误隔离；`Config.max_plugins`（默认 64）。
- **稳定错误码**（T2.2）：`ScriptError#code`（RuntimeError/TypeError/
  ParseError/HostError/DuplicateKey/LimitExceeded/StateError），识别口径
  为消息 `[tessell-*]` 机器标签；`Kind::Host` 落地（宿主方法块内 Crystal
  异常打 `[tessell-host]` 标签，此前是无实现死代码）。
- **G8 性能基线门禁**（T2.6）：`--baseline=docs/baseline/gates-baseline.json`
  基线入库；确定性指标（exe 增量/live_objects 差值）劣化 >25% 或超 §6
  门限即 FAIL，时序 p99 噪声 2–3 倍实测后降级为 advisory。

### 变更

- 错误定位：`__tessell_protect` 取位置改为跳过 `(eval)` 帧夹层取第一个
  脚本帧——修复 prelude/HOST_GLUE 路径下错误报告 `(eval)` 的问题；
  规范形式行为不变。
- shard.yml：tessell 约束升为 `~> 0.4`、mrb.cr 升为 `~> 0.2`（0.1.0 时
  shard.yml 仍写 `~> 0.1`，实际锁 0.4.1/0.2.1——此为约束笔误的修正）。

### 条件项状态（plan §5）

- T2.3 RITE 预编译：mrb.cr#3 仍 OPEN，未触发（W8 截止）。
- T2.7 跨平台评估：tessell 0.4.1 无 Platform::Host release（X1/X3 未落地），
  未触发。
- T2.8 版本矩阵演练：tessell/mrb.cr/Crystal 均无新 minor，W8（12-20）未到，
  未触发。

## 0.1.0 — 2026-11-18

P0 spike + P1 独立 shard 化（plan §5）。首个可消费版本（tag `v0.1.0`）。

- 核心：Runtime（UI 线程单属主 `MRuby::State`、front/good 双缓冲、
  `__tessell_protect` 错误边界）、Handles（Int32 gen+id，freelist 复用）、
  Decls（parent 作用域 FNV-1a key 派生）、Events（frame/persistent 双注册表，
  `MRuby::Ref` 持 Proc）、Bridge（`Tessell.*` DSL：window/text/row/column/
  node/button + begin_*/end_node 静态降级 + on_click/set_text）。
- DSL 两种形态：block 主路径（顶层只执行一次，window block = 帧过程）与
  静态降级（`begin_*/end_node/on_click/set_text`）。
- 热重载（G2）、错误隔离（G1）、空闲零分配（G3）、事件延迟（G4）、
  包体/启动（G5：exe 增量 1.19MB / 启动 3.6ms）、稳定 soak（G6）——
  六项门禁全 PASS（本机 + CI）。
- Log Explorer demo（10k 行虚拟化、Host.* glue 模式、fallback UI、
  Win32/WGL/FT/HB 宿主）与 `--demo-gates` 无人值守门禁 JSON。
- 文档：接入指南、兼容矩阵、Go/No-Go 报告、API 冻结草案；demo 证据 GIF。
- CI：windows-latest（MSYS2 UCRT64 构建+spec+门禁）+ Linux/macOS 编译检查。
- 上游 mrb.cr issue #2–#5（不 fork）。
