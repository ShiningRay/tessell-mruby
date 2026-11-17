require "./spec_helper"

module TessellMRuby
  # block 模式全链路：load → run_frame → dispatch → run_frame（T0.2–T0.5）。
  describe Runtime do
    it "counter 脚本：状态跨帧存活，点击回调生效" do
      path = write_script(<<-RUBY)
        state = { count: 0 }
        Tessell.window "main", 100, 100 do
          Tessell.text "t", "count: \#{state[:count]}"
          Tessell.button "inc", "inc" do
            state[:count] += 1
            Tessell.invalidate "t"
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        rt.mode.should eq(Runtime::Mode::Block)
        rt.window_title.should eq("main")
        rt.window_width.should eq(100)

        r1 = rt.run_frame
        r1.error.should be_nil
        texts = r1.decls.select { |d| d.kind == Tessell::UI::DeclKind::Text }
        texts.size.should eq(2) # "count: 0" + 按钮标签 "inc"
        texts[0].text.should eq("count: 0")
        rt.needs_frame?.should be_false

        # 点击 "inc"：同 parent 作用域派生同一 UiKey
        ukey = rt.decls.derive_key("inc")
        d = rt.dispatch_click(ukey)
        d.dispatched.should be_true
        d.error.should be_nil
        rt.needs_frame?.should be_true # invalidate 生效

        r2 = rt.run_frame
        r2.error.should be_nil
        t2 = r2.decls.select { |d| d.kind == Tessell::UI::DeclKind::Text }
        t2[0].text.should eq("count: 1")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "声明 key 跨帧稳定（Pool 复用的前提）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.row "box" do
            Tessell.text "a", "1"
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r1 = rt.run_frame
        r2 = rt.run_frame
        r1.decls.map(&.key).should eq(r2.decls.map(&.key))
        # 嵌套：row 的子 text 的 parent = row 的 key
        row_decl = r1.decls[0]
        text_decl = r1.decls[1]
        row_decl.kind.should eq(Tessell::UI::DeclKind::Row)
        text_decl.parent.should eq(row_decl.key)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "a11y：button 覆盖 role/name/focusable" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.button "go", "Go!" do
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r = rt.run_frame
        btn = r.decls[0]
        btn.a11y_role.should eq(Tessell::A11y::Role::Button)
        btn.a11y_name.should eq("Go!")
        btn.a11y_focusable.should be_true
        label = r.decls[1]
        label.kind.should eq(Tessell::UI::DeclKind::Text)
        label.text.should eq("Go!")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "宿主模块：host_module / host_method 可被脚本调用" do
      rt = Runtime.new
      begin
        rt.host_module("Host")
        rt.host_method("Host", "count", 1) do |args|
          v = args[0]
          (v.integer? ? v.as_i64 + 1_i64 : 0_i64)
        end
        rt.eval("Host.count(41)").as_i64.should eq(42)
      ensure
        rt.close
      end
    end

    it "open 入口：加载失败抛 ScriptError，成功后 close 不再可用" do
      path = write_script("raise 'nope'")
      begin
        expect_raises(ScriptError) do
          TessellMRuby.open(path) { |rt| rt.run_frame }
        end
      ensure
        cleanup(path)
      end

      path2 = write_script("Tessell.window 'w', 1, 1 do\nend")
      begin
        TessellMRuby.open(path2) do |rt|
          rt.run_frame.error.should be_nil
        end
      ensure
        cleanup(path2)
      end
    end

    it "热重载：新脚本生效、reloads 计数、无崩溃" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text "t", "v1"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        rt.run_frame.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text.should eq("v1")
        rt.reload(path) # 同文件重载（内容未变也允许）
        rt.reloads.should eq(1)
        rt.run_frame.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text.should eq("v1")

        File.write(path, "Tessell.window 'w', 10, 10 do\n  Tessell.text 't', 'v2'\nend")
        rt.reload(path)
        rt2 = rt.run_frame
        rt2.error.should be_nil
        rt2.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text.should eq("v2")
        rt.reloads.should eq(2)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "热重载后 UiKey 保持稳定（Pool 复用 / G2 的前提）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text "t", "a"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        k1 = rt.run_frame.decls[0].key
        rt.reload(path)
        k2 = rt.run_frame.decls[0].key
        k1.should eq(k2)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "live_objects 可读（G2/G6 基线）" do
      path = write_script("Tessell.window 'w', 1, 1 do\nend")
      begin
        rt = Runtime.new
        rt.load_file(path)
        rt.run_frame
        rt.live_objects.should be > 0
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end
  end
end
