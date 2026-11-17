require "./spec_helper"

module TessellMRuby
  # 错误隔离（G1）：脚本 raise / 类型错误 / 重复 key / 宿主异常 / 超长字符串
  # 都不崩进程，good 缓冲保持上一帧画面。
  describe Runtime do
    it "解析错误带精确 file:line" do
      path = write_script("end\n")
      begin
        rt = Runtime.new
        begin
          rt.load_file(path)
          fail "expected load_file to raise"
        rescue ex : ScriptError
          ex.script_file.should eq(path)
          ex.script_line.should eq(1)
          ex.raw_message.should_not be_nil
        end
        rt.last_error.should_not be_nil
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "顶层运行期 raise：file 可得（line 为已知上游缺口）" do
      path = write_script("raise 'boom'\n")
      begin
        rt = Runtime.new
        begin
          rt.load_file(path)
          fail "expected load_file to raise"
        rescue ex : ScriptError
          ex.script_file.should eq(path)
          ex.raw_message.should contain("boom")
          # 已知缺口：顶层运行期异常拿不到行号（mrb.cr 未暴露 C 层 backtrace，
          # 不 fork 上游）；声明阶段与回调路径经 __tessell_protect wrapper
          # 均有 file:line。
          ex.script_line.should be_nil
        end
        rt.last_error.should_not be_nil
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "回调 raise：dispatch 返回错误，UI 保持，进程存活" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text "t", "stable"
          Tessell.button "bad", "bad" do
            raise 'callback boom'
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        good = rt.run_frame
        good.error.should be_nil

        d = rt.dispatch_click(rt.decls.derive_key("bad"))
        d.dispatched.should be_true
        d.error.should_not be_nil
        d.error.not_nil!.raw_message.should contain("callback boom")
        d.error.not_nil!.script_file.should eq(path)
        rt.last_error.should_not be_nil

        # 下一帧照常（good 缓冲未受污染）
        r2 = rt.run_frame
        r2.error.should be_nil
        r2.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text.should eq("stable")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "类型错误：kind = TypeError，且带脚本位置" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text 123, 456
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r = rt.run_frame
        err = r.error.should_not be_nil
        err = r.error.not_nil!
        err.kind.should eq(ScriptError::Kind::TypeError)
        err.script_file.should eq(path)
        err.script_line.not_nil!.should eq(2)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "声明阶段异常：good 缓冲保持上一帧画面（G1）" do
      path = write_script(<<-RUBY)
        n = 0
        Tessell.window "w", 10, 10 do
          n += 1
          raise 'phase boom' if n >= 2
          Tessell.text "t", "frame \#{n}"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r1 = rt.run_frame
        r1.error.should be_nil
        r1.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text.should eq("frame 1")

        r2 = rt.run_frame
        r2.error.should_not be_nil
        # good 缓冲未动：宿主继续 apply 上一帧
        r2.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text.should eq("frame 1")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "同帧重复 key 是脚本错误" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text "dup", "1"
          Tessell.text "dup", "2"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r = rt.run_frame
        r.error.should_not be_nil
        r.error.not_nil!.raw_message.should contain("dup")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "超长字符串被拒绝（max_string_bytes）" do
      long = "x" * 4096
      path = write_script(%(Tessell.window "w", 1, 1 do\n  Tessell.text "t", "#{long}"\nend))
      begin
        rt = Runtime.new(Config.new(max_string_bytes: 1024))
        rt.load_file(path)
        r = rt.run_frame
        r.error.should_not be_nil
        r.error.not_nil!.kind.should eq(ScriptError::Kind::TypeError)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "块外调用 DSL 是明确脚本错误" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
        end
        Tessell.text "outside", "x"
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path) # 顶层调用发生在 load，即报错
        fail "expected load_file to raise"
      rescue ex : ScriptError
        ex.raw_message.should contain("outside the window block")
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "错误登记去重上限（ERROR_CAP=8）" do
      path = write_script(<<-RUBY)
        n = 0
        Tessell.window "w", 10, 10 do
          n += 1
          raise "e\#{n}"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        12.times { rt.run_frame }
        rt.errors.size.should be <= Runtime::ERROR_CAP
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end
  end
end
