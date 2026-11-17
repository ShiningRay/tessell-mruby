require "mrb"
require "tessell"

module TessellMRuby
  # Runtime（T0.2/T0.5，design §2/§3/§8/§9）。
  #
  # - MRuby::State 单属主、非线程安全：必须在 UI 线程创建/调用/关闭（design §3）。
  # - 脚本异常隔离：声明阶段与回调全部包在错误边界里，异常转 ScriptError
  #   （含 file:line），good 缓冲不动、UI 继续（G1）。
  # - 生命周期顺序（design §9）：events（释放回调 Ref）→ handles → state.close。
  class Runtime
    getter config : Config
    getter decls : Decls
    getter handles : Handles
    getter events : Events

    getter window_title : String
    getter window_width : Int32
    getter window_height : Int32

    getter last_error : ScriptError?
    getter errors : Array(ScriptError)
    getter reloads : Int32

    property on_error : Proc(ScriptError, Nil)?

    enum Mode
      Unset
      Block    # window block = 帧过程，每帧重跑
      Static   # begin/end 降级形态，顶层线性发射一次
    end

    # 单次声明阶段 / 单次回调的结果。
    struct RunResult
      getter decls : Array(Tessell::UI::Decl)
      getter error : ScriptError?
      getter script_ms : Float64

      def initialize(@decls : Array(Tessell::UI::Decl), @error : ScriptError?, @script_ms : Float64)
      end
    end

    struct DispatchResult
      getter dispatched : Bool
      getter error : ScriptError?
      getter script_ms : Float64

      def initialize(@dispatched : Bool, @error : ScriptError?, @script_ms : Float64)
      end
    end

    @state : MRuby::State
    @frame_proc : MRuby::Ref?
    @key_handles : Hash(Tessell::UI::UiKey, Int32)
    @mode : Mode = Mode::Unset
    @loading : Bool = false
    @in_phase : Bool = false
    @needs_frame : Bool = true
    @closed : Bool = false
    @window_set : Bool = false
    @invalidate_total : Int64 = 0
    @last_error : ScriptError? = nil
    @errors : Array(ScriptError) = [] of ScriptError
    @reloads : Int32 = 0
    # Ruby 层错误边界（__tessell_protect）：mruby 的 Exception#backtrace 只能
    # 在 Ruby 里取到（mrb_cr 未暴露 C API，不 fork 上游——见 P0 上游 issue 清单），
    # 因此声明阶段与回调经由一个 Ruby wrapper 调用，异常在 Ruby 侧 rescue 后
    # 把 class/message/位置回传宿主。@caught_in_protect 是 wrapper → Runtime
    # 的错误通道。
    @protect_recv : MRuby::Ref?
    @caught_in_protect : ScriptError? = nil

    # 计时环（HUD p99 用；容量 1024，滚动覆盖）。
    class Timing
      CAP = 1024

      @samples : Slice(Float32)
      @n = 0
      @i = 0

      def initialize
        @samples = Slice(Float32).new(CAP)
      end

      def push(ms : Float64) : Nil
        @samples[@i] = ms.to_f32
        @i = (@i + 1) % CAP
        @n += 1 if @n < CAP
      end

      def last : Float64
        return 0.0 if @n == 0
        @samples[(@i - 1 + CAP) % CAP].to_f64
      end

      def max : Float64
        m = 0.0_f32
        i = 0
        while i < @n
          v = @samples[i]
          m = v if v > m
          i += 1
        end
        m.to_f64
      end

      def p99 : Float64
        return 0.0 if @n == 0
        # HUD 只读路径按需排序（拷贝小容量切片，不在声明阶段调用）。
        arr = Array(Float32).new(@n)
        i = 0
        while i < @n
          arr << @samples[i]
          i += 1
        end
        arr.sort!
        idx = ((@n - 1) * 99) // 100
        arr[idx].to_f64
      end

      def count : Int32
        @n
      end
    end

    getter script_timing : Timing
    getter callback_timing : Timing

    def initialize(@config : Config = Config.new)
      # libmruby/shim 未构建时显式失败（InitError），不允许静默降级（design §8）。
      @state = begin
        MRuby::State.new
      rescue ex : Exception
        raise InitError.new("mruby state init failed: #{ex.message} — build libmruby first (see docs/plan.md §12 / scripts/build.ps1)")
      end
      @decls = Decls.new(@config)
      @handles = Handles.new(@config.max_handles)
      @events = Events.new
      @key_handles = Hash(Tessell::UI::UiKey, Int32).new
      @window_title = ""
      @window_width = 0
      @window_height = 0
      @script_timing = Timing.new
      @callback_timing = Timing.new
      Bridge.install(self)
      install_error_boundary
    end

    # ---- 错误边界 glue ----

    PROTECT_GLUE = <<-RUBY
      def __tessell_protect
        yield
      rescue Exception => e
        loc = ""
        begin
          bt = e.backtrace
          loc = bt[0].to_s if bt && bt.size > 0
        rescue Exception
        end
        Tessell.__tessell_report(e.class.to_s, e.message.to_s, loc)
        nil
      end
    RUBY

    # 注册 Ruby 层保护 wrapper 与回传宿主方法。reload 后需重装。
    private def install_error_boundary : Nil
      @state.define_module_function("Tessell", "__tessell_report", 3) do |args|
        cls = args[0].string? ? args[0].as_s : nil
        msg = args[1].string? ? args[1].as_s : "unknown script error"
        loc = args[2].string? ? args[2].as_s : ""
        file, line = parse_location(loc)
        kind = msg.starts_with?("[tessell-type]") ? ScriptError::Kind::TypeError : ScriptError::Kind::Raise
        err = ScriptError.new(kind, msg, cls, file, line)
        @caught_in_protect = err
        record_error(err)
        nil
      end
      @state.eval(PROTECT_GLUE)
      @protect_recv = @state.ref(@state.eval("self"))
    end

    # "ui.rb:12" / "ui.rb:12:in foo" / Windows 盘符路径 "C:\\dir\\ui.rb:12" → (file, line)
    private def parse_location(loc : String) : {String?, Int32?}
      if m = loc.match(/\A(.+):(\d+)(:in .*)?\z/)
        {m[1], m[2].to_i32}
      else
        {nil, nil}
      end
    end

    # 经 Ruby 层保护 wrapper 调用一个 Proc（帧过程 / 回调）。
    # 返回 wrapper 捕获的 ScriptError（nil = 无异常）。
    private def invoke_protected(proc_value : MRuby::Value) : ScriptError?
      recv = @protect_recv
      unless recv && !recv.released?
        raise ScriptError.new(ScriptError::Kind::Raise, "error boundary is not installed")
      end
      @caught_in_protect = nil
      begin
        @state.funcall(recv.value, "__tessell_protect",
          [] of MRuby::CallbackValue, block: proc_value)
      rescue ex : MRuby::Error
        # wrapper 自身失败（极少数：mruby 内部错误越过 rescue）
        return ScriptError.from_mruby(ex, classify(ex))
      end
      @caught_in_protect
    end

    # ---- 宿主侧 API ----

    # 定义宿主模块 + 模块方法（demo 的 Host.* 走这里）。
    def host_module(name : String) : Nil
      ensure_open!
      @state.define_module(name)
    end

    def host_method(module_name : String, name : String, arity : Int32,
                    &block : MRuby::Args -> MRuby::CallbackValue) : Nil
      ensure_open!
      @state.define_module_function(module_name, name, arity) { |args| block.call(args) }
    end

    def eval(code : String) : MRuby::Value
      ensure_open!
      begin
        @state.eval(code)
      rescue ex : MRuby::Error
        se = ScriptError.from_mruby(ex, classify(ex))
        record_error(se)
        raise se
      end
    end

    def load_file(path : String) : Nil
      ensure_open!
      @loading = true
      begin
        code = File.read(path)
        # 解析错误：先直接编译——mruby parser 消息带精确 "line N"，file=path。
        # （compile+load_irep 的 dump 往返会丢 debug info——上游缺口，见
        # P0 上游 issue 清单——所以执行仍走 load_file 的内存编译路径。）
        @state.compile(code, path)
        @state.load_file(path)
      rescue ex : MRuby::Error
        se = ScriptError.from_mruby(ex, classify(ex))
        record_error(se)
        raise se
      ensure
        @loading = false
      end
      # block 模式加载完成后，下一帧跑帧过程；静态模式缓冲已在 load 中就绪。
      # 顶层运行期异常：file 可得、line 不可得（mruby 异常消息不带位置，
      # C 层 backtrace API 未由 mrb.cr 暴露）——声明阶段与回调经
      # __tessell_protect wrapper，file:line 都有。
      @needs_frame = true
    end

    def closed? : Bool
      @closed
    end

    def close : Nil
      return if @closed
      @closed = true
      @events.release_all
      @frame_proc.try(&.release)
      @frame_proc = nil
      @protect_recv.try(&.release)
      @protect_recv = nil
      @handles.clear
      @state.close
    end

    # ---- 状态查询 ----

    # mruby State（宿主 glue / 高级用法）。单属主：只允许 UI 线程触碰。
    def state : MRuby::State
      @state
    end

    protected def static_mode? : Bool
      @mode == Mode::Static
    end

    protected def loading? : Bool
      @loading
    end

    protected def in_phase? : Bool
      @in_phase
    end

    protected def window_title_set? : Bool
      @window_set
    end

    protected def set_window(title : String, w : Int64, h : Int64) : Nil
      @window_title = title
      @window_width = w.to_i32
      @window_height = h.to_i32
      @window_set = true
    end

    protected def enter_block_mode : Nil
      raise ArgumentError.new("script mixes block DSL and static begin_* DSL") if @mode == Mode::Static
      @mode = Mode::Block
    end

    protected def enter_static_mode : Nil
      raise ArgumentError.new("script mixes block DSL and static begin_* DSL") if @mode == Mode::Block
      @mode = Mode::Static
      @decls.static_mode!
    end

    protected def set_frame_proc(ref : MRuby::Ref) : Nil
      @frame_proc = ref
    end

    protected def register_handle(key : Tessell::UI::UiKey) : Int32
      h = @key_handles[key]?
      return h if h
      h = @handles.create(key)
      @key_handles[key] = h
      h
    end

    def request_frame : Nil
      @needs_frame = true
      @invalidate_total += 1
    end

    def needs_frame? : Bool
      @needs_frame && !@closed
    end

    def mode : Mode
      @mode
    end

    def live_objects : Int64
      ensure_open!
      @state.live_object_count
    end

    def invalidate_total : Int64
      @invalidate_total
    end

    # ---- 声明阶段 ----

    # 跑一帧声明阶段（block 模式）。异常隔离：失败时 good 缓冲保持不动。
    # 静态模式：缓冲在 load 时已就绪，本方法只消耗 needs_frame 标记。
    def run_frame : RunResult
      ensure_open!
      if @mode == Mode::Static
        @needs_frame = false
        return RunResult.new(@decls.good_buf, nil, 0.0)
      end
      fp = @frame_proc
      unless fp && !fp.released?
        raise ScriptError.new(ScriptError::Kind::Raise,
          "no window block registered (script must call Tessell.window with a block)")
      end

      @events.release_frame_all
      @decls.begin_phase
      @in_phase = true
      err : ScriptError? = nil
      t0 = Time.monotonic
      begin
        err = invoke_protected(fp.value)
      ensure
        @in_phase = false
      end
      ms = elapsed_ms(t0)

      if e = err
        @decls.rollback
        record_error(e)
        RunResult.new(@decls.good_buf, e, ms)
      else
        buf = @decls.commit
        @script_timing.push(ms)
        @needs_frame = false
        RunResult.new(buf, nil, ms)
      end
    end

    # ---- 事件分发（T0.5）----

    # 按 UiKey 派发点击回调。异常隔离同声明阶段。预算：单帧回调数上限。
    def dispatch_click(key : Tessell::UI::UiKey) : DispatchResult
      ensure_open!
      ref = @events.find(key)
      return DispatchResult.new(false, nil, 0.0) unless ref
      t0 = Time.monotonic
      err = invoke_protected(ref.value)
      ms = elapsed_ms(t0)
      @callback_timing.push(ms)
      if e = err
        record_error(e)
        DispatchResult.new(true, e, ms)
      else
        DispatchResult.new(true, nil, ms)
      end
    end

    # ---- 热重载（G2）----

    # 重建脚本状态：释放全部 Ref → close 旧 State → 新 State → 重注册 DSL →
    # load_file。tessell 侧 Pool/节点不动：UiKey 由脚本字符串确定派生，
    # 跨重载稳定，Pool 复用节点、焦点与滚动位置不丢（R8）。
    # block 模式失败抛 ScriptError，good 缓冲保持旧画面；静态模式缓冲随
    # load 重建（失败由宿主切 fallback UI）。
    def reload(path : String) : Nil
      ensure_open!
      unless @config.allow_hot_reload
        raise InitError.new("hot reload disabled by config")
      end
      @events.release_all
      @frame_proc.try(&.release)
      @frame_proc = nil
      @protect_recv.try(&.release)
      @protect_recv = nil
      @state.close
      begin
        @state = MRuby::State.new
      rescue ex : Exception
        raise InitError.new("mruby state re-init failed: #{ex.message}")
      end
      @key_handles.clear
      @handles.clear
      @decls.reset_key_cache
      if @mode == Mode::Static
        @decls.reset_static
      end
      @mode = Mode::Unset
      @window_set = false
      Bridge.install(self)
      install_error_boundary
      load_file(path)
      @reloads += 1
    end

    # ---- 错误登记（design §8：去重限流）----

    ERROR_CAP = 8

    protected def record_error(err : ScriptError) : Nil
      @last_error = err
      # 同 file:line 连续错误去重（保留首条与计数语义由宿主 HUD 决定）。
      if @errors.size >= ERROR_CAP
        @errors.shift
      end
      @errors << err
      @on_error.try(&.call(err))
    end

    def clear_errors : Nil
      @last_error = nil
      @errors.clear
    end

    def error_count : Int32
      @errors.size
    end

    private def classify(ex : MRuby::Error) : ScriptError::Kind
      msg = ex.message || ""
      msg.starts_with?("[tessell-type]") ? ScriptError::Kind::TypeError : ScriptError::Kind::Raise
    end

    private def elapsed_ms(t0 : Time::Span) : Float64
      (Time.monotonic - t0).total_milliseconds
    end

    private def ensure_open! : Nil
      if @closed
        raise MRuby::StateClosedError.new
      end
    end
  end
end
