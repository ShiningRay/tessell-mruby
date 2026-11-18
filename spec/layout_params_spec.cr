require "./spec_helper"

module TessellMRuby
  # T2.4 布局参数（gap/padding）：row/column/node 与静态 begin_* 的可选参数。
  # tessell 的 auto layout 消费 Decl.gap / Decl.padding（layout.cr:22-26），
  # 这里只断言 Decl 字段落位 + 默认值逐位一致；端到端布局由 demo 门禁覆盖。
  describe "布局参数（gap/padding）" do
    it "位置参数：gap 数字、padding 单数字或 [l,t,r,b] 数组" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.row "r1", 4.0, 8 do
            Tessell.text "a", "x"
          end
          Tessell.column "c1", 2, [1, 2, 3, 4] do
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r = rt.run_frame
        r.error.should be_nil
        row_d = r.decls.find { |d| d.kind == Tessell::UI::DeclKind::Row }.not_nil!
        row_d.gap.should eq(4.0_f32)
        row_d.padding.should eq(Tessell::Insets.new(8, 8, 8, 8))
        col_d = r.decls.find { |d| d.kind == Tessell::UI::DeclKind::Column }.not_nil!
        col_d.gap.should eq(2.0_f32)
        # [left=1, top=2, right=3, bottom=4] → Insets.new(top, right, bottom, left)
        col_d.padding.should eq(Tessell::Insets.new(2, 3, 4, 1))
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "kwargs 风格：gap:/padding: 经 Hash 落点支持" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.node "n1", gap: 3, padding: 5 do
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r = rt.run_frame
        r.error.should be_nil
        node_d = r.decls.find { |d| d.kind == Tessell::UI::DeclKind::Node }.not_nil!
        node_d.gap.should eq(3.0_f32)
        node_d.padding.should eq(Tessell::Insets.new(5, 5, 5, 5))
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "不传参时与 0.1.0 逐位一致：gap=0、padding 全 0" do
      # block 形态（两种形态不可混用，静态形态在下方单独断言）
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.row "r" do
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r = rt.run_frame
        r.error.should be_nil
        row_d = r.decls.find { |d| d.kind == Tessell::UI::DeclKind::Row }.not_nil!
        row_d.gap.should eq(0.0_f32)
        row_d.padding.should eq(Tessell::Insets.new)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
      # 静态形态
      path2 = write_script(<<-RUBY)
        Tessell.window "w", 10, 10
        Tessell.begin_column "c"
        Tessell.end_node
      RUBY
      begin
        rt2 = Runtime.new
        rt2.load_file(path2)
        r2 = rt2.run_frame
        r2.error.should be_nil
        col_d = r2.decls.find { |d| d.kind == Tessell::UI::DeclKind::Column }.not_nil!
        col_d.gap.should eq(0.0_f32)
        col_d.padding.should eq(Tessell::Insets.new)
      ensure
        rt2.try(&.close)
        cleanup(path2)
      end
    end

    it "静态 begin_* 带布局参数" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10
        Tessell.begin_row "r", 3.0, 2
          Tessell.text "t", "x"
        Tessell.end_node
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        rt.mode.should eq(Runtime::Mode::Static)
        r = rt.run_frame
        r.error.should be_nil
        row_d = r.decls.find { |d| d.kind == Tessell::UI::DeclKind::Row }.not_nil!
        row_d.gap.should eq(3.0_f32)
        row_d.padding.should eq(Tessell::Insets.new(2, 2, 2, 2))
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "类型错误：gap 非数字 → TypeError，定位到脚本调用点" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.row "r", "x" do
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        r = rt.run_frame
        e = r.error
        e.should_not be_nil
        err = e.not_nil!
        err.kind.should eq(ScriptError::Kind::TypeError)
        err.script_file.should eq(path)
        err.script_line.should eq(2)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "裸形式（bare_dsl）带布局参数可用" do
      path = write_script(<<-RUBY)
        window "w", 10, 10 do
          row "r", 4, 6 do
            text "t", "x"
          end
        end
      RUBY
      begin
        rt = Runtime.new(Config.new(bare_dsl: true))
        rt.load_file(path)
        r = rt.run_frame
        r.error.should be_nil
        row_d = r.decls.find { |d| d.kind == Tessell::UI::DeclKind::Row }.not_nil!
        row_d.gap.should eq(4.0_f32)
        row_d.padding.should eq(Tessell::Insets.new(6, 6, 6, 6))
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end

    it "key 派生不受布局参数影响（跨重载 UiKey 稳定，G2 前提）" do
      path = write_script(<<-RUBY)
        Tessell.window "w", 10, 10 do
          Tessell.row "r", 4.0 do
          end
        end
      RUBY
      begin
        rt = Runtime.new
        rt.load_file(path)
        k1 = rt.run_frame.decls.find(&.kind.==(Tessell::UI::DeclKind::Row)).not_nil!.key
        File.write(path, "Tessell.window 'w', 10, 10 do\n  Tessell.row 'r' do\n  end\nend")
        rt.reload(path)
        k2 = rt.run_frame.decls.find(&.kind.==(Tessell::UI::DeclKind::Row)).not_nil!.key
        k1.should eq(k2)
      ensure
        rt.try(&.close)
        cleanup(path)
      end
    end
  end
end
