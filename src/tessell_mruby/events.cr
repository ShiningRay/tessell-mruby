require "mrb"

module TessellMRuby
  # 回调注册表（T0.5，design §7）。
  #
  # - 两个登记簿：frame（block 模式，每次声明阶段重建，阶段开始时统一释放）
  #   与 persistent（静态降级模式，load 时注册，reload/close 才释放）。
  # - 每个 Proc 用 MRuby::Ref 持有（GC root），防回调被 GC 回收（R3）。
  # - key → Ref；dispatch 只在 UI 线程发生。
  class Events
    @frame : Hash(Tessell::UI::UiKey, MRuby::Ref)
    @persistent : Hash(Tessell::UI::UiKey, MRuby::Ref)

    # 计数（HUD / 门禁用）。
    getter registered_total : Int64
    getter released_total : Int64

    def initialize
      @frame = Hash(Tessell::UI::UiKey, MRuby::Ref).new
      @persistent = Hash(Tessell::UI::UiKey, MRuby::Ref).new
      @registered_total = 0_i64
      @released_total = 0_i64
    end

    # block 模式：声明阶段内注册（按钮 block 等）。同 key 重复注册 =
    # 脚本错误（同一节点两个回调没有合理语义）。
    def register_frame(key : Tessell::UI::UiKey, state : MRuby::State, proc_value : MRuby::Value) : Nil
      if @frame.has_key?(key)
        raise ArgumentError.new("[tessell-dup-key] callback already registered for this key in the current frame")
      end
      ref = state.ref(proc_value)
      @frame[key] = ref
      @registered_total += 1
    end

    # 静态降级模式：load 时注册，跨帧持久。
    def register_persistent(key : Tessell::UI::UiKey, state : MRuby::State, proc_value : MRuby::Value) : Nil
      if @persistent.has_key?(key)
        raise ArgumentError.new("[tessell-dup-key] persistent callback already registered for this key")
      end
      ref = state.ref(proc_value)
      @persistent[key] = ref
      @registered_total += 1
    end

    def find(key : Tessell::UI::UiKey) : MRuby::Ref?
      @frame[key]? || @persistent[key]?
    end

    # 释放当帧全部回调 Ref（block 模式每阶段开始调用）。
    def release_frame_all : Nil
      @frame.each_value do |ref|
        ref.release
        @released_total += 1
      end
      @frame.clear
    end

    # 释放全部（reload / close）。
    def release_all : Nil
      release_frame_all
      @persistent.each_value do |ref|
        ref.release
        @released_total += 1
      end
      @persistent.clear
    end

    def frame_count : Int32
      @frame.size
    end

    def persistent_count : Int32
      @persistent.size
    end
  end
end
