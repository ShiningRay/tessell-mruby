require "json"

module TessellMRuby
  # 插件发现/加载器（T2.5）。
  #
  # 决策记录（plan T2.5 要求）：**单 State 顺序 eval，而非每插件一 Runtime**——
  # 1. 多 Runtime = N 份 State/GC/good 缓冲/事件表，宿主帧循环每帧要跑 N 次
  #    声明阶段，帧预算线性膨胀，违背「不夺权」约束；
  # 2. 插件与主脚本共享 Host.* 数据与工具函数的需求在单 State 内自然成立；
  # 3. 错误隔离在声明/回调层已完备（G1 口径），可信插件前提下 State 级隔离
  #    收益不抵成本（handles/events 单属主模型也会被打破）。
  #
  # 使用约定：
  # - 宿主在 rt.load_file(主脚本) **之前**调用 rt.load_plugins(dir)；
  # - 插件是 Ruby 库（定义模块/函数、扩展 Host.*），若插件声明 Tessell.window
  #   它就接管 UI 主脚本身份（主从语义由宿主约定，加载器不禁止）；
  # - 插件 reload：rt.reload(主脚本) 换新 State 后由宿主重调 load_plugins
  #   （与重注册宿主模块同一模式）。
  #
  # 清单 plugins.json（可选）：{"plugins": [{"file": "a.rb", "name": "可选",
  #   "version": "可选"}]}；无清单 → 目录内 *.rb 按文件名字典序。
  # 逐插件错误隔离：单个插件失败（解析/运行/文件缺失）不阻断后续插件，
  # 失败详情在 PluginLoadResult#failed；清单本身损坏属于宿主配置错误 →
  # InitError（design §8：配置错误不允许静默降级）。
  struct PluginInfo
    getter file : String
    getter name : String
    getter version : String

    def initialize(@file : String, @name : String, @version : String)
    end
  end

  struct PluginFailure
    getter info : PluginInfo
    getter error : ScriptError

    def initialize(@info : PluginInfo, @error : ScriptError)
    end
  end

  struct PluginLoadResult
    getter loaded : Array(PluginInfo)
    getter failed : Array(PluginFailure)

    def initialize(@loaded : Array(PluginInfo), @failed : Array(PluginFailure))
    end

    def ok? : Bool
      @failed.empty?
    end
  end

  class Runtime
    # 发现并加载插件目录。见本文件顶部决策记录与约定。
    def load_plugins(dir : String) : PluginLoadResult
      ensure_open!
      unless Dir.exists?(dir)
        raise InitError.new("plugins dir not found: #{dir}")
      end
      entries = read_manifest(File.join(dir, "plugins.json")) || scan_dir(dir)

      loaded = [] of PluginInfo
      failed = [] of PluginFailure
      seen_files = Set(String).new
      @loading = true
      begin
        entries.each do |info|
          if loaded.size + failed.size >= @config.max_plugins
            failed << PluginFailure.new(info, ScriptError.new(ScriptError::Kind::Raise,
              "[tessell-limit] plugin count limit exceeded (#{@config.max_plugins})",
              code: ScriptError::Code::LimitExceeded))
            next
          end
          if seen_files.includes?(info.file) || info.file.empty?
            failed << PluginFailure.new(info, ScriptError.new(ScriptError::Kind::Raise,
              "[tessell-dup-key] plugin file #{info.file.inspect} is empty or listed more than once",
              code: ScriptError::Code::DuplicateKey))
            next
          end
          seen_files << info.file
          path = File.join(dir, info.file)
          unless File.exists?(path)
            failed << PluginFailure.new(info, ScriptError.new(ScriptError::Kind::Raise,
              "[tessell-state] plugin file not found: #{info.file}",
              code: ScriptError::Code::StateError))
            next
          end
          if err = load_script(path)
            failed << PluginFailure.new(info, err)
            next
          end
          loaded << info
        end
      ensure
        @loading = false
      end
      PluginLoadResult.new(loaded, failed)
    end

    # 清单读取与校验。清单不存在返回 nil（走目录扫描）；清单损坏抛 InitError。
    private def read_manifest(manifest_path : String) : Array(PluginInfo)?
      return nil unless File.exists?(manifest_path)
      parsed = begin
        JSON.parse(File.read(manifest_path))
      rescue ex : JSON::ParseException
        raise InitError.new("plugins.json is not valid JSON (#{manifest_path}): #{ex.message}")
      end
      obj = parsed.as_h?
      unless obj && obj["plugins"]?
        raise InitError.new("plugins.json must be an object with a \"plugins\" array (#{manifest_path})")
      end
      arr = obj["plugins"].as_a?
      raise InitError.new("plugins.json \"plugins\" must be an array (#{manifest_path})") unless arr

      infos = [] of PluginInfo
      arr.each do |item|
        h = item.as_h?
        file = h.try(&.[]?("file")).try(&.as_s?) || ""
        name = h.try(&.[]?("name")).try(&.as_s?) || ""
        version = h.try(&.[]?("version")).try(&.as_s?) || ""
        name = File.basename(file, ".rb") if name.empty? && !file.empty?
        infos << PluginInfo.new(file, name, version)
      end
      infos
    end

    # 无清单：目录内 *.rb 按文件名字典序。
    private def scan_dir(dir : String) : Array(PluginInfo)
      Dir.children(dir).select do |f|
        f.ends_with?(".rb") && File.file?(File.join(dir, f))
      end.sort.map do |f|
        PluginInfo.new(f, File.basename(f, ".rb"), "")
      end
    end
  end
end
