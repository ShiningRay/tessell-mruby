require "mrb"

module TessellMRuby
  # DSL bridge（T0.4/T0.5）：把 `Tessell.*` host 方法注册到 mruby。
  #
  # 两种脚本形态（design §6）：
  # - block 形态（主）：顶层只执行一次；`Tessell.window(...) { ... }` 的 block
  #   成为"帧过程"，声明阶段反复调用。顶层局部变量（state 哈希）被闭包持有，
  #   跨帧存活——这是 counter/log-explorer 脚本能工作的前提。
  # - begin/end 降级形态：顶层线性发射一次；`on_click` 注册持久回调；
  #   `set_text` 原地改文本。（design §6.2 写的 `Tessell.end` 在 Ruby 里是
  #   关键字，实现为 `Tessell.end_node`。）
  #
  # 类型不符 / 重复 key / 容量超限都以 mruby 异常抛回脚本（带 file:line）。
  class Bridge
    # T2.1 裸 DSL sugar：顶层委托 def（Object 私有方法），每个 DSL 名转发到
    # Tessell.* 规范形式。已实证（P1 冻结评审期探针）：委托全链路绿，脚本
    # file:line 不受影响；每次调用多一跳 mruby 派发，声明阶段 p99 < 2ms 预算
    # 下可忽略。注意：脚本顶层同名 `def` 会遮蔽委托（Ruby 后定义优先）；
    # kwargs 经 splat 转发按位置 Hash 打包，与 mruby 3.x+ 语义一致。
    BARE_DSL_PRELUDE = <<-RUBY
      def window(*args, &blk);         Tessell.window(*args, &blk); end
      def text(*args, &blk);           Tessell.text(*args, &blk); end
      def row(*args, &blk);            Tessell.row(*args, &blk); end
      def column(*args, &blk);         Tessell.column(*args, &blk); end
      def node(*args, &blk);           Tessell.node(*args, &blk); end
      def button(*args, &blk);         Tessell.button(*args, &blk); end
      def begin_row(*args, &blk);      Tessell.begin_row(*args, &blk); end
      def begin_column(*args, &blk);   Tessell.begin_column(*args, &blk); end
      def begin_node(*args, &blk);     Tessell.begin_node(*args, &blk); end
      def end_node(*args, &blk);       Tessell.end_node(*args, &blk); end
      def on_click(*args, &blk);       Tessell.on_click(*args, &blk); end
      def set_text(*args, &blk);       Tessell.set_text(*args, &blk); end
      def invalidate(*args, &blk);     Tessell.invalidate(*args, &blk); end
      def invalidate_all(*args, &blk); Tessell.invalidate_all(*args, &blk); end
      def handle(*args, &blk);         Tessell.handle(*args, &blk); end
    RUBY

    # T2.4 布局参数 glue：规范名（row/column/node/begin_*）定义为可选参数的
    # Ruby def，转发到 __ 前缀宿主方法。约定：
    # - `Tessell.row "k", 4.0, 8`（位置参数）或 `Tessell.row "k", gap: 4,
    #   padding: 8`（kwargs 经 mruby 3.x+ 的 Hash 落点进 gap 形参，此处拆开）。
    # - padding：单个数字 = 四边；或 [left, top, right, bottom] 四元素数组。
    # - gap/padding 必须非负数字，否则 [tessell-type] TypeError。
    # - 不传参时补默认值（gap 0 / padding 全 0），产出与 0.1.0 逐位一致。
    BRIDGE_GLUE = <<-RUBY
      module Tessell
        def self.__norm_layout(gap, padding)
          if gap.is_a?(Hash)
            padding = gap[:padding] unless gap[:padding].nil?
            gap = gap[:gap]
          end
          unless gap.nil? || gap.is_a?(Integer) || gap.is_a?(Float)
            raise ArgumentError, "[tessell-type] gap must be a number (Integer/Float), or use gap:/padding: keywords"
          end
          if gap.is_a?(Integer) || gap.is_a?(Float)
            raise ArgumentError, "[tessell-type] gap must be >= 0" if gap < 0
          end
          [gap.nil? ? 0 : gap, padding]
        end

        def self.__pad4(p)
          return [0, 0, 0, 0] if p.nil?
          if p.is_a?(Array)
            raise ArgumentError, "[tessell-type] padding must be 4 numbers [left, top, right, bottom]" unless p.size == 4
            i = 0
            while i < 4
              v = p[i]
              unless v.is_a?(Integer) || v.is_a?(Float)
                raise ArgumentError, "[tessell-type] padding values must be numbers (Integer/Float)"
              end
              raise ArgumentError, "[tessell-type] padding values must be >= 0" if v < 0
              i += 1
            end
            return p
          end
          unless p.is_a?(Integer) || p.is_a?(Float)
            raise ArgumentError, "[tessell-type] padding must be a number or a 4-number array [left, top, right, bottom]"
          end
          raise ArgumentError, "[tessell-type] padding values must be >= 0" if p < 0
          [p, p, p, p]
        end

        def self.row(key, gap = nil, padding = nil, &blk)
          gap, padding = __norm_layout(gap, padding)
          l, t, r, b = __pad4(padding)
          __row(key, gap, l, t, r, b, &blk)
        end

        def self.column(key, gap = nil, padding = nil, &blk)
          gap, padding = __norm_layout(gap, padding)
          l, t, r, b = __pad4(padding)
          __column(key, gap, l, t, r, b, &blk)
        end

        def self.node(key, gap = nil, padding = nil, &blk)
          gap, padding = __norm_layout(gap, padding)
          l, t, r, b = __pad4(padding)
          __node(key, gap, l, t, r, b, &blk)
        end

        def self.begin_row(key, gap = nil, padding = nil)
          gap, padding = __norm_layout(gap, padding)
          l, t, r, b = __pad4(padding)
          __begin_row(key, gap, l, t, r, b)
        end

        def self.begin_column(key, gap = nil, padding = nil)
          gap, padding = __norm_layout(gap, padding)
          l, t, r, b = __pad4(padding)
          __begin_column(key, gap, l, t, r, b)
        end

        def self.begin_node(key, gap = nil, padding = nil)
          gap, padding = __norm_layout(gap, padding)
          l, t, r, b = __pad4(padding)
          __begin_node(key, gap, l, t, r, b)
        end
      end
    RUBY

    def self.install(runtime : Runtime) : Nil
      new(runtime).install
    end

    def initialize(@rt : Runtime)
      @state = @rt.state
      @decls = @rt.decls
      @events = @rt.events
      @handles = @rt.handles
    end

    def install : Nil
      @state.define_module("Tessell")
      reg = ->(name : String, arity : Int32, blk : Proc(MRuby::Args, MRuby::CallbackValue)) {
        @state.define_module_function("Tessell", name, arity) { |args| blk.call(args) }
      }
      # T2.4：容器宿主方法带布局参数（key, gap, pad_l, pad_t, pad_r, pad_b，
      # arity 6），内部名加 __ 前缀；规范名（row/column/node/begin_*）由
      # BRIDGE_GLUE 定义为可选参数的 Ruby def 转发——shim 按 MRB_ARGS_REQ
      # 固定 arity 派发，C 层无法收可选参数，默认值在 glue 侧补齐（不传参
      # 时产出与 0.1.0 逐位一致的 Decl）。
      reg.call("window", 3, ->(a : MRuby::Args) : MRuby::CallbackValue { window(a) })
      reg.call("text", 2, ->(a : MRuby::Args) : MRuby::CallbackValue { text(a) })
      reg.call("__row", 6, ->(a : MRuby::Args) : MRuby::CallbackValue { container_layout(a, Tessell::UI::DeclKind::Row, Tessell::Layout::Direction::Horizontal, "row") })
      reg.call("__column", 6, ->(a : MRuby::Args) : MRuby::CallbackValue { container_layout(a, Tessell::UI::DeclKind::Column, Tessell::Layout::Direction::Vertical, "column") })
      reg.call("__node", 6, ->(a : MRuby::Args) : MRuby::CallbackValue { container_layout(a, Tessell::UI::DeclKind::Node, Tessell::Layout::Direction::Vertical, "node") })
      reg.call("button", 2, ->(a : MRuby::Args) : MRuby::CallbackValue { button(a) })
      reg.call("__begin_row", 6, ->(a : MRuby::Args) : MRuby::CallbackValue { begin_container_layout(a, Tessell::UI::DeclKind::Row, Tessell::Layout::Direction::Horizontal) })
      reg.call("__begin_column", 6, ->(a : MRuby::Args) : MRuby::CallbackValue { begin_container_layout(a, Tessell::UI::DeclKind::Column, Tessell::Layout::Direction::Vertical) })
      reg.call("__begin_node", 6, ->(a : MRuby::Args) : MRuby::CallbackValue { begin_container_layout(a, Tessell::UI::DeclKind::Node, Tessell::Layout::Direction::Vertical) })
      reg.call("end_node", 0, ->(a : MRuby::Args) : MRuby::CallbackValue { end_node(a) })
      reg.call("on_click", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { on_click(a) })
      reg.call("set_text", 2, ->(a : MRuby::Args) : MRuby::CallbackValue { set_text(a) })
      reg.call("invalidate", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { invalidate(a) })
      reg.call("invalidate_all", 0, ->(a : MRuby::Args) : MRuby::CallbackValue { invalidate_all(a) })
      reg.call("handle", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { handle(a) })
      @state.eval(BRIDGE_GLUE)
    end

    # ---- 参数与上下文守卫 ----

    private def type_error(i : Int32, want : String, v : MRuby::Value) : NoReturn
      raise ArgumentError.new("[tessell-type] argument #{i} must be #{want}, got #{v.type_name}")
    end

    private def str_arg(args : MRuby::Args, i : Int32) : String
      v = args[i]
      type_error(i, "String", v) unless v.string?
      s = v.as_s
      limit = @rt.config.max_string_bytes
      if s.bytesize > limit
        raise ArgumentError.new("[tessell-type] argument #{i} exceeds max_string_bytes (#{limit})")
      end
      s
    end

    private def int_arg(args : MRuby::Args, i : Int32) : Int64
      v = args[i]
      type_error(i, "Integer", v) unless v.integer?
      v.as_i64
    end

    private def require_block(args : MRuby::Args, name : String) : MRuby::Value
      unless args.block_given?
        raise ArgumentError.new("[tessell-type] Tessell.#{name} requires a block (or use the begin_*/end_node degraded form)")
      end
      args.block.not_nil!
    end

    private def require_loading(name : String) : Nil
      unless @rt.loading?
        raise ArgumentError.new("[tessell-state] Tessell.#{name} may only be called while the script is loading (top level or window block)")
      end
    end

    private def require_phase(name : String) : Nil
      if @rt.static_mode?
        raise ArgumentError.new("[tessell-state] Tessell.#{name} cannot be nested inside the frame proc; use begin_*/end_node in static mode")
      end
      unless @rt.in_phase?
        raise ArgumentError.new("[tessell-state] Tessell.#{name} called outside the window block (declarations are only emitted while the frame proc runs)")
      end
    end

    # ---- DSL host 方法 ----

    # Tessell.window "name", w, h { ... } —— 记录窗口元数据；带 block 时进入
    # block 模式，block 即帧过程。
    private def window(args : MRuby::Args) : MRuby::CallbackValue
      if @rt.window_title_set?
        raise ArgumentError.new("[tessell-state] Tessell.window may only be called once per script")
      end
      title = str_arg(args, 0)
      w = int_arg(args, 1)
      h = int_arg(args, 2)
      @rt.set_window(title, w, h)
      if args.block_given?
        @rt.enter_block_mode
        @rt.set_frame_proc(@state.ref(args.block.not_nil!))
      else
        # 无 block 的 window = 静态降级形态（begin_*/text 顶层线性发射）。
        @rt.enter_static_mode
      end
      nil
    end

    private def text(args : MRuby::Args) : MRuby::CallbackValue
      key = str_arg(args, 0)
      body = str_arg(args, 1)
      if @rt.static_mode?
        require_loading("text")
        @decls.emit_text(key, body)
        @decls.note_static_index(key, @decls.good_buf.size - 1)
      else
        require_phase("text")
        @decls.emit_text(key, body)
      end
      nil
    end

    # 数字参数（gap：Integer/Float → Float64；其余 TypeError）。
    private def num_arg(args : MRuby::Args, i : Int32) : Float64
      v = args[i]
      type_error(i, "Number (Integer/Float)", v) unless v.float? || v.integer?
      v.float? ? v.as_f64 : v.as_i64.to_f64
    end

    # glue 传参序 (key, gap, l, t, r, b) → Insets.new(top, right, bottom, left)。
    private def insets_arg(args : MRuby::Args) : Tessell::Insets
      l = int_arg(args, 2)
      t = int_arg(args, 3)
      r = int_arg(args, 4)
      b = int_arg(args, 5)
      Tessell::Insets.new(t.to_f32, r.to_f32, b.to_f32, l.to_f32)
    end

    private def container_layout(args : MRuby::Args, kind : Tessell::UI::DeclKind,
                                 dir : Tessell::Layout::Direction, name : String) : MRuby::CallbackValue
      key = str_arg(args, 0)
      gap = num_arg(args, 1)
      padding = insets_arg(args)
      if @rt.static_mode?
        require_loading(name)
        raise ArgumentError.new("[tessell-state] Tessell.#{name} without a block is not supported in static mode; use Tessell.begin_#{name}/Tessell.end_node")
      end
      require_phase(name)
      @decls.push_container(key, kind, dir, gap: gap, padding: padding)
      begin
        @state.yield(require_block(args, name))
      ensure
        @decls.pop_container
      end
      nil
    end

    # Tessell.button "key", "label" { ... } —— Row(a11y=Button) + 文本子节点 +
    # 点击回调（block 可省略 = 纯展示按钮）。
    private def button(args : MRuby::Args) : MRuby::CallbackValue
      key = str_arg(args, 0)
      label = str_arg(args, 1)
      if @rt.static_mode?
        require_loading("button")
        @decls.push_container(key, Tessell::UI::DeclKind::Row,
          Tessell::Layout::Direction::Horizontal, Tessell::A11y::Role::Button, label, true)
        @decls.emit_text("__label", label)
        @decls.pop_container
        @decls.note_static_declared(key)
        return nil
      end
      require_phase("button")
      ukey = @decls.push_container(key, Tessell::UI::DeclKind::Row,
        Tessell::Layout::Direction::Horizontal, Tessell::A11y::Role::Button, label, true)
      begin
        @decls.emit_text("__label", label)
        @rt.register_handle(ukey)
        if args.block_given?
          @events.register_frame(ukey, @state, args.block.not_nil!)
        end
      ensure
        @decls.pop_container
      end
      nil
    end

    # ---- 静态降级形态 ----

    private def begin_container_layout(args : MRuby::Args, kind : Tessell::UI::DeclKind,
                                       dir : Tessell::Layout::Direction) : MRuby::CallbackValue
      @rt.enter_static_mode
      key = str_arg(args, 0)
      gap = num_arg(args, 1)
      padding = insets_arg(args)
      require_loading("begin_*")
      @decls.push_container(key, kind, dir, gap: gap, padding: padding)
      nil
    end

    private def end_node(args : MRuby::Args) : MRuby::CallbackValue
      @decls.pop_container
      nil
    end

    # Tessell.on_click "key" { ... } —— block 模式挂到本帧已声明节点；
    # 静态模式注册持久回调。
    private def on_click(args : MRuby::Args) : MRuby::CallbackValue
      key = str_arg(args, 0)
      blk = require_block(args, "on_click")
      if @rt.static_mode?
        require_loading("on_click")
        unless @decls.declared_static?(key)
          raise ArgumentError.new("[tessell-state] Tessell.on_click: unknown key #{key.inspect} (declare it with text/row/column/button first)")
        end
        @events.register_persistent(@decls.derive_key(key), @state, blk)
      else
        require_phase("on_click")
        @events.register_frame(@decls.derive_key(key), @state, blk)
      end
      nil
    end

    # 静态模式文本更新。
    private def set_text(args : MRuby::Args) : MRuby::CallbackValue
      @rt.enter_static_mode
      key = str_arg(args, 0)
      body = str_arg(args, 1)
      unless @decls.set_text(key, body)
        raise ArgumentError.new("[tessell-state] Tessell.set_text: unknown key #{key.inspect} (static text must be declared with Tessell.text first)")
      end
      @rt.request_frame
      nil
    end

    private def invalidate(args : MRuby::Args) : MRuby::CallbackValue
      str_arg(args, 0)
      @rt.request_frame
      nil
    end

    private def invalidate_all(args : MRuby::Args) : MRuby::CallbackValue
      @rt.request_frame
      nil
    end

    private def handle(args : MRuby::Args) : MRuby::CallbackValue
      key = str_arg(args, 0)
      @rt.register_handle(@decls.derive_key(key))
    end
  end
end
