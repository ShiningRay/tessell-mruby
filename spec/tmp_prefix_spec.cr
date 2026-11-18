# 临时验证：消除 Tessell. 前缀的两条路线（跑完即删）。
require "./spec_helper"

module TessellMRuby
  describe "prefix elimination" do
    it "route A: include Tessell + bare calls" do
      path = write_script(<<-RUBY)
        include Tessell
        window "main", 100, 100 do
          column "root" do
            text "t", "hello"
          end
        end
      RUBY
      begin
        rt = Runtime.new
        begin
          rt.load_file(path)
          r1 = rt.run_frame
          fail("unexpected run ok").inspect
        rescue ex : ScriptError
          puts "route A (include Tessell): #{ex.message}"
        ensure
          rt.close
        end
      ensure
        cleanup(path)
      end
    end

    it "route B: Object-level methods via define_method" do
      path = write_script(<<-RUBY)
        window "main", 100, 100 do
          column "root" do
            text "t", "hello"
            button "inc", "inc" do
              invalidate_all
            end
          end
        end
      RUBY
      begin
        rt = Runtime.new
        # 复用 bridge 的闭包做不到（私有），这里验证机制：
        # 把同样的名字以 Object 实例方法再注册一遍是否让裸调用可用。
        rt.state.define_method("window", 3) { |a| MRuby::Args::CallbackValue.new(nil) }
        begin
          rt.load_file(path)
          r1 = rt.run_frame
          puts "route B (Object methods): run_frame ok, decls=#{r1.decls.size}, err=#{r1.error.try(&.message).inspect}"
        rescue ex : ScriptError
          puts "route B (Object methods): load failed: #{ex.message}"
        ensure
          rt.close
        end
      ensure
        cleanup(path)
      end
    end
  end
end
