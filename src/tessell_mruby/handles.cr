require "tessell"

module TessellMRuby
  # Int32 句柄表（T0.3，design §5）。
  #
  # Handle = (generation << 24) | id；0 保留为无效。
  # - 句柄映射到 UiKey 而非 Node 实例：Pool 复用重建节点不换句柄。
  # - freelist 复用 id；generation 单调递增防 ABA（release 保留 gen，
  #   复用时 +1，旧句柄必然失配）。
  # - resolve 对失效/越界句柄返回 nil，脚本侧收到明确异常而非踩内存。
  #
  # 句柄整数可跨线程传递，但只允许在 UI 线程解析（design §3）。
  class Handles
    # 低 24 位 id，高 8 位 generation。
    MAX_ID = (1 << 24) - 1

    private struct Entry
      property key : Tessell::UI::UiKey
      property gen : UInt8
      property used : Bool

      def initialize(@key : Tessell::UI::UiKey, @gen : UInt8, @used : Bool)
      end
    end

    @entries : Array(Entry)
    @freelist : Array(Int32)
    @next_id : Int32
    @live : Int32
    @capacity : Int32

    def initialize(capacity : Int32 = 100_000)
      raise ArgumentError.new("handles capacity must be <= #{MAX_ID}") if capacity > MAX_ID
      @capacity = capacity
      @entries = Array(Entry).new(capacity)
      @freelist = Array(Int32).new
      @next_id = 1
      @live = 0
    end

    # 创建句柄。容量超限抛 CapacityError（调用方转成脚本异常）。
    def create(key : Tessell::UI::UiKey) : Int32
      id = @freelist.pop? || begin
        fresh = @next_id
        if fresh > @capacity
          raise CapacityError.new("handle table exhausted (max #{@capacity})")
        end
        @next_id = fresh + 1
        fresh
      end
      idx = id - 1
      old_gen = idx < @entries.size ? @entries.unsafe_fetch(idx).gen : 0_u8
      # generation 单调递增；0 只出现在从未使用的槽位，非零 gen 防 ABA。
      gen = old_gen == 255_u8 ? 1_u8 : old_gen + 1_u8
      gen = 1_u8 if gen == 0_u8
      entry = Entry.new(key, gen, true)
      if idx < @entries.size
        @entries[idx] = entry
      else
        @entries << entry
      end
      @live += 1
      (gen.to_i32 << 24) | id
    end

    # 解析句柄 → UiKey。失效（released / generation 不匹配 / 越界 / 0）返回 nil。
    def resolve(handle : Int32) : Tessell::UI::UiKey?
      return nil if handle <= 0
      id = handle & MAX_ID
      gen = (handle >> 24) & 0xFF
      idx = id - 1
      return nil if idx < 0 || idx >= @entries.size
      entry = @entries.unsafe_fetch(idx)
      return nil unless entry.used
      return nil unless entry.gen == gen
      entry.key
    end

    # 释放句柄。重复释放返回 false（幂等安全）。id 回 freelist，槽内 gen 保留。
    def release(handle : Int32) : Bool
      return false if handle <= 0
      id = handle & MAX_ID
      gen = (handle >> 24) & 0xFF
      idx = id - 1
      return false if idx < 0 || idx >= @entries.size
      entry = @entries.unsafe_fetch(idx)
      return false unless entry.used
      return false unless entry.gen == gen
      @entries[idx] = Entry.new(entry.key, entry.gen, false)
      @freelist << id
      @live -= 1
      true
    end

    # 清空全部句柄（热重载 / close）。存活槽位 gen 递增，旧句柄全部失效。
    def clear : Nil
      @entries.each_with_index do |entry, idx|
        if entry.used
          gen = entry.gen == 255_u8 ? 1_u8 : entry.gen + 1_u8
          gen = 1_u8 if gen == 0_u8
          @entries[idx] = Entry.new(entry.key, gen, false)
        end
      end
      @freelist.clear
      @live = 0
    end

    def live_count : Int32
      @live
    end

    def capacity : Int32
      @capacity
    end

    class CapacityError < Exception
    end
  end
end
