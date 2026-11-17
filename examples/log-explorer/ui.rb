# Log Explorer 演示脚本（demo.md §3 冻结形状的 block 版本）。
#
# 顶层只执行一次：`state` 哈希被 window block 的闭包持有，跨帧存活；
# 声明阶段每次 invalidate 后重跑 window block。
#
# 外层 column "root" 让全部区域成为同一个 auto 布局根的子节点
# （各自独立根会被 viewport 原点分别求解，全部叠在 y=0）。
#
# state[:theme] 切换主题文字；filter 切换日志过滤；
# Harm 按钮现场注入脚本异常（G1 演示：错误条出现、UI 存活）。

state = { theme: :dark, filter: :all }

Tessell.window "log-explorer", 1000, 700 do
  Tessell.column "root" do
    Tessell.row "toolbar" do
      Tessell.text "title", "Log Explorer"
      Tessell.button "theme", "Theme: #{state[:theme]}" do
        state[:theme] = state[:theme] == :dark ? :light : :dark
        Tessell.invalidate_all
      end
      Tessell.button "f-errors", "Errors" do
        state[:filter] = :errors
        Tessell.invalidate_all
      end
      Tessell.button "f-warnings", "Warnings" do
        state[:filter] = :warnings
        Tessell.invalidate_all
      end
      Tessell.button "f-all", "All" do
        state[:filter] = :all
        Tessell.invalidate_all
      end
      Tessell.button "harm", "Harm" do
        raise "injected failure from Harm button"
      end
    end

    Tessell.row "kpi" do
      Tessell.text "rows",     "rows #{Host.count(:all)}"
      Tessell.text "errors",   "errors #{Host.count(:errors)}"
      Tessell.text "warnings", "warnings #{Host.count(:warnings)}"
    end

    Tessell.column "rows" do
      Host.each_visible(state[:filter]) do |row|
        Tessell.row("row-#{row[:id]}") do
          Tessell.text "time", row[:time]
          Tessell.text "lvl",  row[:level]
          Tessell.text "msg",  row[:msg]
        end
      end
    end

    Tessell.row "hud" do
      Tessell.text "hud-text",
        "script #{Host.script_ms_p99}ms p99 · idle alloc #{Host.idle_alloc} · " \
        "reloads #{Host.reloads} · live #{Host.live} · fps #{Host.fps}"
    end
  end
end
