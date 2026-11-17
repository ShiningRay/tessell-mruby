# G5 基线：同一 demo 的"不带脚本层"构建（demo.md §7 的 exe 增量对比项）。
#
# 与 log_explorer.exe 相同的内置 UI 声明、同一 apply/auto-layout 帧骨架，
# 只是没有 tessell_mruby / mrb 链接。构建：
#   crystal build --release examples/log-explorer/main_builtin.cr -o bin/log_explorer_builtin.exe
require "tessell"
require "./log_data"
require "./builtin_ui"
require "./shared"

module LogExplorer
  class BuiltinHostApp
    getter frames : Int32 = 0

    @store : LogStore
    @root : Node
    @pool : UI::Pool
    @builder_buf : Array(UI::Decl)
    @dirty_nodes : Array(Node)
    @builtin : BuiltinUI
    @measurer : Text::Measurer
    @needs_rebuild : Bool = true

    def initialize
      @store = LogStore.new(LIST_VIEWPORT_H)
      @root = Node.new("root", Rect.new(0.0_f32, 0.0_f32, WIDTH.to_f32, HEIGHT.to_f32))
      @pool = UI::Pool.new
      @builder_buf = Array(UI::Decl).new(512)
      @dirty_nodes = Array(Node).new(64)
      @builtin = BuiltinUI.new
      @measurer = EstimateMeasurer.new
    end

    LIST_VIEWPORT_H = HEIGHT - 120

    def frame : Bool
      @frames += 1
      rebuild = @needs_rebuild
      if rebuild
        buf = @builder_buf
        buf.clear
        @builtin.emit(buf, @store, "builtin baseline · frames #{@frames}")
        UI.apply(buf, @root, @pool)
        UI.apply_auto_layout(buf, @pool,
          Rect.new(0.0_f32, 0.0_f32, WIDTH.to_f32, (HEIGHT - HUD_H).to_f32), @measurer)
        Node.collect_dirty(@root, @dirty_nodes)
        UI.consume(@dirty_nodes)
        @needs_rebuild = false
      end
      rebuild
    end
  end
end

app = LogExplorer::BuiltinHostApp.new
10.times { app.frame }
puts "builtin baseline ready: decls=#{app.frames}"
