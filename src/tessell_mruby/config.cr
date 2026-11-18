module TessellMRuby
  # 脚本层运行配置。全部上限都为了"脚本出错时宿主不失控"。
  struct Config
    # 单个字符串参数上限（UTF-8 字节数）。超限即脚本异常，防止脚本侧失控分配。
    getter max_string_bytes : Int32

    # 句柄表容量（T0.3）。超过即拒绝创建并报脚本异常。
    getter max_handles : Int32

    # 单次声明阶段的 Decl 上限。超过即中止声明阶段。
    getter max_decl_nodes : Int32

    # 单帧最多执行的回调数（design §7）。超出排队到下一帧。
    getter max_callbacks_per_frame : Int32

    # 单次回调预算（毫秒）。超过只记录告警——mruby 无法安全中断。
    getter callback_budget_ms : Float64

    # 是否允许热重载（G2）。关闭后 reload 抛 InitError。
    getter allow_hot_reload : Bool

    # 裸 DSL sugar（T2.1）：开启后宿主在 load 前注入一批顶层委托 def，脚本可
    # 省略 `Tessell.` 前缀（`window "w", 10, 10 do ... end`）。默认关——
    # `Tessell.*` 规范形式始终是冻结 API；本开关只是可配置 sugar，热重载
    # （reload 换新 State）会自动重放。
    getter bare_dsl : Bool

    # 单次 load_plugins 扫描的插件数上限（T2.5）。超出部分记为 LimitExceeded
    # 失败条目，不静默截断。
    getter max_plugins : Int32

    def initialize(@max_string_bytes : Int32 = 1_048_576,
                   @max_handles : Int32 = 100_000,
                   @max_decl_nodes : Int32 = 20_000,
                   @max_callbacks_per_frame : Int32 = 64,
                   @callback_budget_ms : Float64 = 1.0,
                   @allow_hot_reload : Bool = true,
                   @bare_dsl : Bool = false,
                   @max_plugins : Int32 = 64)
    end
  end
end
