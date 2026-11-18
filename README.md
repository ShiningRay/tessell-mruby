# tessell-mruby

[![CI](https://github.com/ShiningRay/tessell-mruby/actions/workflows/ci.yml/badge.svg)](https://github.com/ShiningRay/tessell-mruby/actions/workflows/ci.yml)

Tessell 的可选 **mruby 脚本 / 插件层**。P0 spike 已完成并通过全部六项门禁（结论见 [`docs/go-no-go.md`](docs/go-no-go.md)），当前进入 P1（独立 shard 化）。

> 定位不是"用 Ruby 写 Tessell 应用"，而是给已有 Tessell 应用增加**可选的**脚本、插件、热重载能力。主应用模型仍然是有静态类型与零分配承诺的 Crystal。

## 状态

| 项目 | 状态 |
| --- | --- |
| P0 spike（Runtime/Handles/Bridge/事件 + Log Explorer demo + G1–G6） | ✅ 全部 PASS（[报告](docs/go-no-go.md)） |
| spec | ✅ 26 examples 全绿（`crystal spec`） |
| 门禁自动化 | ✅ `--demo-gates --json` 无人值守，JSON 进 CI 工件 |
| CI（windows-latest + MSYS2 UCRT64） | ✅ 构建 + spec + 门禁 |
| P1 shard 发布 | ✅ `0.1.0`（tag `v0.1.0`；API 冻结候选见 [api-freeze](docs/api-freeze.md)） |

## 为什么单独一个仓库

- `tessell` 是 GUI 核心，不能依赖 `mrb`：Crystal 的 shard 依赖没有 optional 语义，一旦声明，所有 Tessell 用户都会被拖去装 Ruby / C 工具链并先跑 `make`，直接破坏"单 exe、裸 PATH 可跑"的分发口径。
- `mrb.cr` 是通用 mruby 绑定，不应该知道窗口、`Decl`、`UiKey` 这些 GUI 概念。
- 桥接层同时依赖两者，只能住在第三个仓库：`tessell ← tessell_mruby → mrb → libmruby.a`。

## 快速开始

```powershell
# 1) 依赖与 mruby 产物（同级有 ../mrb.cr checkout 则直接拷贝，否则在 shard 内 make）
powershell -ExecutionPolicy Bypass -File scripts/build.ps1

# 2) 跑 demo（窗口模式，脚本可选；无脚本/脚本失败自动回退内置 UI）
bin\log_explorer.exe examples\log-explorer\ui.rb

# 3) 无人值守门禁（G1–G6，JSON 输出，exit code = 全过 ? 0 : 1）
bin\log_explorer.exe --demo-gates --json

# 4) headless 冒烟 / 测试
bin\log_explorer.exe --frames=60
bin\log_explorer.exe --window=25 --screenshot=shot.bmp   # 自动退出 + 抓帧

# 5) 三段演示证据（热重载 / 错误注入 / HUD → artifacts/demo_*.png）
bin\log_explorer.exe --window --demo-capture examples\log-explorer\ui.rb
```

## 实测数字（release 构建，本机 Win11 / UCRT64 / Crystal 1.22.1 / mruby 4.0.0）

| 指标 | 值 | 目标 |
| --- | --- | --- |
| G1 异常隔离 | 4 类故障全部隔离，错误含 file:line，UI 存活 | 不崩进程 |
| G2 热重载 | 50 次连续 reload p99 **1.18ms**，UiKey 稳定，live 增长 0 | ≤ 500ms |
| G3 空闲零分配 | 1000 空闲帧 delta_work = **0** | < 1000 / ≤ 256 |
| G4 事件延迟 | 1000 次真实点击 e2e p99 **2.57ms**；回调 p99 **0.014ms** | < 1 帧 / < 1ms |
| G5 包体/启动 | exe 增量 **1.19MB**；启动增量 **~3.6ms** | ≤ 2.5MB / ≤ 50ms |
| G6 稳定性 | 200 点击 + 50 重载，live 233→233，Ref 差值 0 | 无泄漏 |

## 依赖与前置条件

- [Tessell](https://github.com/ShiningRay/tessell) 0.4.1：Crystal ≥ 1.21，Windows 已验证（MSYS2 UCRT64）。
- [mrb.cr](https://github.com/ShiningRay/mrb.cr) 0.2.1：**不 fork**，固定版本消费；上游缺口跟踪 [issues #2–#5](https://github.com/ShiningRay/mrb.cr/issues)。
- 首次构建需要 mruby 静态库：`scripts/build.ps1` 自动处理（优先拷贝同级 `../mrb.cr/lib` 产物，否则在 shard 内 `make`）。
- 版本矩阵：Crystal 1.22.1 × mruby 4.0.0 × mrb.cr 0.2.1 × tessell 0.4.1（升级需全门禁重跑）。

## 文档

- [`docs/plan.md`](docs/plan.md)：目标、非目标、三阶段计划、六项门禁、工时、风险登记。
- [`docs/design.md`](docs/design.md)：依赖方向、线程与 GC 模型、值边界、句柄表、事件流、错误隔离、性能预算。
- [`docs/demo.md`](docs/demo.md)：P0 验收用 hero demo「Log Explorer」规格。
- [`docs/go-no-go.md`](docs/go-no-go.md)：**P0 结论报告**——门禁实测数字、实现要点与偏差、上游缺口、P1 建议。
- [`docs/api-freeze.md`](docs/api-freeze.md)：API 冻结候选（Crystal 侧 / 脚本 DSL / 宿主 glue 惯例 / Config）。

## 明确不做

- Ruby / CRuby 嵌入，或 gem 生态支持（那是"C ABI 共享库 + 官方 gem"的另一条产品线）。
- 不可信代码沙箱。mruby 没有执行配额，死循环会卡住 UI 线程；本仓库只服务可信插件，不可信输入需独立进程。
- 把脚本层变成 Tessell 的主应用模型；零分配门禁不覆盖脚本路径。

## 许可证

MIT，见 [LICENSE](LICENSE)。
