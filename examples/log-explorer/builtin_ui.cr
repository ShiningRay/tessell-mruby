# 内置 UI（fallback）：与 ui.rb 等价的 Crystal 实现（demo.md §2）。
#
# - 脚本缺失 / 加载失败 / 用户关闭脚本（Script: on/off）时接管。
# - key 派生与 Decls 相同（Decls.fnv64）→ 脚本切换到内置 UI 时
#   Pool 复用同一批节点，画面不跳、身份不换（demo.md 场景 3 / G3-G5）。
# - 按钮回调注册到 HostApp 的 builtin_handlers，与脚本回调互斥生效。
require "tessell"
require "../../src/tessell_mruby"
require "./log_data"

module LogExplorer
  class BuiltinUI
    getter theme_dark : Bool = true
    getter filter : String = "all"
    getter clicks : Int32 = 0

    @handlers : Hash(Tessell::UI::UiKey, Proc(Nil))
    @stack : Array(Tessell::UI::UiKey)

    def initialize
      @handlers = Hash(Tessell::UI::UiKey, Proc(Nil)).new
      @stack = Array(Tessell::UI::UiKey).new(16)
    end

    def handlers : Hash(Tessell::UI::UiKey, Proc(Nil))
      @handlers
    end

    def click_theme_dark : Nil
      @theme_dark = !@theme_dark
      @clicks += 1
    end

    def set_filter(f : String) : Nil
      @filter = f
      @clicks += 1
    end

    def dirty? : Bool
      @clicks != @emitted_clicks
    end

    @emitted_clicks : Int32 = -1

    # 把与 ui.rb 等价的声明写入 buf（追加；parent 栈自带管理）。
    def emit(buf : Array(Tessell::UI::Decl), store : LogStore, hud_text : String) : Nil
      @emitted_clicks = @clicks
      @handlers.clear
      @stack.clear
      @stack << Tessell::UI::UiKey.root
      theme = theme_dark ? "dark" : "light"

      vstack(buf, "root") do
        hstack(buf, "toolbar") do
          text(buf, "title", "Log Explorer [builtin]")
          button(buf, "theme", "Theme: #{theme}") { click_theme_dark }
          button(buf, "f-errors", "Errors") { set_filter("errors") }
          button(buf, "f-warnings", "Warnings") { set_filter("warnings") }
          button(buf, "f-all", "All") { set_filter("all") }
        end
        hstack(buf, "kpi") do
          text(buf, "rows",     "rows #{store.counts("all")}")
          text(buf, "errors",   "errors #{store.counts("errors")}")
          text(buf, "warnings", "warnings #{store.counts("warnings")}")
        end
        vstack(buf, "rows") do
          i = 0
          n = store.visible_count
          while i < n
            if row = store.row_at(i)
              hstack(buf, "row-#{row.id}") do
                text(buf, "time", row.time)
                text(buf, "lvl",  row.level)
                text(buf, "msg",  row.message)
              end
            end
            i += 1
          end
        end
        hstack(buf, "hud") do
          text(buf, "hud-text", hud_text)
        end
      end
    end

    # ---- 发射辅助（与 Decls 同构）----

    private def current : Tessell::UI::UiKey
      @stack.last
    end

    private def push(buf : Array(Tessell::UI::Decl), key_str : String,
                     kind : Tessell::UI::DeclKind, dir : Tessell::Layout::Direction,
                     role : Tessell::A11y::Role = Tessell::A11y::Role::Group,
                     name : String = "", focusable : Bool = false) : Tessell::UI::UiKey
      key = current.child(TessellMRuby::Decls.fnv64(key_str))
      buf << Tessell::UI::Decl.new(key, current, kind, "",
        Tessell::Rect.new, dir, 0_u32, true, Tessell::Insets.new, 0.0_f32,
        TessellMRuby::Decls::DEFAULT_TEXT_SIZE, role, name, "", focusable, true)
      @stack << key
      key
    end

    private def pop : Nil
      @stack.pop if @stack.size > 1
    end

    private def vstack(buf, key_str, &) : Nil
      push(buf, key_str, Tessell::UI::DeclKind::Column, Tessell::Layout::Direction::Vertical)
      begin
        yield
      ensure
        pop
      end
    end

    private def hstack(buf, key_str, &) : Nil
      push(buf, key_str, Tessell::UI::DeclKind::Row, Tessell::Layout::Direction::Horizontal)
      begin
        yield
      ensure
        pop
      end
    end

    private def text(buf, key_str, body : String) : Nil
      key = current.child(TessellMRuby::Decls.fnv64(key_str))
      buf << Tessell::UI::Decl.new(key, current, Tessell::UI::DeclKind::Text, body,
        Tessell::Rect.new, Tessell::Layout::Direction::Vertical, 0_u32, true,
        Tessell::Insets.new, 0.0_f32, TessellMRuby::Decls::DEFAULT_TEXT_SIZE,
        Tessell::A11y::Role::Text, body, "", false, true)
    end

    private def button(buf, key_str, label : String, &handler : Proc(Nil)) : Nil
      key = push(buf, key_str, Tessell::UI::DeclKind::Row,
        Tessell::Layout::Direction::Horizontal, Tessell::A11y::Role::Button, label, true)
      begin
        text(buf, "__label", label)
      ensure
        pop
      end
      @handlers[key] = handler
    end
  end
end
