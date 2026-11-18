# Tessell 的可选 mruby 脚本层。
#
# 脚本只产出声明与回调；retained 树、布局、渲染、输入路由仍全部由
# Crystal 拥有（docs/design.md §1 的硬约束：tessell ← tessell_mruby → mrb）。
#
# 用法（plan T0 硬性产出）：
# ```
# TessellMRuby.open("ui.rb") do |rt|
#   rt.request_frame            # 初始渲染
#   loop do                     # UI 线程内
#     next unless rt.needs_frame?
#     result = rt.run_frame     # 声明阶段（错误隔离）
#     UI.apply(result.decls, root, pool)
#   end
# end
# ```
require "./tessell_mruby/config"
require "./tessell_mruby/errors"
require "./tessell_mruby/handles"
require "./tessell_mruby/decls"
require "./tessell_mruby/events"
require "./tessell_mruby/runtime"
require "./tessell_mruby/bridge"
require "./tessell_mruby/plugins"

module TessellMRuby
  VERSION = "0.1.0"

  # 脚本层入口：创建 Runtime，可选加载脚本，块结束时安全关闭
  # （events → handles → state.close 的固定顺序，design §9）。
  #
  # load_file 失败抛 ScriptError（含 file:line）；运行时创建失败抛 InitError。
  def self.open(script : String? = nil, config : Config = Config.new, & : Runtime -> _)
    runtime = Runtime.new(config)
    begin
      runtime.load_file(script) if script
      yield runtime
    ensure
      runtime.close
    end
  end
end
