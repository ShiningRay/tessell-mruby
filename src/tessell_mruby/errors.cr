require "mrb"

module TessellMRuby
  # 脚本层错误（design §8）。
  #
  # 三类来源统一收敛为 ScriptError，全部携带 file:line：
  # - Raise：脚本 raise / mruby 运行时异常
  # - TypeError：脚本传参与宿主约定不符（String/Int/Bool 等）
  # - Host：宿主方法内部异常（mrb.cr 把 Crystal 异常转成 mruby RuntimeError，
  #   回到 Crystal 侧时已带脚本调用点位置）
  #
  # 初始化失败（libmruby 缺失 / State 无法创建）走 InitError，启动即显式失败，
  # 不允许静默降级。
  class ScriptError < Exception
    enum Kind
      Raise
      TypeError
      Host
    end

    getter kind : Kind
    getter script_class : String?
    getter script_file : String?
    getter script_line : Int32?
    getter raw_message : String

    def initialize(@kind : Kind, @raw_message : String,
                   @script_class : String? = nil,
                   @script_file : String? = nil,
                   @script_line : Int32? = nil,
                   cause_message : String? = nil)
      super(format_message, cause_message)
    end

    # 呈现口径：file:line: Class: message（错误条与门禁 JSON 都用它）。
    def location : String
      file = @script_file || "?"
      "#{file}:#{@script_line || 0}"
    end

    private def format_message : String
      cls = @script_class || @kind.to_s
      "#{location}: #{cls}: #{@raw_message}"
    end

    # 从 mrb.cr 的 MRuby::Error 归一化。kind 由调用方按上下文给出
    # （声明阶段 / 回调 / 宿主方法）。
    def self.from_mruby(ex : MRuby::Error, kind : Kind) : ScriptError
      new(kind, ex.message || "unknown mruby error",
        ex.script_class, ex.script_file, ex.script_line)
    end
  end

  # 运行时无法创建（libmruby/shim 未构建、State 打开失败）。
  class InitError < Exception
  end
end
