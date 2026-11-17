# Log Explorer 共享常量与无字体测量（host_app / main_builtin 共用）。
require "tessell"

module LogExplorer
  include Tessell
  include Tessell::UI

  WIDTH  = 1000
  HEIGHT = 700
  HUD_H  = 26
  ERR_H  = 26

  # 无字体依赖的确定性测量（headless / CI / G5 基线）。宽度按字符数估计，
  # 高度 = 字号 × 1.5。视觉演示模式换 FtMeasurer。
  class EstimateMeasurer < Text::Measurer
    def measure(text : String, font_id : Int32, size : Float32, max_width : Float32) : Size
      w = text.size.to_f32 * size * 0.55_f32
      w = max_width if w > max_width
      Size.new(w, size * 1.5_f32)
    end
  end
end
