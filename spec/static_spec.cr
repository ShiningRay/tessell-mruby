require "./spec_helper"

module TessellMRuby
  # begin/end 降级形态（T0.5）：顶层线性发射一次 + 持久 on_click + set_text。
  describe Runtime do
    it "静态模式：声明一次、回调持久、set_text 更新" do
      path = write_script(<<-RUBY)
        Tessell.window "s", 100, 100
        Tessell.begin_column "root"
        Tessell.text "label", "clicked: 0"
        Tessell.button "b", "+1"
        Tessell.end_node
        Tessell.on_click "b" do
          n = Host.get
          Tessell.set_text "label", "clicked: \#{n}"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.host_module("Host")
        count = 0_i64
        rt.host_method("Host", "get", 0) { count += 1_i64 }
        rt.load_file(path)
        rt.mode.should eq(Runtime::Mode::Static)

        r1 = rt.run_frame
        r1.error.should be_nil
        r1.decls.size.should eq(4) # column + text + button(Row) + button 标签(Text)
        texts = r1.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))
        texts[0].text.should eq("clicked: 0")

        d = rt.dispatch_click(rt.decls.derive_key("b"))
        d.error.should be_nil
        rt.needs_frame?.should be_true # set_text → request_frame

        r2 = rt.run_frame
        r2.error.should be_nil
        t2 = r2.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))
        t2[0].text.should eq("clicked: 1")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "静态模式 on_click 引用未声明 key 报脚本错误" do
      path = write_script(<<-RUBY)
        Tessell.window "s", 10, 10
        Tessell.text "t", "x"
        Tessell.on_click "ghost" do
        end
      RUBY
      begin
        rt = Runtime.new
        begin
          rt.load_file(path)
          fail "expected load_file to raise"
        rescue ex : ScriptError
          ex.raw_message.should contain("ghost")
        end
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "静态热重载失败时抛 ScriptError，运行时仍可 close" do
      path = write_script(<<-RUBY)
        Tessell.window "s", 10, 10
        Tessell.text "t", "v1"
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        rt.run_frame.error.should be_nil

        bad = write_script("Tessell.begin_row 'r'\nTessell.raise 'broken'")
        begin
          rt.reload(bad)
          fail "expected reload to raise"
        rescue ex : ScriptError
          # 重载失败本身可观察
        ensure
          cleanup(bad)
        end
        rt.close # 不崩进程即可
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "mixing block DSL 与 static DSL 报错" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text "t", "x"
        end
        Tessell.begin_row "r"
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        fail "expected load_file to raise"
      rescue ex : ScriptError
        ex.raw_message.should contain("mixes")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end
  end
end
