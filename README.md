# tessell-mruby

Tessell 的可选 **mruby 脚本 / 插件层**。实验性项目，当前处于 **阶段 0（计划冻结）**：仓库里是方案、骨架与验收口径，可用实现按 [`docs/plan.md`](docs/plan.md) 的 P0 任务逐项落地。

> 定位不是"用 Ruby 写 Tessell 应用"，而是给已有 Tessell 应用增加**可选的**脚本、插件、热重载能力。主应用模型仍然是有静态类型与零分配承诺的 Crystal。

## 状态

| 项目 | 状态 |
| --- | --- |
| 计划 / 方案 | ✅ 冻结（`docs/plan.md`、`docs/design.md`） |
| 仓库骨架 | ✅ 仅版本占位，无可用 API |
| P0 spike（counter demo + 六项门禁） | ⏳ 计划中，估 8–10 人日 |
| P1 独立 shard 发布 | ⏳ 未开始 |

## 为什么单独一个仓库

- `tessell` 是 GUI 核心，不能依赖 `mrb`：Crystal 的 shard 依赖没有 optional 语义，一旦声明，所有 Tessell 用户都会被拖去装 Ruby / C 工具链并先跑 `make`，直接破坏"单 exe、裸 PATH 可跑"的分发口径。
- `mrb.cr` 是通用 mruby 绑定，不应该知道窗口、`Decl`、`UiKey` 这些 GUI 概念。
- 桥接层同时依赖两者，只能住在第三个仓库：`tessell ← tessell_mruby → mrb → libmruby.a`。

## 依赖与前置条件

- [Tessell](https://github.com/ShiningRay/tessell)：Crystal ≥ 1.21，Windows 已验证（MSYS2 UCRT64）。
- [mrb.cr](https://github.com/ShiningRay/mrb.cr)：固定 commit 消费，**不 fork**。
- 上游缺口跟踪：[ShiningRay/mrb.cr#1](https://github.com/ShiningRay/mrb.cr/issues/1)（Windows 链接名、lockfile、bison/gperf 文档，以及 block / `Proc` / `yield` / `funcall` 绑定）。
- 首次使用需在 `mrb.cr` 目录执行其 `make`，产出 `lib/libmruby.a` 与 shim；Windows 下的 mingw 构建路径已实测通过（见 issue #1）。

## 文档

- [`docs/plan.md`](docs/plan.md)：目标、非目标、三阶段计划、六项门禁、工时、风险登记、验收标准。
- [`docs/design.md`](docs/design.md)：依赖方向、线程与 GC 模型、值边界、句柄表、事件流、错误隔离、性能预算。
- [`docs/demo.md`](docs/demo.md)：P0 验收用 hero demo「Log Explorer」——热重载、错误隔离、性能 HUD 与 G1–G6 的对应。
- [`examples/counter/counter.rb`](examples/counter/counter.rb)：目标形态的脚本示例（当前不可运行，仅冻结 API 方向）。

## 明确不做

- Ruby / CRuby 嵌入，或 gem 生态支持（那是"C ABI 共享库 + 官方 gem"的另一条产品线）。
- 不可信代码沙箱。mruby 没有执行配额，死循环会卡住 UI 线程；本仓库只服务可信插件，不可信输入需独立进程。
- 把脚本层变成 Tessell 的主应用模型；零分配门禁不覆盖脚本路径。

## 许可证

MIT，见 [LICENSE](LICENSE)。
