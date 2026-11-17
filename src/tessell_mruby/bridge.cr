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
      reg.call("window", 3, ->(a : MRuby::Args) : MRuby::CallbackValue { window(a) })
      reg.call("text", 2, ->(a : MRuby::Args) : MRuby::CallbackValue { text(a) })
      reg.call("row", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { row(a) })
      reg.call("column", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { column(a) })
      reg.call("node", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { node(a) })
      reg.call("button", 2, ->(a : MRuby::Args) : MRuby::CallbackValue { button(a) })
      reg.call("begin_row", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { begin_row(a) })
      reg.call("begin_column", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { begin_column(a) })
      reg.call("begin_node", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { begin_node(a) })
      reg.call("end_node", 0, ->(a : MRuby::Args) : MRuby::CallbackValue { end_node(a) })
      reg.call("on_click", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { on_click(a) })
      reg.call("set_text", 2, ->(a : MRuby::Args) : MRuby::CallbackValue { set_text(a) })
      reg.call("invalidate", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { invalidate(a) })
      reg.call("invalidate_all", 0, ->(a : MRuby::Args) : MRuby::CallbackValue { invalidate_all(a) })
      reg.call("handle", 1, ->(a : MRuby::Args) : MRuby::CallbackValue { handle(a) })
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
        raise ArgumentError.new("Tessell.#{name} may only be called while the script is loading (top level or window block)")
      end
    end

    private def require_phase(name : String) : Nil
      if @rt.static_mode?
        raise ArgumentError.new("Tessell.#{name} cannot be nested inside the frame proc; use begin_*/end_node in static mode")
      end
      unless @rt.in_phase?
        raise ArgumentError.new("Tessell.#{name} called outside the window block (declarations are only emitted while the frame proc runs)")
      end
    end

    # ---- DSL host 方法 ----

    # Tessell.window "name", w, h { ... } —— 记录窗口元数据；带 block 时进入
    # block 模式，block 即帧过程。
    private def window(args : MRuby::Args) : MRuby::CallbackValue
      if @rt.window_title_set?
        raise ArgumentError.new("Tessell.window may only be called once per script")
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

    private def row(args : MRuby::Args) : MRuby::CallbackValue
      container(args, Tessell::UI::DeclKind::Row, Tessell::Layout::Direction::Horizontal, "row")
    end

    private def column(args : MRuby::Args) : MRuby::CallbackValue
      container(args, Tessell::UI::DeclKind::Column, Tessell::Layout::Direction::Vertical, "column")
    end

    private def node(args : MRuby::Args) : MRuby::CallbackValue
      container(args, Tessell::UI::DeclKind::Node, Tessell::Layout::Direction::Vertical, "node")
    end

    private def container(args : MRuby::Args, kind : Tessell::UI::DeclKind,
                          dir : Tessell::Layout::Direction, name : String) : MRuby::CallbackValue
      key = str_arg(args, 0)
      if @rt.static_mode?
        require_loading(name)
        raise ArgumentError.new("Tessell.#{name} without a block is not supported in static mode; use Tessell.begin_#{name}/Tessell.end_node")
      end
      require_phase(name)
      @decls.push_container(key, kind, dir)
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

    private def begin_row(args : MRuby::Args) : MRuby::CallbackValue
      begin_container(args, Tessell::UI::DeclKind::Row, Tessell::Layout::Direction::Horizontal)
    end

    private def begin_column(args : MRuby::Args) : MRuby::CallbackValue
      begin_container(args, Tessell::UI::DeclKind::Column, Tessell::Layout::Direction::Vertical)
    end

    private def begin_node(args : MRuby::Args) : MRuby::CallbackValue
      begin_container(args, Tessell::UI::DeclKind::Node, Tessell::Layout::Direction::Vertical)
    end

    private def begin_container(args : MRuby::Args, kind : Tessell::UI::DeclKind,
                                dir : Tessell::Layout::Direction) : MRuby::CallbackValue
      @rt.enter_static_mode
      key = str_arg(args, 0)
      require_loading("begin_*")
      @decls.push_container(key, kind, dir)
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
          raise ArgumentError.new("Tessell.on_click: unknown key #{key.inspect} (declare it with text/row/column/button first)")
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
        raise ArgumentError.new("Tessell.set_text: unknown key #{key.inspect} (static text must be declared with Tessell.text first)")
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
