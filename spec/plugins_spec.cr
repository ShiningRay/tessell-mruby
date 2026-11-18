require "./spec_helper"
require "file_utils"

module TessellMRuby
  # T2.5 插件发现/加载器：单 State 顺序 eval（决策记录见 plugins.cr 顶部），
  # 清单可选，逐插件错误隔离。
  describe "插件加载器" do
    it "无清单：目录 *.rb 按文件名字典序加载，插件与主脚本共享 State" do
      dir = File.tempname("tessell_mruby_plugins", "_d")
      FileUtils.mkdir(dir)
      begin
        File.write(File.join(dir, "util.rb"), <<-RUBY)
          module P
            def self.double(x)
              x * 2
            end
          end
        RUBY
        File.write(File.join(dir, "more_util.rb"), "MORE = 7\n")

        rt = Runtime.new
        begin
          result = rt.load_plugins(dir)
          result.ok?.should be_true
          result.loaded.map(&.name).should eq(["more_util", "util"]) # 字典序
          result.loaded.map(&.version).should eq(["", ""])

          # 主脚本调用插件定义（单 State 共享命名空间的端到端证明）
          main = write_script(<<-RUBY)
            Tessell.window "w", 10, 10 do
              Tessell.text "t", "v=\#{P.double(21)}:\#{MORE}"
            end
          RUBY
          begin
            rt.load_file(main)
            r = rt.run_frame
            r.error.should be_nil
            r.decls.select(&.kind.==(Tessell::UI::DeclKind::Text))[0].text
              .should eq("v=42:7")
          ensure
            cleanup(main)
          end
        ensure
          rt.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "坏插件隔离：failed 记录 + file:line 指向插件文件，后续插件照载" do
      dir = File.tempname("tessell_mruby_plugins", "_d")
      FileUtils.mkdir(dir)
      begin
        File.write(File.join(dir, "a_good.rb"), "GOOD = 1\n")
        File.write(File.join(dir, "b_bad.rb"), "raise 'plugin boom'\n")
        File.write(File.join(dir, "c_good.rb"), "GOOD2 = 2\n")

        rt = Runtime.new
        begin
          result = rt.load_plugins(dir)
          result.ok?.should be_false
          result.loaded.size.should eq(2)
          result.failed.size.should eq(1)
          f = result.failed[0]
          f.info.name.should eq("b_bad")
          f.error.raw_message.should contain("plugin boom")
          f.error.script_file.should eq(File.join(dir, "b_bad.rb"))
          # 运行时仍可用；好插件的定义都在
          rt.live_objects.should be > 0
          good_defs = rt.eval("GOOD + GOOD2").as_i64
          good_defs.should eq(3)
        ensure
          rt.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "清单：显式顺序 + name/version 元数据" do
      dir = File.tempname("tessell_mruby_plugins", "_d")
      FileUtils.mkdir(dir)
      begin
        File.write(File.join(dir, "z.rb"), "1\n")
        File.write(File.join(dir, "a.rb"), "2\n")
        File.write(File.join(dir, "plugins.json"), <<-JSON)
          {"plugins": [
            {"file": "z.rb", "name": "zeta", "version": "1.2"},
            {"file": "a.rb"}
          ]}
        JSON

        rt = Runtime.new
        begin
          result = rt.load_plugins(dir)
          result.ok?.should be_true
          result.loaded.map(&.name).should eq(["zeta", "a"]) # 清单顺序，非字典序
          result.loaded.map(&.version).should eq(["1.2", ""])
        ensure
          rt.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "清单 JSON 损坏 → InitError（宿主配置错误不允许静默降级）" do
      dir = File.tempname("tessell_mruby_plugins", "_d")
      FileUtils.mkdir(dir)
      begin
        File.write(File.join(dir, "plugins.json"), "{not json")
        rt = Runtime.new
        begin
          expect_raises(InitError) { rt.load_plugins(dir) }
        ensure
          rt.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "清单条目文件缺失 → 该条目 failed（StateError），其余照载" do
      dir = File.tempname("tessell_mruby_plugins", "_d")
      FileUtils.mkdir(dir)
      begin
        File.write(File.join(dir, "ok.rb"), "1\n")
        File.write(File.join(dir, "plugins.json"),
          %({"plugins": [{"file": "ghost.rb"}, {"file": "ok.rb"}]}))
        rt = Runtime.new
        begin
          result = rt.load_plugins(dir)
          result.loaded.size.should eq(1)
          result.failed.size.should eq(1)
          result.failed[0].info.file.should eq("ghost.rb")
          result.failed[0].error.code.should eq(ScriptError::Code::StateError)
        ensure
          rt.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "max_plugins 截断 → LimitExceeded 失败条目" do
      dir = File.tempname("tessell_mruby_plugins", "_d")
      FileUtils.mkdir(dir)
      begin
        4.times do |i|
          File.write(File.join(dir, "p#{i}.rb"), "1\n")
        end
        rt = Runtime.new(Config.new(max_plugins: 2))
        begin
          result = rt.load_plugins(dir)
          result.loaded.size.should eq(2)
          result.failed.size.should eq(2)
          result.failed.each do |f|
            f.error.code.should eq(ScriptError::Code::LimitExceeded)
          end
        ensure
          rt.close
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
