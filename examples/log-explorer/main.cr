# Log Explorer 入口（demo.md §9）。
#
#   crystal build examples/log-explorer/main.cr -o log_explorer.exe
#
#   log_explorer.exe examples/log-explorer/ui.rb   # 交互窗口（脚本可选）
#   log_explorer.exe                               # 无脚本 → 内置 fallback UI
#   log_explorer.exe --demo-gates --json           # 无人值守 G1-G6（CI 用）
#   log_explorer.exe --frames=60                   # headless 冒烟（无窗口）
require "tessell"
require "../../src/tessell_mruby"
require "./log_data"
require "./builtin_ui"
require "./host_app"
require "./gates"
require "./win_host"

module LogExplorer
  DEFAULT_SCRIPT = File.expand_path("ui.rb", __DIR__)

  def self.main : Int32
    args = ARGV.dup

    if args.includes?("--demo-gates")
      baseline = nil
      if arg = args.find { |a| a.starts_with?("--baseline=") }
        baseline = arg.split("=", 2)[1]
      end
      return Gates.run(args.includes?("--json"), baseline)
    end

    if arg = args.find { |a| a.starts_with?("--frames") }
      n = arg.includes?("=") ? arg.split("=", 2)[1].to_i : 60
      app = HostApp.new(DEFAULT_SCRIPT, headless: true)
      n.times { app.frame }
      texts = app.last_decls.select(&.kind.==(UI::DeclKind::Text)).map(&.text)
      puts "frames=#{app.frames} decls=#{app.last_decls.size} script_p99=#{app.script_timing_p99.round(3)}ms"
      puts "first_texts=#{texts.first(4).inspect}"
      app.close
      return 0
    end

    # 交互窗口：脚本路径可传（默认仓库内 ui.rb）；--frames=N 供测试自动退出。
    script = args.find { |a| !a.starts_with?("--") } || DEFAULT_SCRIPT
    frame_limit = 0
    frame_limit = 0
    screenshot = ""
    demo_capture = false
    if arg = args.find { |a| a.starts_with?("--window") }
      frame_limit = arg.includes?("=") ? arg.split("=", 2)[1].to_i : 0
    end
    if arg = args.find { |a| a.starts_with?("--screenshot=") }
      screenshot = arg.split("=", 2)[1]
    end
    demo_capture = args.includes?("--demo-capture")
    run_window(script, frame_limit, screenshot, demo_capture)
  end
end

exit LogExplorer.main
