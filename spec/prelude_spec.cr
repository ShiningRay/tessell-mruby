require "./spec_helper"

module TessellMRuby
  # T2.1 裸 DSL sugar（prelude 委托）：bare_dsl: true 时脚本可省略 Tessell.
  # 前缀。默认关——规范形式始终可用（本文件每个用例旁都有对应规范路径覆盖）。
  describe "prelude（bare_dsl）" do
    it "裸脚本全链路：load → run_frame → 点击 → 重声明，闭包状态跨帧" do
      path = write_script(<<-RUBY)
        state = { count: 0 }
        window "main", 100, 100 do
          column "root" do
            text "t", "count: \#{state[:count]}"
            button "inc", "inc" do
              state[:count] += 1
              invalidate_all
            end
          end
        end
      RUBY
      begin
        cfg = Config.new(bare_dsl: true)
        rt = Runtime.new(cfg)
        rt.load_file(path)
        rt.mode.should eq(Runtime::Mode::Block)
        rt.window_title.should eq("main")

        r1 = rt.run_frame
        r1.error.should be_nil
        texts = r1.decls.select { |d| d.kind == Tessell::UI::DeclKind::Text }
        texts.size.should eq(2)
        texts[0].text.should eq("count: 0")

        # 嵌套在 column "root" 里的按钮真实 key 按 column 作用域派生——
        # 从根作用域 derive_key 取不到（探针踩坑），从 decls 里取真实 key。
        btn = r1.decls.find { |d| d.a11y_role == Tessell::A11y::Role::Button }
        btn.should_not be_nil
        d = rt.dispatch_click(btn.not_nil!.key)

        r2 = rt.run_frame
        r2.error.should be_nil
        r2.decls.select { |d| d.kind == Tessell::UI::DeclKind::Text }[0].text
          .should eq("count: 1")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "错误位置：裸脚本 raise 定位到脚本帧（DSL 调用点行，跳过 (eval) 帧夹层）" do
      path = write_script(<<-RUBY)
        window "w", 10, 10 do
          column "root" do
            text "t", "x"
            raise "boom in frame"
          end
        end
      RUBY
      begin
        rt = Runtime.new(Config.new(bare_dsl: true))
        rt.load_file(path)
        r = rt.run_frame
        e = r.error
        e.should_not be_nil
        err = e.not_nil!
        # mruby 把经委托调用的块归到 wrapper "(eval)" 帧，脚本能提供的最准
        # 位置是出错块的 DSL 调用点行（此处 column 在第 2 行）；PROTECT_GLUE
        # 跳过 (eval) 帧取第一个脚本帧。规范形式下定位到 raise 行（见 errors_spec）。
        err.script_file.should eq(path)
        err.script_line.should eq(2)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "错误位置：裸脚本的类型错误仍归类 TypeError" do
      path = write_script(<<-RUBY)
        window "w", 10, 10 do
          text "t", 123
        end
      RUBY
      begin
        rt = Runtime.new(Config.new(bare_dsl: true))
        rt.load_file(path)
        r = rt.run_frame
        e = r.error
        e.should_not be_nil
        err = e.not_nil!
        err.kind.should eq(ScriptError::Kind::TypeError)
        err.script_file.should eq(path)
        err.script_line.should eq(2) # text "t", 123 的调用点
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "热重载重放 prelude：reload 后裸 DSL 仍可用" do
      path = write_script(<<-RUBY)
        state = { n: 1 }
        window "w", 10, 10 do
          text "t", "n=\#{state[:n]}"
        end
      RUBY
      begin
        rt = Runtime.new(Config.new(bare_dsl: true))
        rt.load_file(path)
        rt.run_frame.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text
          .should eq("n=1")
        rt.reload(path) # 新 State：prelude 必须重放，否则裸调用 NoMethodError
        rt.reloads.should eq(1)
        r = rt.run_frame
        r.error.should be_nil
        r.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text
          .should eq("n=1")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "静态降级形态的裸调用可用" do
      path = write_script(<<-RUBY)
        window "w", 10, 10
        begin_column "root"
          text "t", "static"
        end_node
        on_click "t" do
          set_text "t", "clicked"
        end
      RUBY
      begin
        rt = Runtime.new(Config.new(bare_dsl: true))
        rt.load_file(path)
        rt.mode.should eq(Runtime::Mode::Static)
        r = rt.run_frame
        r.error.should be_nil
        r.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text
          .should eq("static")
        d = rt.dispatch_click(rt.decls.derive_key("t"))
        d.dispatched.should be_true
        d.error.should be_nil
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "默认关：不开启 bare_dsl 时裸调用是 NoMethodError（规范形式不受影响）" do
      path = write_script("window 'w', 1, 1 do\nend")
      begin
        rt = Runtime.new
        expect_raises(ScriptError) do
          rt.load_file(path)
        end
        # 规范形式同 runtime 照常工作
        path2 = write_script("Tessell.window 'w', 1, 1 do\nend")
        rt2 = Runtime.new
        begin
          rt2.load_file(path2)
          rt2.run_frame.error.should be_nil
        ensure
          rt2.close
          cleanup(path2)
        end
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end
  end
end
