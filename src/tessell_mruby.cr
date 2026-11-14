# Tessell 的可选 mruby 脚本层。
#
# 阶段 0：只冻结入口形状与版本，Runtime / Handles / Bridge 按 docs/plan.md 的 P0 落地。
require "./tessell_mruby/version"

module TessellMRuby
  # 脚本层入口。P0 完成后替换为 Runtime.new(...)。
  #
  # 现在的签名只用于冻结 API 方向，调用即抛出 NotImplementedError。
  def self.open(script : String | Nil = nil, &)
    raise NotImplementedError.new(
      "TessellMRuby is in phase 0: no runtime implementation yet. See docs/plan.md"
    )
  end
end
