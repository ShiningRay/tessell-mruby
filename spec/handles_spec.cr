require "./spec_helper"

module TessellMRuby
  describe Handles do
    it "create → resolve 往返" do
      h = Handles.new(10)
      key = Tessell::UI::UiKey.root.child(42_u64)
      handle = h.create(key)
      handle.should be > 0
      h.resolve(handle).should eq(key)
      h.live_count.should eq(1)
    end

    it "无效句柄 resolve 返回 nil（0 / 越界 / 伪造）" do
      h = Handles.new(10)
      h.resolve(0).should be_nil
      h.resolve(12345).should be_nil
      h.resolve(-1).should be_nil
      key = Tessell::UI::UiKey.root.child(1_u64)
      handle = h.create(key)
      # 伪造：改 generation 位
      fake = (handle & 0xFFFFFF) | ((handle >> 24) + 1) << 24
      h.resolve(fake.to_i32).should be_nil
      h.resolve(handle).should eq(key)
    end

    it "release 后 resolve 失效；复用 id 时 generation 单调递增防 ABA" do
      h = Handles.new(10)
      k1 = Tessell::UI::UiKey.root.child(1_u64)
      k2 = Tessell::UI::UiKey.root.child(2_u64)
      h1 = h.create(k1)
      h.release(h1).should be_true
      h.resolve(h1).should be_nil          # released → nil
      h.release(h1).should be_false        # 幂等
      h2 = h.create(k2)                    # freelist 复用同一 id
      (h2 & 0xFFFFFF).should eq(h1 & 0xFFFFFF)
      h2.should_not eq(h1)                 # generation 变了 → 旧句柄不再等于新句柄
      h.resolve(h1).should be_nil          # 旧句柄（旧 gen）失效
      h.resolve(h2).should eq(k2)
    end

    it "容量超限抛 CapacityError；释放后可复用" do
      h = Handles.new(2)
      a = h.create(Tessell::UI::UiKey.root.child(1_u64))
      h.create(Tessell::UI::UiKey.root.child(2_u64))
      expect_raises(Handles::CapacityError) do
        h.create(Tessell::UI::UiKey.root.child(3_u64))
      end
      h.release(a)
      h.create(Tessell::UI::UiKey.root.child(3_u64)) # 不再抛
    end

    it "clear 后存活句柄全部失效" do
      h = Handles.new(10)
      k = Tessell::UI::UiKey.root.child(7_u64)
      handle = h.create(k)
      h.clear
      h.resolve(handle).should be_nil
      h.live_count.should eq(0)
      h2 = h.create(k)
      h.resolve(h2).should eq(k)
    end
  end
end
