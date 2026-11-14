# 目标形态示例（当前不可运行）。
#
# 这份脚本冻结的是 P0 完成后期望的 mruby DSL 方向：
# 脚本只声明 UI 与回调，retained 树、布局、渲染全部由 Tessell(Crystal) 拥有。
# 实现进度见 docs/plan.md。

state = { count: 0 }

Tessell.window "main", 800, 600 do
  Tessell.column "root", spacing: 8 do
    Tessell.text "title", "Count: #{state[:count]}"

    Tessell.button "inc", "Increment" do
      state[:count] += 1
      Tessell.invalidate "title"
    end

    Tessell.button "reset", "Reset" do
      state[:count] = 0
      Tessell.invalidate "title"
    end
  end
end
