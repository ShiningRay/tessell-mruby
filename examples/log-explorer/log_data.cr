# Log Explorer 数据源：确定性日志集 + 后台快照投递（demo.md §4）。
#
# - 脚本侧只拿到 JSON-like 标量（host 方法出参），不暴露 Node/UiKey/指针。
# - 虚拟化的关键：1 万行常驻内存，但 Host 只暴露当前视口窗口（~30 行），
#   脚本每帧只遍历可见行（demo.md §11 风险表第 2 行的缓解）。
# - 三个过滤视图启动时预计算一次；每帧零分配（除脚本帧外不计入口径）。
# - 快照由后台线程周期性生成、Channel 投递（design §3 跨线程约定）：
#   UI 线程每帧 try_receive，空通道零分配。
require "tessell"

module LogExplorer
  struct LogRow
    getter id : Int32
    getter time : String
    getter level : String
    getter message : String

    def initialize(@id : Int32, @time : String, @level : String, @message : String)
    end
  end

  class LogStore
    ROWS       = 10_000
    ROW_STEP_PX = 20

    @all : Array(LogRow)
    @errors : Array(LogRow)
    @warnings : Array(LogRow)
    @scroll_y : Int32 = 0
    @filter : String = "all"
    @viewport_h : Int32
    @snapshot_ch : Channel(Nil)
    @snapshot_count : Int64 = 0

    getter scroll_y

    def initialize(viewport_h : Int32 = 520)
      @viewport_h = viewport_h
      @all = build_rows
      @errors = @all.select(&.level.==("ERROR"))
      @warnings = @all.select(&.level.==("WARN"))
      @snapshot_ch = Channel(Nil).new(1)
      start_generator
    end

    # 确定性数据（演示可复现；门禁 JSON 与现场一致的前提）。
    private def build_rows : Array(LogRow)
      rows = Array(LogRow).new(ROWS)
      msgs = [
        "upstream timeout", "retry 2/3", "reconnect ok",
        "cache miss ratio 12.4%", "flush wal segment 0017",
        "shard rebalance done", "slow query 812ms",
        "gc pause 14ms", "pool resize 64->96",
      ]
      i = 0
      while i < ROWS
        level = case
                when (i * 7 + (i >> 5)) % 19 < 3 then "ERROR"
                when (i * 13) % 11 < 3          then "WARN"
                else                                 "INFO"
                end
        sec = (i // 3) % 60
        min = (i // 180) % 60
        hour = (i // 10800) % 4
        rows << LogRow.new(i, "%02d:%02d:%02d" % {8 + hour, min, sec},
          level, msgs[(i * 5) % msgs.size])
        i += 1
      end
      rows
    end

    # 后台线程：每 250ms 投递一次快照就绪信号（容量 1，满则丢弃）。
    private def start_generator : Nil
      ch = @snapshot_ch
      # 默认并行 context：Isolated 线程上 spawn/sleep 不会得到调度。
      Fiber::ExecutionContext.default.spawn(name: "log-snapshot") do
        loop do
          sleep 250.milliseconds
          select
          when ch.send(nil)
          when timeout(50.milliseconds)
            # 满则丢弃（UI 线程频率低）
          end
        end
      end
    end

    # UI 线程只在重建帧调用（空闲帧零分配口径不受影响）：drain 语义。
    def pump : Nil
      loop do
        got = false
        select
        when @snapshot_ch.receive?
          got = true
        when timeout(0.seconds)
          got = false
        end
        break unless got
        @snapshot_count += 1
      end
    end

    def snapshot_count : Int64
      @snapshot_count
    end

    def set_filter(filter : String) : Nil
      @filter = filter
      clamp_scroll
    end

    def filter : String
      @filter
    end

    def scroll_by(dy : Int32) : Nil
      @scroll_y += dy
      clamp_scroll
    end

    def scroll_to(y : Int32) : Nil
      @scroll_y = y
      clamp_scroll
    end

    private def clamp_scroll : Nil
      max = max_scroll
      @scroll_y = 0 if @scroll_y < 0
      @scroll_y = max if @scroll_y > max
    end

    def max_scroll : Int32
      m = filtered_rows(@filter).size * ROW_STEP_PX - @viewport_h
      m > 0 ? m : 0
    end

    private def filtered_rows(filter : String) : Array(LogRow)
      case filter
      when "errors"   then @errors
      when "warnings" then @warnings
      else                 @all
      end
    end

    def counts(filter : String) : Int32
      filtered_rows(filter).size
    end

    # 视口窗口起点（行索引）。
    private def window_start : Int32
      (@scroll_y / ROW_STEP_PX).to_i32
    end

    # 视口窗口内行数（虚拟化：脚本只看到这一段）。
    def visible_count : Int32
      rows = filtered_rows(@filter)
      first = window_start
      last = first + (@viewport_h / ROW_STEP_PX).to_i32 + 1
      last = rows.size - 1 if last >= rows.size
      last >= first ? last - first + 1 : 0
    end

    # 可见窗口第 i 行（0 基）。
    def row_at(i : Int32) : LogRow?
      rows = filtered_rows(@filter)
      idx = window_start + i
      rows[idx]?
    end

    def snapshot_rows(filter : String, limit : Int32) : Array(LogRow)
      filtered_rows(filter).first(limit)
    end
  end
end
