require "tessell"

module TessellMRuby
  # 脚本调用 → Decl 缓冲（T0.4，design §6）。
  #
  # - 脚本给的字符串 key 在 parent 作用域内派生 UiKey（UiKey.child(FNV-1a)），
  #   跨帧稳定——这是热重载后 Pool 复用节点、焦点/滚动不丢的前提（G2/R8）。
  # - 缓冲复用：front（当帧草稿）/ good（上次成功提交）双缓冲。声明阶段异常时
  #   good 不动，UI 保持上一帧画面（G1 错误隔离）。
  # - 静态降级模式只有一份缓冲，set_text 原地改文本后整体重 apply。
  #
  # 不经 UI::Builder：Builder 的嵌套栈依赖 Crystal block，而脚本嵌套发生在
  # mruby 栈上（host 方法回调里 yield Ruby block），这里用自有栈直接写 Decl。
  class Decls
    DEFAULT_TEXT_SIZE = 14.0_f32

    getter good_buf : Array(Tessell::UI::Decl)
    getter config : Config

    @front_buf : Array(Tessell::UI::Decl)
    @stack : Array(Tessell::UI::UiKey)
    # key 缓存按 parent 作用域分桶：同字符串在不同容器下是不同身份。
    @key_cache : Hash(UInt64, Hash(String, Tessell::UI::UiKey))
    @seen : Set(Tessell::UI::UiKey)
    @static_mode : Bool
    @static_index : Hash(String, Int32)
    # 静态模式已声明 key 集合（on_click 引用校验用）。
    @declared_keys : Set(String)

    def initialize(@config : Config)
      # 预分配容量（稳态脚本帧不扩容；脚本帧不计入零分配口径，但仍避免抖动）。
      @front_buf = Array(Tessell::UI::Decl).new(256)
      @good_buf = Array(Tessell::UI::Decl).new(256)
      @stack = Array(Tessell::UI::UiKey).new(16)
      @stack << Tessell::UI::UiKey.root
      @key_cache = Hash(UInt64, Hash(String, Tessell::UI::UiKey)).new
      @seen = Set(Tessell::UI::UiKey).new
      @static_mode = false
      @static_index = Hash(String, Int32).new
      @declared_keys = Set(String).new
    end

    # ---- key 派生 ----

    # FNV-1a 64：同一脚本字符串跨帧得到同一 local（跨 UiKey 稳定）。
    private def fnv64(s : String) : UInt64
      h = 0xcbf29ce484222325_u64
      s.each_byte do |b|
        h = h ^ b
        h = h &* 0x100000001b3_u64
      end
      h
    end

    # 在当前 parent 作用域内派生 key，结果缓存（同字符串同 parent → 同 UiKey）。
    def derive_key(script_key : String) : Tessell::UI::UiKey
      scope = current_parent.id64
      bucket = @key_cache[scope]?
      unless bucket
        bucket = Hash(String, Tessell::UI::UiKey).new
        @key_cache[scope] = bucket
      end
      cached = bucket[script_key]?
      return cached if cached
      key = current_parent.child(fnv64(script_key))
      bucket[script_key] = key
      key
    end

    def current_parent : Tessell::UI::UiKey
      @stack.last
    end

    def depth : Int32
      @stack.size
    end

    # ---- 声明阶段（block 模式）----

    # 开始一帧声明：front 清空复用容量，重复 key 集清空（issue #43 语义前置到
    # 脚本层，异常以脚本错误呈现并带 file:line）。
    def begin_phase : Nil
      @front_buf.clear
      @seen.clear
      @stack.clear
      @stack << Tessell::UI::UiKey.root
    end

    # 阶段成功提交：front ↔ good 交换。返回 good（宿主 apply 用它）。
    def commit : Array(Tessell::UI::Decl)
      @front_buf, @good_buf = @good_buf, @front_buf
      @good_buf
    end

    # 阶段失败：丢弃 front，good 不动。
    def rollback : Nil
      @front_buf.clear
      @stack.clear
      @stack << Tessell::UI::UiKey.root
    end

    # ---- 发射方法（bridge 调用）----

    private def check_dup(key : Tessell::UI::UiKey, script_key : String) : Nil
      unless @seen.add?(key)
        raise ArgumentError.new("duplicate script key #{script_key.inspect} in one frame: two nodes share an identity; use a unique key per node")
      end
      if buf_for_phase.size >= @config.max_decl_nodes
        raise ArgumentError.new("decl node limit exceeded (#{@config.max_decl_nodes})")
      end
    end

    private def buf_for_phase : Array(Tessell::UI::Decl)
      @static_mode ? @good_buf : @front_buf
    end

    private def emit(key : Tessell::UI::UiKey, kind : Tessell::UI::DeclKind,
                     text : String = "", dir : Tessell::Layout::Direction = Tessell::Layout::Direction::Vertical,
                     auto : Bool = true,
                     a11y_role : Tessell::A11y::Role = Tessell::A11y::Role::Group,
                     a11y_name : String = "",
                     a11y_focusable : Bool = false) : Nil
      buf_for_phase << Tessell::UI::Decl.new(key, current_parent, kind, text,
        Tessell::Rect.new, dir, 0_u32, auto, Tessell::Insets.new, 0.0_f32,
        DEFAULT_TEXT_SIZE, a11y_role, a11y_name, "", a11y_focusable, true)
    end

    def emit_text(script_key : String, text : String) : Nil
      key = derive_key(script_key)
      check_dup(key, script_key)
      emit(key, Tessell::UI::DeclKind::Text, text)
    end

    # 容器（row/column/node）：先发射再压栈，yield 回调期间子节点以它为 parent。
    def push_container(script_key : String, kind : Tessell::UI::DeclKind,
                       dir : Tessell::Layout::Direction,
                       a11y_role : Tessell::A11y::Role = Tessell::A11y::Role::Group,
                       a11y_name : String = "",
                       a11y_focusable : Bool = false) : Tessell::UI::UiKey
      key = derive_key(script_key)
      check_dup(key, script_key)
      emit(key, kind, "", dir, true, a11y_role, a11y_name, a11y_focusable)
      @stack << key
      key
    end

    def pop_container : Nil
      @stack.pop if @stack.size > 1
    end

    # ---- 静态降级模式 ----

    def static_mode! : Nil
      @static_mode = true
    end

    def static_mode? : Bool
      @static_mode
    end

    # 静态模式下记录 script_key → buf 下标，set_text 用（同时登记声明存在）。
    def note_static_index(script_key : String, idx : Int32) : Nil
      @static_index[script_key] = idx
      @declared_keys << script_key
    end

    # 仅登记声明存在（on_click 引用校验），不进 set_text 索引。
    def note_static_declared(script_key : String) : Nil
      @declared_keys << script_key
    end

    def declared_static?(script_key : String) : Bool
      @declared_keys.includes?(script_key)
    end

    # 静态文本更新：原地替换 Decl（同 key 同身份，只改 layout-affecting 的
    # text —— apply 会判 Layout dirty）。返回是否命中。
    def set_text(script_key : String, text : String) : Bool
      idx = @static_index[script_key]?
      return false unless idx
      old = @good_buf[idx]?
      return false unless old
      @good_buf[idx] = Tessell::UI::Decl.new(old.key, old.parent, old.kind, text,
        old.bounds, old.direction, old.paint, old.auto, old.padding, old.gap,
        old.text_size, old.a11y_role, old.a11y_name, old.a11y_value,
        old.a11y_focusable, old.a11y_enabled)
      true
    end

    # 静态模式从零重建（热重载后）。
    def reset_static : Nil
      @good_buf.clear
      @seen.clear
      @stack.clear
      @stack << Tessell::UI::UiKey.root
      @static_index.clear
      @declared_keys.clear
    end

    def reset_key_cache : Nil
      @key_cache.clear
    end
  end
end
