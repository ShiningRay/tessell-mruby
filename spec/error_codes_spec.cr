require "./spec_helper"

module TessellMRuby
  # T2.2 稳定错误码：Code 是比 Kind 更细的可编程维度，识别口径是消息机器
  # 标签（[tessell-*]），三条错误路径（load / 声明阶段 / 回调）共用归一。
  describe "错误码（ScriptError#code）" do
    it "脚本 raise → RuntimeError（声明阶段）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          raise "boom"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        e = rt.run_frame.error
        e.should_not be_nil
        e.not_nil!.code.should eq(ScriptError::Code::RuntimeError)
        e.not_nil!.kind.should eq(ScriptError::Kind::Raise)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "解析错误 → ParseError" do
      path = write_script("end\n")
      rt = Runtime.new
      begin
        expect_raises(ScriptError) { rt.load_file(path) }
      ensure
        rt.close
        cleanup(path)
      end
      # load 抛出的错误也带 code（record_error 已登记）
      rt.last_error.should_not be_nil
      rt.last_error.not_nil!.code.should eq(ScriptError::Code::ParseError)
    end

    it "类型错误 → TypeError（[tessell-type] 标签）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text "t", 123
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        e = rt.run_frame.error
        e.should_not be_nil
        e.not_nil!.code.should eq(ScriptError::Code::TypeError)
        e.not_nil!.kind.should eq(ScriptError::Kind::TypeError)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "同帧重复 key → DuplicateKey（[tessell-dup-key] 标签）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.text "t", "a"
          Tessell.text "t", "b"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        e = rt.run_frame.error
        e.should_not be_nil
        e.not_nil!.code.should eq(ScriptError::Code::DuplicateKey)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "decl 上限 → LimitExceeded（[tessell-limit] 标签）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          i = 0
          while i < 6
            Tessell.text "t\#{i}", "x"
            i += 1
          end
        end
      RUBY
      begin
        cfg = Config.new(max_decl_nodes: 5)
        rt = Runtime.new(cfg)
        rt.load_file(path)
        e = rt.run_frame.error
        e.should_not be_nil
        e.not_nil!.code.should eq(ScriptError::Code::LimitExceeded)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "形态混用 → StateError（[tessell-state] 标签）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.begin_column "c"
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        e = rt.run_frame.error
        e.should_not be_nil
        e.not_nil!.code.should eq(ScriptError::Code::StateError)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "宿主方法内 Crystal 异常 → HostError（[tessell-host] 标签；Kind::Host 落地）" do
      rt = Runtime.new
      begin
        rt.host_module("Boom")
        rt.host_method("Boom", "explode", 0) do |_args|
          raise ArgumentError.new("host data missing")
          0_i64
        end
        rt.eval("Boom.explode")
        fail "expected eval to raise"
      rescue se : ScriptError
        se.code.should eq(ScriptError::Code::HostError)
        se.kind.should eq(ScriptError::Kind::Host)
        se.raw_message.should contain("host data missing")
        se.raw_message.should contain("[tessell-host]")
      ensure
        rt.try(&.close)
      end
    end
  end
end