# Log Explorer 宿主（demo.md §2/§4）。
#
# 职责边界（plan §1 约束 2"不夺权"）：retained 树、apply、输入路由、
# 虚拟化切片全部在 Crystal；脚本只产出 Decl 与回调。
#
# - 单帧流程：pump 快照 → 输入路由/回调 → （needs_frame 时）声明阶段 →
#   UI.apply → auto layout → collect_dirty → consume。
# - 脚本与内置 UI 互斥切换，key 同源派生 → 节点身份跨切换稳定。
# - 错误条与 HUD 是宿主区（magic local，与脚本 key 空间分离）。
require "tessell"
require "../../src/tessell_mruby"
require "./log_data"
require "./builtin_ui"
require "./shared"

module LogExplorer
  # 宿主区 key（root.child(magic)）：与脚本 key（root.child(fnv(str))）空间
  # 理论上可碰撞，取非 FNV 输出的常量使实际碰撞不可构造。
  HUD_KEY = Tessell::UI::UiKey.root.child(0x5e55e11_0000_0001_u64)
  ERR_KEY = Tessell::UI::UiKey.root.child(0x5e55e11_0000_0002_u64)

  class HostApp
    LIST_VIEWPORT_H = HEIGHT - 120

    getter root : Node
    getter pool : UI::Pool
    getter router : Input::Router
    getter store : LogStore
    getter runtime : TessellMRuby::Runtime?
    getter script_path : String?
    getter last_script_error : TessellMRuby::ScriptError?

    def last_script_error
      @last_error_for_bar
    end
    getter script_active : Bool = false
    getter script_loaded : Bool = false
    getter dirty_nodes : Array(Node)
    getter last_decls : Array(UI::Decl)
    getter frames : Int32 = 0
    getter click_count : Int32 = 0
    getter wheel_count : Int32 = 0
    getter fps : Float64
    getter last_frame_ms : Float64

    @builtin : BuiltinUI
    @measurer : Text::Measurer
    @builder_buf : Array(UI::Decl)
    @needs_rebuild : Bool = true
    @script_enabled : Bool = true
    @last_error_for_bar : TessellMRuby::ScriptError?
    @frame_times : TimingRing
    @idle_alloc : Int64 = 0
    @fps : Float64 = 0.0
    @last_frame_ms : Float64 = 0.0

    def initialize(@script_path : String?, headless : Bool = true,
                   measurer : Text::Measurer? = nil)
      @store = LogStore.new(LIST_VIEWPORT_H)
      @root = Node.new("root", Rect.new(0.0_f32, 0.0_f32, WIDTH.to_f32, HEIGHT.to_f32))
      @pool = UI::Pool.new
      @router = Input::Router.new
      @builtin = BuiltinUI.new
      @measurer = measurer || EstimateMeasurer.new
      @builder_buf = Array(UI::Decl).new(512)
      @dirty_nodes = Array(Node).new(64)
      @last_decls = Array(UI::Decl).new(512)
      @frame_times = TimingRing.new
      @last_error_for_bar = nil
      if sp = @script_path
        setup_runtime(sp)
      else
        @last_error_for_bar = TessellMRuby::ScriptError.new(TessellMRuby::ScriptError::Kind::Raise,
          "script not loaded (no script path given) — builtin UI active")
        STDERR.puts "log-explorer: script not loaded (no script path given) — builtin UI active"
      end
    end

    # ---- TessellMRuby::Runtime 装配 ----

    private def setup_runtime(path : String) : Nil
      rt = TessellMRuby::Runtime.new(TessellMRuby::Config.new(allow_hot_reload: true))
      rt.on_error = ->(err : TessellMRuby::ScriptError) { @last_error_for_bar = err }
      register_host_module(rt)
      begin
        rt.load_file(path)
        rt.eval(HOST_GLUE)
        @script_loaded = true
        @script_active = true
        @runtime = rt
        rt.request_frame
      rescue se : TessellMRuby::ScriptError
        @last_error_for_bar = se
        STDERR.puts "log-explorer: script failed to load: #{se.message}"
        rt.close
        @runtime = nil
      end
    end

    # Host.* 模块方法（demo.md §4）：宿主数据只以 JSON-like 标量过桥。
    private def register_host_module(rt : TessellMRuby::Runtime) : Nil
      store = @store
      app = self
      rt.host_module("Host")
      rt.host_method("Host", "__count", 1) do |args|
        v = args[0]
        store.counts(v.string? ? v.as_s : "all").to_i64
      end
      rt.host_method("Host", "__visible_count", 1) do |args|
        v = args[0]
        store.set_filter(v.string? ? v.as_s : "all") if v.string? && v.as_s != store.filter
        store.visible_count.to_i64
      end
      rt.host_method("Host", "__row_id", 1) do |args|
        (store.row_at(args[0].as_i64.to_i32).try(&.id) || 0).to_i64
      end
      rt.host_method("Host", "__row_time", 1) do |args|
        store.row_at(args[0].as_i64.to_i32).try(&.time) || ""
      end
      rt.host_method("Host", "__row_level", 1) do |args|
        store.row_at(args[0].as_i64.to_i32).try(&.level) || ""
      end
      rt.host_method("Host", "__row_msg", 1) do |args|
        store.row_at(args[0].as_i64.to_i32).try(&.message) || ""
      end
      rt.host_method("Host", "reloads", 0) { rt.reloads.to_i64 }
      rt.host_method("Host", "live", 0) { rt.live_objects }
      rt.host_method("Host", "script_ms_p99", 0) { rt.script_timing.p99 }
      rt.host_method("Host", "idle_alloc", 0) { app.idle_alloc }
      rt.host_method("Host", "fps", 0) { (app.fps * 10).round / 10.0 }
    end

    def idle_alloc : Int64
      @idle_alloc
    end

    # Ruby 侧 glue：demo.md §4 冻结的 Host API（count / each_visible /
    # visible_rows / snapshot），全部由标量访问器拼装。
    HOST_GLUE = <<-RUBY
      module Host
        def self.count(level)
          Host.__count(level.to_s)
        end

        def self.each_visible(filter, &blk)
          n = Host.__visible_count(filter.to_s)
          i = 0
          while i < n
            blk.call({ id: Host.__row_id(i), time: Host.__row_time(i),
                       level: Host.__row_level(i), msg: Host.__row_msg(i) })
            i += 1
          end
          nil
        end

        def self.visible_rows(filter)
          n = Host.__visible_count(filter.to_s)
          out = []
          i = 0
          while i < n
            out << { id: Host.__row_id(i), time: Host.__row_time(i),
                     level: Host.__row_level(i), msg: Host.__row_msg(i) }
            i += 1
          end
          out
        end

        def self.snapshot(kind)
          visible_rows(kind.to_s)
        end
      end
    RUBY

    # ---- 输入 ----

    def handle_event(ev : Input::Event) : Nil
      target = @router.handle(ev, @root)
      case ev.kind
      when .pointer_up?
        if target && (key = key_for_node(target))
          dispatch_click(key)
        end
      when .wheel?
        dy = (ev.wheel_dy * LogStore::ROW_STEP_PX).to_i32
        if dy != 0
          @store.scroll_by(-dy)
          @wheel_count += 1
          request_rebuild
        end
      else
        nil
      end
    end

    private def key_for_node(node : Node) : Tessell::UI::UiKey?
      @pool.map.each do |k, n|
        return k if n.same?(node)
      end
      nil
    end

    private def dispatch_click(key : Tessell::UI::UiKey) : Nil
      @click_count += 1
      if rt = @runtime
        d = rt.dispatch_click(key)
        rt.request_frame # 事件帧强制重建（回调可能只改内部状态）
        @last_error_for_bar = d.error if d.error
        return
      end
      if h = @builtin.handlers[key]?
        h.call
        request_rebuild
      end
    end

    def request_rebuild : Nil
      @needs_rebuild = true
    end

    # Script: on/off（demo.md 场景 3）。切换不重建 State：Pool 节点按 key
    # 复用（builtin 与脚本 key 同源派生）。
    def toggle_script : Nil
      if @script_loaded
        @script_enabled = !@script_enabled
        @script_active = @script_enabled
        request_rebuild
      end
    end

    # 热重载（G2）。返回耗时 ms；失败更新错误条（good 缓冲不动 → 旧 UI 保持）。
    def reload_script : Float64
      sp = @script_path
      return 0.0 unless sp && (rt = @runtime)
      t0 = Time.monotonic
      begin
        rt.reload(sp)
        # 新 State：Host 模块与 glue 全部重装。
        register_host_module(rt)
        rt.eval(HOST_GLUE)
        rt.request_frame
        @last_error_for_bar = nil
      rescue se : TessellMRuby::ScriptError
        @last_error_for_bar = se
      end
      (Time.monotonic - t0).total_milliseconds
    end

    # ---- 帧循环 ----

    # 一帧。返回本帧是否发生了声明阶段重建（含脚本运行）。
    def frame : Bool
      @frames += 1
      t0 = Time.monotonic

      rebuild = @needs_rebuild
      if !rebuild && @script_active && (rt = @runtime)
        rebuild = rt.needs_frame?
      end
      if rebuild
        run_declaration_phase
        @needs_rebuild = false
      end
      @last_frame_ms = (Time.monotonic - t0).total_milliseconds
      @frame_times.push(@last_frame_ms)
      @fps = @last_frame_ms > 0 ? 1000.0 / @last_frame_ms : 0.0
      rebuild
    end

    private def run_declaration_phase : Nil
      @store.pump
      buf = @builder_buf
      buf.clear

      if @script_active && (rt = @runtime)
        result = rt.run_frame
        # 成功 = 本帧声明；失败 = good 缓冲（上一帧画面保持，G1）
        buf.concat(result.decls)
        @last_error_for_bar = result.error if result.error
      else
        @builtin.emit(buf, @store, hud_text)
      end

      # 宿主区：HUD + 错误条。
      append_host_bars(buf)

      @last_decls = buf
      UI.apply(buf, @root, @pool)
      UI.apply_auto_layout(buf, @pool,
        Rect.new(0.0_f32, 0.0_f32, WIDTH.to_f32, (HEIGHT - HUD_H - ERR_H).to_f32),
        @measurer)
      Node.collect_dirty(@root, @dirty_nodes)
      UI.consume(@dirty_nodes)
    end

    private def append_host_bars(buf : Array(UI::Decl)) : Nil
      bottom = (HEIGHT - HUD_H).to_f32
      hud_rect = Rect.new(0.0_f32, bottom, WIDTH.to_f32, HUD_H.to_f32)
      buf << UI::Decl.new(HUD_KEY, Tessell::UI::UiKey.root, UI::DeclKind::Text,
        hud_text, hud_rect, Tessell::Layout::Direction::Vertical, 0_u32, false,
        Tessell::Insets.new, 0.0_f32, 12.0_f32,
        Tessell::A11y::Role::Text, "hud", "", false, true)
      if err = @last_error_for_bar
        err_rect = Rect.new(0.0_f32, bottom - ERR_H.to_f32, WIDTH.to_f32, ERR_H.to_f32)
        msg = "script error: #{err.location}: #{err.script_class}: #{err.raw_message}"
        buf << UI::Decl.new(ERR_KEY, Tessell::UI::UiKey.root, UI::DeclKind::Text,
          msg[0, 160], err_rect, Tessell::Layout::Direction::Vertical, 0_u32, false,
          Tessell::Insets.new, 0.0_f32, 12.0_f32,
          Tessell::A11y::Role::Text, "script error", msg, false, true)
      end
    end

    def hud_text : String
      rt = @runtime
      script_p99 = rt ? rt.script_timing.p99 : 0.0
      live = rt ? rt.live_objects : 0_i64
      reloads = rt ? rt.reloads : 0
      "script #{script_p99.round(2)}ms p99 · frame #{@last_frame_ms.round(2)}ms · " \
      "idle alloc #{@idle_alloc} · reloads #{reloads} · live #{live} · " \
      "clicks #{@click_count} · wheel #{@wheel_count}"
    end

    # 空闲帧分配基线（G3）：由门禁在受控窗口内测量后回填 HUD。
    def record_idle_alloc(delta : Int64) : Nil
      @idle_alloc = delta
    end

    def script_timing_p99 : Float64
      rt = @runtime
      rt ? rt.script_timing.p99 : 0.0
    end

    def callback_timing_p99 : Float64
      rt = @runtime
      rt ? rt.callback_timing.p99 : 0.0
    end

    def live_objects : Int64
      rt = @runtime
      rt ? rt.live_objects : 0_i64
    end

    def reloads : Int32
      rt = @runtime
      rt ? rt.reloads : 0
    end

    def frame_ms_p99 : Float64
      @frame_times.p99
    end

    def close : Nil
      @runtime.try(&.close)
    end
  end

  # 轻量计时环（demo HUD / 门禁）。
  class TimingRing
    CAP = 512

    @samples : Slice(Float64)
    @n = 0
    @i = 0

    def initialize
      @samples = Slice(Float64).new(CAP)
    end

    def push(v : Float64) : Nil
      @samples[@i] = v
      @i = (@i + 1) % CAP
      @n += 1 if @n < CAP
    end

    def p99 : Float64
      percentile(99)
    end

    def percentile(p : Int32) : Float64
      return 0.0 if @n == 0
      arr = Array(Float64).new(@n)
      i = 0
      while i < @n
        arr << @samples[i]
        i += 1
      end
      arr.sort!
      idx = ((@n - 1) * p) // 100
      arr[idx]
    end

    def max : Float64
      m = 0.0
      i = 0
      while i < @n
        v = @samples[i]
        m = v if v > m
        i += 1
      end
      m
    end

    def count : Int32
      @n
    end
  end
end
