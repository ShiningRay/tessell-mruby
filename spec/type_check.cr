# 仅供 CI compile-check 的类型检查入口（crystal build --no-codegen）：
# 把全部 spec 纳入类型检查而不链接 mruby 产物（Linux/macOS 无 libmruby）。
# 测试请用 `crystal spec`（Windows 门禁机）。
require "./spec_helper"
require "./handles_spec"
require "./runtime_spec"
require "./errors_spec"
require "./static_spec"
require "./prelude_spec"
