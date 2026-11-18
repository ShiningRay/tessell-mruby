require "mrb"

module TessellMRuby
  # 脚本层错误（design §8）。
  #
  # 三类来源统一收敛为 ScriptError，全部携带 file:line：
  # - Raise：脚本 raise / mruby 运行时异常
  # - TypeError：脚本传参与宿主约定不符（String/Int/Bool 等）
  # - Host：宿主方法内部异常（T2.2 起宿主块异常被打上 [tessell-host] 标签
  #   重抛，此前 Kind::Host 是死代码——见 api-freeze §1 的 kind 语义）
  #
  # 稳定错误码（T2.2）：Code 是比 Kind 更细的可编程维度，宿主可按 code 决定
  # 禁用脚本 / 重试 / 展示策略。识别口径是消息机器标签（与 [tessell-type]
  # 同一约定，异常穿过 mruby 边界后仍可归一）：
  # - RuntimeError / ParseError：无标签（ParseError 另按 script_class ==
  #   SyntaxError 识别）
  # - TypeError：`[tessell-type]`（含字符串超 max_string_bytes）
  # - HostError：`[tessell-host]`（宿主方法块内 Crystal 异常）
  # - DuplicateKey：`[tessell-dup-key]`（同帧重复 key / 回调重复注册）
  # - LimitExceeded：`[tessell-limit]`（decl 上限 / 句柄表耗尽）
  # - StateError：`[tessell-state]`（形态混用、调用时机、window 重复、
  #   on_click/set_text 未知 key）
  #
  # 初始化失败（libmruby 缺失 / State 无法创建）走 InitError，启动即显式失败，
  # 不允许静默降级。
  class ScriptError < Exception
    enum Kind
      Raise
      TypeError
      Host
    end

    enum Code
      RuntimeError
      TypeError
      ParseError
      HostError
      DuplicateKey
      LimitExceeded
      StateError
    end

    getter kind : Kind
    getter code : Code
    getter script_class : String?
    getter script_file : String?
    getter script_line : Int32?
    getter raw_message : String

    def initialize(@kind : Kind, @raw_message : String,
                   @script_class : String? = nil,
                   @script_file : String? = nil,
                   @script_line : Int32? = nil,
                   @code : Code = Code::RuntimeError,
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

    # 从 mrb.cr 的 MRuby::Error 归一化。kind/code 由调用方按上下文给出
    # （声明阶段 / 回调 / 宿主方法 / 解析）。
    def self.from_mruby(ex : MRuby::Error, kind : Kind, code : Code = Code::RuntimeError) : ScriptError
      new(kind, ex.message || "unknown mruby error",
        ex.script_class, ex.script_file, ex.script_line, code)
    end

    # 机器标签 → (Kind, Code) 归一。无标签时 (Raise, RuntimeError)；
    # SyntaxError 类 → ParseError。声明阶段 / 回调 / load 三条路径共用。
    def self.classify_message(msg : String, script_class : String? = nil) : {Kind, Code}
      if script_class == "SyntaxError"
        {Kind::Raise, Code::ParseError}
      elsif msg.starts_with?("[tessell-type]")
        {Kind::TypeError, Code::TypeError}
      elsif msg.starts_with?("[tessell-host]")
        {Kind::Host, Code::HostError}
      elsif msg.starts_with?("[tessell-dup-key]")
        {Kind::Raise, Code::DuplicateKey}
      elsif msg.starts_with?("[tessell-limit]")
        {Kind::Raise, Code::LimitExceeded}
      elsif msg.starts_with?("[tessell-state]")
        {Kind::Raise, Code::StateError}
      else
        {Kind::Raise, Code::RuntimeError}
      end
    end
  end

  # 运行时无法创建（libmruby/shim 未构建、State 打开失败）。
  class InitError < Exception
  end
end
