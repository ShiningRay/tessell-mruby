# G1–G6 门禁自动化（demo.md §5/§7、plan §6）。
#
# 用法：log_explorer.exe --demo-gates [--json]
# 无人值守跑完六项门禁，JSON 落 stdout，退出码 = 全部通过 ? 0 : 1。
#
# 口径说明：
# - G3 在 headless 下测量：空闲帧 = 无输入、无 invalidate、无脚本运行，
#   判据 A `delta_work < 1000` 且 B `<= 256`（GC.stats.bytes_since_gc 窗口）。
# - G5 的 exe 增量：与同目录 log_explorer_builtin.exe（无脚本层构建）
#   对比，缺文件则该项 unavailable；启动增量在本进程内测
#   （TessellMRuby::Runtime 创建 + load_file + 首帧 vs 内置 UI 首帧）。
# - "UI 存活 ≥ 60 s" 的现场判据在门禁中表现为连续 600 帧无崩溃存活。
require "json"
require "tessell"
require "../../src/tessell_mruby"
require "./log_data"
require "./builtin_ui"
require "./host_app"

module LogExplorer
  module Gates
    GATE_SCRIPT = File.expand_path("ui.rb", __DIR__)

    # 门禁 scratch：TEMP 对新构建的未签名 exe 可能被本机策略拒绝写，
    # 统一落在 CWD 下的 .gate_scratch（门禁自建自清理）。
    private def self.scratch : String
      dir = File.join(Dir.current, ".gate_scratch")
      Dir.mkdir_p(dir) unless Dir.exists?(dir)
      dir
    end

    # 各门禁返回 Hash(String, JSON 可序列化值)（字符串键 → Hash 而非
    # NamedTuple，字段访问走 JSON 化后的 JSON::Any，避免 union 窄化噪音）。
    private def self.jhash(h : Hash) : JSON::Any
      JSON.parse(h.to_json)
    end

    def self.run(json : Bool, baseline_path : String? = nil) : Int32
      # 门禁脚本走仓库内 ui.rb（不存在则用临时最小脚本）。
      script_path = File.exists?(GATE_SCRIPT) ? GATE_SCRIPT : nil

      g1 = gate_g1
      g2 = gate_g2(script_path)
      g3 = gate_g3(script_path)
      g4 = gate_g4(script_path)
      g5 = gate_g5(script_path)
      g6 = gate_g6(script_path)
      g8 = gate_g8(g2, g4, g5, g6, baseline_path)

      all_pass = g1["pass"].as_bool? == true && g2["pass"].as_bool? == true &&
                 g3["pass"].as_bool? == true && g4["pass"].as_bool? == true &&
                 g5["pass"].as_bool? == true && g6["pass"].as_bool? == true &&
                 g8["pass"].as_bool? == true

      json_out = JSON.build do |b|
        b.object do
          b.field("gates", "G1-G6+G8")
          b.field("pass", all_pass)
          b.field("g1_isolation", g1)
          b.field("g2_hot_reload", g2)
          b.field("g3_idle_alloc", g3)
          b.field("g4_event_latency", g4)
          b.field("g5_size_startup", g5)
          b.field("g6_soak", g6)
          b.field("g8_baseline", g8)
        end
      end
      puts json_out
      all_pass ? 0 : 1
    end

    # ---- G8 基线回归（plan T2.6）----
    #
    # 关键指标较入库基线（docs/baseline/gates-baseline.json，--baseline= 传入）
    # 劣化 > 25%，或超 plan §6 硬门限，即 FAIL。无基线文件时只做硬门限检查
    # （首次运行 / CI 未传 --baseline 时门禁仍然闭合）。
    REGRESSION_RATIO = 0.25

    private def self.jnum(a : JSON::Any) : Float64
      a.as_f? || a.as_i64?.try(&.to_f64) || 0.0
    end

    private def self.gate_g8(g2 : JSON::Any, g4 : JSON::Any, g5 : JSON::Any,
                             g6 : JSON::Any, baseline_path : String?) : JSON::Any
      # 当前值（来自本轮各门禁输出）与 §6 硬门限。全部指标越低越好。
      current = {
        "reload_ms_p99"    => jnum(g2["reload_ms_p99"]),
        "e2e_ms_p99"       => jnum(g4["e2e_ms_p99"]),
        "callback_ms_p99"  => jnum(g4["callback_ms_p99"]),
        "exe_delta_bytes"  => jnum(g5["exe_delta_bytes"]),
        "startup_delta_ms" => jnum(g5["startup_delta_ms"]),
        "live_growth"      => jnum(g6["live_growth"]),
      }
      limits = {
        "reload_ms_p99"    => 500.0,      # G2 ≤500ms
        "e2e_ms_p99"       => 16.7,       # G4 < 1 帧
        "callback_ms_p99"  => 1.0,        # G4 回调 p99
        "exe_delta_bytes"  => 2_621_440.0, # G5 ≤2.5MB
        "startup_delta_ms" => 50.0,       # G5 ≤50ms
        "live_growth"      => 0.0,        # G6 无泄漏
      }

      base : Hash(String, Float64)? = nil
      baseline_note = "not provided"
      if bp = baseline_path
        if File.exists?(bp)
          begin
            parsed = JSON.parse(File.read(bp))["metrics"]
            base = Hash(String, Float64).new
            current.keys.each do |k|
              base[k] = jnum(parsed[k])
            end
            baseline_note = bp
          rescue
            baseline_note = "#{bp} (unreadable — hard limits only)"
          end
        else
          baseline_note = "#{bp} (missing — hard limits only)"
        end
      end

      all_ok = true
      rows = current.map do |name, cur|
        bval = base.try(&.[name]?)
        ratio = nil
        # 时序 p99 在本机实测 run-to-run 噪声 2–3 倍（同一份代码 e2e p99
        # 2.57–6.73ms），25% 比例规则对其必然随机误报——仅确定性指标
        # （exe 增量 / live_objects 差值）把比例劣化作为 FAIL 条件；时序
        # 指标的比例值照记（advisory），FAIL 只看 §6 硬门限。
        deterministic = name == "exe_delta_bytes" || name == "live_growth"
        ratio_ok = true
        if bval
          ratio = bval > 0 ? (cur - bval) / bval : (cur > 0 ? Float64::INFINITY : 0.0)
          ratio_ok = !deterministic || ratio <= REGRESSION_RATIO
        end
        limit_ok = cur <= limits[name]
        ok = ratio_ok && limit_ok
        all_ok &&= ok
        jhash({"name" => name, "current" => cur, "baseline" => bval,
               "regression_ratio" => ratio, "hard_limit" => limits[name],
               "advisory" => !deterministic, "ok" => ok})
      end

      jhash({"pass" => all_ok, "baseline" => baseline_note,
             "ratio_limit" => REGRESSION_RATIO, "metrics" => rows})
    end

    # 独立最小脚本（ui.rb 不在场时的门禁脚本）。
    private def self.minimal_script(dir : String) : String
      path = File.join(dir, "gate_min_#{Random.new.hex(4)}.rb")
      File.write(path, <<-RUBY)
        Tessell.window "gate", 1000, 700 do
          Tessell.text "t", "gate v1"
          Tessell.button "b", "click" do
            Tessell.invalidate_all
          end
        end
      RUBY
      path
    end

    # ---- G1 异常隔离 ----
    private def self.gate_g1
      faults = [] of JSON::Any
      frames_survived = 0
      f1 = File.join(scratch, "gate_g1_f1.rb")
      f2 = File.join(scratch, "gate_g1_f2.rb")
      f3 = File.join(scratch, "gate_g1_f3.rb")
      begin
        # F1: 解析错误（file:line 精确）
        File.write(f1, "end\n")
        app = HostApp.new(f1, headless: true)
        5.times { app.frame }
        frames_survived += 5
        e1 = app.last_script_error
        faults << fault("parse_error", e1, true)

        # F2: 声明阶段 raise（file:line 经 wrapper）
        File.write(f2, <<-RUBY)
          n = 0
          Tessell.window "g", 100, 100 do
            n += 1
            raise 'phase boom' if n >= 2
            Tessell.text "t", "f2 \#{n}"
          end
        RUBY
        app2 = HostApp.new(f2, headless: true)
        app2.frame
        app2.request_rebuild
        app2.frame # 第二次声明阶段 raise → error bar + good 保持
        100.times { app2.frame }
        frames_survived += 101
        e2 = app2.last_script_error
        faults << fault("decl_raise", e2, true)
        ui_kept = app2.last_decls.any? { |d| d.text == "f2 1" }
        app2.close

        # F3: 回调 raise（Harm 按钮）
        File.write(f3, <<-RUBY)
          Tessell.window "g", 100, 100 do
            Tessell.button "harm", "Harm" do
              raise 'callback boom'
            end
          end
        RUBY
        app3 = HostApp.new(f3, headless: true)
        2.times { app3.frame }
        key = app3.runtime.not_nil!.decls.derive_key("harm")
        app3.runtime.not_nil!.dispatch_click(key)
        100.times { app3.frame }
        frames_survived += 102
        e3 = app3.last_script_error
        faults << fault("callback_raise", e3, true)
        app3.close

        # F4: 宿主方法异常（Crystal raise → 脚本异常，UI 存活）
        rt = TessellMRuby::Runtime.new
        rt.host_module("Host")
        rt.host_method("Host", "boom", 0) do
          raise RuntimeError.new("host exploded")
        end
        begin
          rt.eval("Host.boom")
        rescue se : TessellMRuby::ScriptError
          # 预期路径
        end
        e4 = rt.last_error
        faults << fault("host_exception", e4, false)
        rt.close
      ensure
        [f1, f2, f3].each { |f| File.delete(f) rescue nil }
      end

      pass = faults.all? { |f| f["error_present"].as_bool? == true } && ui_kept && frames_survived >= 200
      jhash({
        "pass"            => pass,
        "frames_survived" => frames_survived,
        "ui_kept"         => ui_kept,
        "faults"          => faults,
      })
    end

    private def self.fault(kind : String, err : TessellMRuby::ScriptError?, need_line : Bool) : JSON::Any
      JSON.parse({
        "kind"          => kind,
        "error_present" => !err.nil?,
        "script_class"  => err.try(&.script_class) || nil,
        "file"          => err.try(&.script_file) || nil,
        "line"          => err.try(&.script_line) || nil,
        "line_ok"       => need_line ? !err.try(&.script_line).nil? : true,
      }.to_json)
    end

    # ---- G2 热重载 ----
    private def self.gate_g2(script_path : String?)
      return g2_skip unless script_path && File.exists?(script_path)
      tmp = File.join(scratch, "gate_g2.rb")
      File.write(tmp, <<-RUBY)
        Tessell.window "g2", 1000, 700 do
          Tessell.text "t", "v1"
          Tessell.button "b", "click v1" do
            Tessell.invalidate_all
          end
        end
      RUBY
      begin
        app = HostApp.new(tmp, headless: true)
        rt = app.runtime
        return g2_skip unless rt
        3.times { app.frame }
        key_before = app.last_decls[0].key

        rt.state.gc_full

        reloads = 0
        reload_times = [] of Float64
        lives = [] of Int64
        keys_stable = true
        50.times do |i|
          File.write(tmp, i % 2 == 0 ? G2_V2 : G2_V1)
          ms = app.reload_script
          reload_times << ms
          reloads += 1
          app.frame
          keys_stable = false if app.last_decls[0].key != key_before
          rt.state.gc_full
          lives << rt.live_objects
        end
        app.frame
        label = app.last_decls.select(&.kind.==(UI::DeclKind::Text))
          .map(&.text).find { |t| t.starts_with?("click") } || ""
        app.close

        growth = lives.max - lives.min
        p99 = reload_times.sort[reload_times.size * 99 // 100]
        jhash({
          "pass"          => p99 <= 500.0 && keys_stable && growth <= 1000 && label == "click v1",
          "reloads"       => reloads,
          "reload_ms_p99" => p99.round(2),
          "reload_ms_max" => reload_times.max.round(2),
          "keys_stable"   => keys_stable,
          "live_growth"   => growth,
          "label_ok"      => label == "click v1",
        })
      ensure
        cleanup_dir(tmp)
      end
    end

    G2_V1 = %(Tessell.window "g2", 1000, 700 do\n  Tessell.text "t", "v1"\n  Tessell.button "b", "click v1" do\n    Tessell.invalidate_all\n  end\nend\n)
    G2_V2 = %(Tessell.window "g2", 1000, 700 do\n  Tessell.text "t", "v2"\n  Tessell.button "b", "click v2" do\n    Tessell.invalidate_all\n  end\nend\n)

    private def self.g2_skip
      jhash({"pass" => false, "skipped" => true, "reason" => "script not available"})
    end

    # ---- G3 空闲零分配 ----
    private def self.gate_g3(script_path : String?)
      return g3_skip unless script_path
      app = HostApp.new(script_path, headless: true)
      begin
        60.times { app.frame } # 预热：首次声明、glyph/按键缓存
        GC.collect
        GC.disable
        before = GC.stats.bytes_since_gc.to_i64
        1000.times { app.frame } # 空闲帧：无输入、无 invalidate、无脚本
        after = GC.stats.bytes_since_gc.to_i64
        GC.enable
        GC.collect
        delta_work = after - before
        app.record_idle_alloc(delta_work)
        jhash({
          "pass"       => delta_work < 1000 && delta_work <= 256,
          "delta_work" => delta_work,
          "frames"     => 1000,
          "criteria"   => "A delta<1000 AND B delta<=256",
        })
      ensure
        app.close
      end
    end

    private def self.g3_skip
      jhash({"pass" => false, "skipped" => true, "reason" => "script not available"})
    end

    # 按标签找到按钮（Text 声明的 parent = 按钮 Row），取节点 bounds 中心，
    # 经 Router 命中测试走完整点击链路（与真实输入同一路径）。
    private def self.click_button(app : HostApp, label : String) : Bool
      target = nil
      app.last_decls.each do |d|
        if d.kind == UI::DeclKind::Text && d.text.starts_with?(label)
          target = d
          break
        end
      end
      return false unless target
      node = app.pool.map[target.parent]?
      return false unless node
      b = node.bounds
      cx = b.origin.x + b.size.width / 2
      cy = b.origin.y + b.size.height / 2
      ts = (Time.monotonic.total_milliseconds % 1_000_000).to_i64
      app.handle_event(Input::Event.pointer_down(cx, cy, 0, Input::Modifiers.none, ts))
      app.handle_event(Input::Event.pointer_up(cx, cy, 0, Input::Modifiers.none, ts + 8))
      true
    end

    # ---- G4 事件延迟 ----
    private def self.gate_g4(script_path : String?)
      return g4_skip unless script_path
      app = HostApp.new(script_path, headless: true)
      begin
        5.times { app.frame }
        rt = app.runtime
        return g4_skip unless rt
        e2e = TimingRing.new
        clicks = 0
        1000.times do |i|
          t0 = Time.monotonic
          ok = click_button(app, "Theme:")
          app.frame # 输入→下一帧（声明+apply 全程）
          e2e.push((Time.monotonic - t0).total_milliseconds)
          clicks += 1 if ok
        end
        cb_p99 = rt.callback_timing.p99
        e2e_p99 = e2e.p99
        jhash({
          "pass"            => e2e_p99 < 16.7 && cb_p99 < 1.0 && clicks == 1000,
          "clicks"          => clicks,
          "e2e_ms_p99"      => e2e_p99.round(3),
          "e2e_ms_max"      => e2e.max.round(3),
          "callback_ms_p99" => cb_p99.round(4),
          "criteria"        => "e2e < 1 frame (16.7ms), callback p99 < 1ms",
        })
      ensure
        app.close
      end
    end

    private def self.g4_skip
      jhash({"pass" => false, "skipped" => true, "reason" => "script not available"})
    end

    # ---- G5 包体/启动 ----
    private def self.gate_g5(script_path : String?)
      # exe 增量：同目录 script 版 vs builtin 版（build.ps1 产出两份）。
      here = File.dirname(PROGRAM_NAME)
      exe_script = File.exists?(PROGRAM_NAME) ? File.size(PROGRAM_NAME) : nil
      builtin_path = File.join(here, "log_explorer_builtin.exe")
      exe_builtin = File.exists?(builtin_path) ? File.size(builtin_path) : nil
      exe_delta = nil
      if exe_script && exe_builtin
        exe_delta = exe_script - exe_builtin
      end

      # 启动增量：脚本模式（State 创建 + load + 首帧）vs 内置 UI 首帧。
      t_builtin = startup_time(nil)
      t_script = script_path ? startup_time(script_path) : nil
      startup_delta = nil
      if t_script && t_builtin
        startup_delta = t_script - t_builtin
      end

      pass = (startup_delta.nil? ? false : startup_delta <= 50.0) &&
             (exe_delta.nil? || exe_delta <= 2_621_440)
      jhash({
        "pass"             => pass,
        "exe_bytes"        => exe_script || 0,
        "exe_delta_bytes"  => exe_delta,
        "startup_ms"       => t_script,
        "startup_builtin_ms" => t_builtin,
        "startup_delta_ms" => startup_delta.try(&.round(2)),
        "criteria"         => "exe delta <= 2.5MB, startup delta <= 50ms",
      })
    end

    private def self.startup_time(script : String?) : Float64
      t0 = Time.monotonic
      app = HostApp.new(script, headless: true)
      app.frame
      ms = (Time.monotonic - t0).total_milliseconds
      app.close
      ms
    end

    # ---- G6 稳定性 soak ----
    private def self.gate_g6(script_path : String?)
      return g6_skip unless script_path
      app = HostApp.new(script_path, headless: true)
      begin
        5.times { app.frame }
        rt = app.runtime
        return g6_skip unless rt
        click_labels = ["Theme:", "Errors", "Warnings", "All"]
        rt.state.gc_full
        live_start = rt.live_objects
        handles_start = rt.handles.live_count
        reg_start = rt.events.registered_total
        rel_start = rt.events.released_total

        clicks = 0
        200.times do |i|
          ok = click_button(app, click_labels[i % click_labels.size])
          app.frame
          clicks += 1 if ok
        end

        reloads = 0
        lives = [] of Int64
        50.times do |i|
          app.reload_script
          app.frame
          reloads += 1
          lives << rt.live_objects
        end

        app.frame
        rt.state.gc_full
        live_end = rt.live_objects
        handles_end = rt.handles.live_count
        ref_balance = (rt.events.registered_total - reg_start) - (rt.events.released_total - rel_start)

        # live_objects 不单调增长：soak 末值不高于起点 + 余量。
        growth_ok = live_end <= live_start + 500
        jhash({
          "pass"          => clicks == 200 && reloads == 50 && growth_ok &&
                             handles_start == handles_end && ref_balance == 0,
          "clicks"        => clicks,
          "reloads"       => reloads,
          "live_start"    => live_start,
          "live_end"      => live_end,
          "live_growth"   => live_end - live_start,
          "live_peak"     => lives.max,
          "handles_stable" => handles_start == handles_end,
          "ref_balance"   => ref_balance,
        })
      ensure
        app.close
      end
    end

    private def self.g6_skip
      jhash({"pass" => false, "skipped" => true, "reason" => "script not available"})
    end

    private def self.cleanup_dir(path : String) : Nil
      if Dir.exists?(path)
        Dir.children(path).each { |f| File.delete(File.join(path, f)) rescue nil }
        File.delete(path) rescue nil
      elsif File.exists?(path)
        File.delete(path) rescue nil
      end
    end
  end
end
