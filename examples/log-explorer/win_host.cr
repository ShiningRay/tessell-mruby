# 交互窗口模式：Win32 + WGL + GLBackend（纯 FFI，模式照搬 tessell
# examples/app_demo.cr 的已验证宿主样板）。
#
# - 帧循环跑在 Isolated 执行上下文（Tessell 线程契约，design §3）。
# - 渲染走 decl 树：每个 Text 节点按 pool 后的 bounds 提交（文本渲染，
#   容器不画底色——P0 渲染层不暴露 rect 声明，见 demo.md §8）。
# - 热重载：watcher 线程 250ms 轮询 ui.rb mtime，命中经 Channel 通知
#   UI 线程 reload（空闲帧零 stat，G3 口径不受影响）。
# - F2 切换 Script: on/off（demo.md 场景 3），Esc 退出。
require "tessell"
require "../../src/tessell_mruby"
require "./log_data"
require "./builtin_ui"
require "./host_app"
require "tessell/render/gl/gl_backend"

module LogExplorer
  DEBUG_RENDER = ENV["LEX_DEBUG"]? == "1"

  @[Link("kernel32")]
  lib LexKernel32
    fun GetModuleHandleW(lpModuleName : UInt16*) : Void*
    fun GetLastError : UInt32
  end

  @[Link("user32")]
  lib LexUser32
    struct WNDCLASSEXW
      cbSize : UInt32
      style : UInt32
      lpfnWndProc : (Void*, UInt32, UInt64, Int64 -> Int64)
      cbClsExtra : Int32
      cbWndExtra : Int32
      hInstance : Void*
      hIcon : Void*
      hCursor : Void*
      hbrBackground : Void*
      lpszMenuName : UInt16*
      lpszClassName : UInt16*
      hIconSm : Void*
    end

    struct POINT
      x : Int32
      y : Int32
    end

    struct MSG
      hwnd : Void*
      message : UInt32
      wParam : UInt64
      lParam : Int64
      time : UInt32
      pt : POINT
    end

    struct RECT
      left : Int32
      top : Int32
      right : Int32
      bottom : Int32
    end

    fun RegisterClassExW(lpWndClass : WNDCLASSEXW*) : UInt16
    fun CreateWindowExW(dwExStyle : UInt32, lpClassName : UInt16*, lpWindowName : UInt16*,
                        dwStyle : UInt32, x : Int32, y : Int32, nWidth : Int32, nHeight : Int32,
                        hWndParent : Void*, hMenu : Void*, hInstance : Void*, lpParam : Void*) : Void*
    fun ShowWindow(hWnd : Void*, nCmdShow : Int32) : Int32
    fun UpdateWindow(hWnd : Void*) : Int32
    fun DestroyWindow(hWnd : Void*) : Int32
    fun PostQuitMessage(nExitCode : Int32) : Void
    fun DefWindowProcW(hWnd : Void*, msg : UInt32, wParam : UInt64, lParam : Int64) : Int64
    fun PeekMessageW(lpMsg : MSG*, hWnd : Void*, wMsgFilterMin : UInt32, wMsgFilterMax : UInt32, wRemoveMsg : UInt32) : Int32
    fun TranslateMessage(lpMsg : MSG*) : Int32
    fun DispatchMessageW(lpMsg : MSG*) : Int64
    fun GetDC(hWnd : Void*) : Void*
    fun ReleaseDC(hWnd : Void*, hDC : Void*) : Int32
    fun LoadCursorW(hInstance : Void*, lpCursorName : UInt16*) : Void*
    fun AdjustWindowRectEx(lpRect : RECT*, dwStyle : UInt32, bMenu : Int32, dwExStyle : UInt32) : Int32
  end

  @[Link("gdi32")]
  lib LexGdi32
    struct PIXELFORMATDESCRIPTOR
      nSize : UInt16
      nVersion : UInt16
      dwFlags : UInt32
      iPixelType : UInt8
      cColorBits : UInt8
      cRedBits : UInt8
      cRedShift : UInt8
      cGreenBits : UInt8
      cGreenShift : UInt8
      cBlueBits : UInt8
      cBlueShift : UInt8
      cAlphaBits : UInt8
      cAccumBits : UInt8
      cAccumRedBits : UInt8
      cAccumGreenBits : UInt8
      cAccumBlueBits : UInt8
      cAccumAlphaBits : UInt8
      cDepthBits : UInt8
      cStencilBits : UInt8
      cAuxBuffers : UInt8
      iLayerType : UInt8
      bReserved : UInt8
      dwLayerMask : UInt32
      dwVisibleMask : UInt32
      dwDamageMask : UInt32
    end

    fun ChoosePixelFormat(hdc : Void*, ppfd : PIXELFORMATDESCRIPTOR*) : Int32
    fun SetPixelFormat(hdc : Void*, format : Int32, ppfd : PIXELFORMATDESCRIPTOR*) : Int32
    fun SwapBuffers(hdc : Void*) : Int32
  end

  @[Link("opengl32")]
  lib LexGLCap
    GL_RGBA           = 0x1908_u32
    GL_UNSIGNED_BYTE  = 0x1401_u32
    GL_PACK_ALIGNMENT = 0x0D05_u32
    fun glFinish : Void
    fun glPixelStorei(pname : UInt32, param : Int32) : Void
    fun glReadPixels(x : Int32, y : Int32, width : Int32, height : Int32,
                     format : UInt32, type : UInt32, pixels : Void*) : Void
  end

  @[Link("opengl32")]
  lib LexWGL
    fun wglCreateContext(hdc : Void*) : Void*
    fun wglMakeCurrent(hdc : Void*, hglrc : Void*) : Int32
    fun wglDeleteContext(hglrc : Void*) : Int32
  end

  module LexState
    class_property quit_requested : Bool = false
    class_property wheel_delta : Int32 = 0
    class_property key_code : UInt32 = 0
    class_property mouse_x : Int32 = 0
    class_property mouse_y : Int32 = 0
    class_property mouse_moved : Bool = false
    class_property mouse_down_x : Int32 = -1
    class_property mouse_down_y : Int32 = -1
    class_property mouse_up_x : Int32 = -1
    class_property mouse_up_y : Int32 = -1
  end

  WS_OVERLAPPEDWINDOW = 0x00CF0000_u32
  WS_VISIBLE          = 0x10000000_u32
  CW_USEDEFAULT       = 0x80000000_u32.to_i32!
  SW_SHOW             = 5
  PM_REMOVE           = 0x0001_u32
  WM_CLOSE            = 0x0010_u32
  WM_DESTROY          = 0x0002_u32
  WM_QUIT             = 0x0012_u32
  WM_KEYDOWN          = 0x0100_u32
  WM_MOUSEMOVE        = 0x0200_u32
  WM_LBUTTONDOWN      = 0x0201_u32
  WM_LBUTTONUP        = 0x0202_u32
  WM_MOUSEWHEEL       = 0x020A_u32
  VK_ESCAPE           = 0x1B_u64
  VK_F2               = 0x71_u64
  IDC_ARROW           = Pointer(UInt16).new(32512_u64)
  CS_OWNDC            = 0x0020_u32

  PFD_DRAW_TO_WINDOW = 0x00000004_u32
  PFD_SUPPORT_OPENGL = 0x00000020_u32
  PFD_DOUBLEBUFFER   = 0x00000001_u32
  PFD_TYPE_RGBA      = 0_u8
  PFD_MAIN_PLANE     = 0_u8

  LEX_WNDPROC = ->(hwnd : Void*, msg : UInt32, wparam : UInt64, lparam : Int64) : Int64 do
    case msg
    when WM_CLOSE
      LexUser32.DestroyWindow(hwnd)
      return 0_i64
    when WM_DESTROY
      LexUser32.PostQuitMessage(0)
      LexState.quit_requested = true
      return 0_i64
    when WM_KEYDOWN
      if wparam == VK_ESCAPE
        LexUser32.DestroyWindow(hwnd)
        return 0_i64
      end
      LexState.key_code = (wparam & 0xFFFF_u64).to_u32
    when WM_MOUSEMOVE
      x = (lparam & 0xFFFF_u64).to_i32
      x -= 65536 if x > 32767
      y = ((lparam >> 16) & 0xFFFF_u64).to_i32
      y -= 65536 if y > 32767
      LexState.mouse_x = x
      LexState.mouse_y = y
      LexState.mouse_moved = true
    when WM_LBUTTONDOWN
      LexState.mouse_down_x = (lparam & 0xFFFF_u64).to_i32
      LexState.mouse_down_x -= 65536 if LexState.mouse_down_x > 32767
      LexState.mouse_down_y = ((lparam >> 16) & 0xFFFF_u64).to_i32
      LexState.mouse_down_y -= 65536 if LexState.mouse_down_y > 32767
    when WM_LBUTTONUP
      LexState.mouse_up_x = (lparam & 0xFFFF_u64).to_i32
      LexState.mouse_up_x -= 65536 if LexState.mouse_up_x > 32767
      LexState.mouse_up_y = ((lparam >> 16) & 0xFFFF_u64).to_i32
      LexState.mouse_up_y -= 65536 if LexState.mouse_up_y > 32767
    when WM_MOUSEWHEEL
      d = ((wparam >> 16) & 0xFFFF_u64).to_i32
      d -= 65536 if d > 32767
      LexState.wheel_delta = d
    end
    LexUser32.DefWindowProcW(hwnd, msg, wparam, lparam)
  end

  private def self.to_wstr(s : String) : Slice(UInt16)
    u = s.to_utf16
    buf = Slice(UInt16).new(u.size + 1, 0_u16)
    u.size.times { |i| buf[i] = u[i] }
    buf
  end

  private def self.fail(msg : String) : NoReturn
    err = LexKernel32.GetLastError
    STDERR.puts "error=#{msg} win32_error=#{err}"
    exit 1
  end

  def self.run_window(script : String, frame_limit : Int32 = 0, screenshot : String = "", demo_capture : Bool = false) : Int32
    result_ch = Channel(Int32).new

    iso_ctx = Fiber::ExecutionContext::Isolated.new("tessell-log-explorer") do
      begin
        hinstance = LexKernel32.GetModuleHandleW(Pointer(UInt16).null)
        fail("GetModuleHandleW") if hinstance.null?

        class_name = to_wstr("TessellLogExplorer")
        window_title = to_wstr("Tessell Log Explorer (mruby)")

        wc = LexUser32::WNDCLASSEXW.new
        wc.cbSize = sizeof(LexUser32::WNDCLASSEXW).to_u32
        wc.style = CS_OWNDC
        wc.lpfnWndProc = LEX_WNDPROC
        wc.hInstance = hinstance
        wc.hCursor = LexUser32.LoadCursorW(Pointer(Void).null, IDC_ARROW)
        wc.lpszClassName = class_name.to_unsafe
        atom = LexUser32.RegisterClassExW(pointerof(wc))
        fail("RegisterClassExW") if atom == 0

        rect = LexUser32::RECT.new
        rect.left = 0
        rect.top = 0
        rect.right = WIDTH
        rect.bottom = HEIGHT
        style = WS_OVERLAPPEDWINDOW
        LexUser32.AdjustWindowRectEx(pointerof(rect), style, 0, 0)
        win_w = rect.right - rect.left
        win_h = rect.bottom - rect.top

        hwnd = LexUser32.CreateWindowExW(0_u32, class_name.to_unsafe, window_title.to_unsafe,
          style | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT, win_w, win_h,
          Pointer(Void).null, Pointer(Void).null, hinstance, Pointer(Void).null)
        fail("CreateWindowExW") if hwnd.null?
        LexUser32.ShowWindow(hwnd, SW_SHOW)
        LexUser32.UpdateWindow(hwnd)

        hdc = LexUser32.GetDC(hwnd)
        fail("GetDC") if hdc.null?

        pfd = LexGdi32::PIXELFORMATDESCRIPTOR.new
        pfd.nSize = sizeof(LexGdi32::PIXELFORMATDESCRIPTOR).to_u16
        pfd.nVersion = 1_u16
        pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER
        pfd.iPixelType = PFD_TYPE_RGBA
        pfd.cColorBits = 32_u8
        pfd.cDepthBits = 24_u8
        pfd.cStencilBits = 8_u8
        pfd.iLayerType = PFD_MAIN_PLANE
        pf = LexGdi32.ChoosePixelFormat(hdc, pointerof(pfd))
        fail("ChoosePixelFormat") if pf == 0
        fail("SetPixelFormat") if LexGdi32.SetPixelFormat(hdc, pf, pointerof(pfd)) == 0

        hglrc = LexWGL.wglCreateContext(hdc)
        fail("wglCreateContext") if hglrc.null?
        fail("wglMakeCurrent") if LexWGL.wglMakeCurrent(hdc, hglrc) == 0

        code = window_loop(script, hdc, frame_limit, screenshot, demo_capture)
        STDERR.puts code unless code.empty?

        LexWGL.wglMakeCurrent(Pointer(Void).null, Pointer(Void).null)
        LexWGL.wglDeleteContext(hglrc)
        LexUser32.ReleaseDC(hwnd, hdc)
        LexUser32.DestroyWindow(hwnd) unless LexState.quit_requested
        result_ch.send(0)
      rescue ex
        bt = ex.backtrace?
        bt_s = bt ? bt.first(5).join(" | ") : ""
        STDERR.puts "error=exception message=#{ex.message.inspect} backtrace=#{bt_s.inspect}"
        result_ch.send(1)
      end
    end

    result_ch.receive
  end

  # 按标签找按钮（Text 声明的 parent = 按钮容器），经 Router 命中注入点击。
  private def self.click_button(app : HostApp, label : String) : Nil
    target = nil
    app.last_decls.each do |d|
      if d.kind == UI::DeclKind::Text && d.text.starts_with?(label)
        target = d
        break
      end
    end
    return unless target
    node = app.pool.map[target.parent]?
    return unless node
    b = node.bounds
    cx = b.origin.x + b.size.width / 2
    cy = b.origin.y + b.size.height / 2
    ts = (Time.monotonic.total_milliseconds % 1_000_000).to_i64
    app.handle_event(Input::Event.pointer_down(cx, cy, 0, Input::Modifiers.none, ts))
    app.handle_event(Input::Event.pointer_up(cx, cy, 0, Input::Modifiers.none, ts + 8))
  end

  private def self.window_loop(script : String, hdc : Void*, frame_limit : Int32, screenshot : String, demo_capture : Bool) : String
    return "ft_unavailable: #{Text::FtMeasurer.unavailable_reason}" unless Text::FtMeasurer.available?

    STDERR.puts "lex: ft available" if DEBUG_RENDER
    measurer = Text::FtMeasurer.open("C:/Windows/Fonts/msyh.ttc", 0)
    STDERR.puts "lex: ft opened" if DEBUG_RENDER
    atlas = Text::GlyphAtlas.new(1024, 4096)
    rasterizer = Text::Rasterizer.new(measurer, atlas, 0, 8192)
    renderer = Render::TextRenderer.new(atlas, rasterizer)
    backend = Render::GL::GLBackend.new
    backend.init(WIDTH, HEIGHT)
    backend.resize(WIDTH, HEIGHT)
    renderer.reserve_quads(4096)
    renderer.reserve_batches(128)
    placement = [] of Text::GlyphPlacement
    theme = Render::Theme.dark

    STDERR.puts "lex: gl ready" if DEBUG_RENDER
    app = HostApp.new(script, headless: false, measurer: measurer)
    STDERR.puts "lex: app ready" if DEBUG_RENDER

    # 热重载 watcher（后台线程只 stat 文件，UI 线程收到信号才 reload）。
    reload_ch = Channel(Nil).new(1)
    Fiber::ExecutionContext.default.spawn(name: "reload-watcher") do
      last_mtime = File.info?(script).try(&.modification_time)
      loop do
        sleep 250.milliseconds
        cur = File.info?(script).try(&.modification_time)
        if cur != last_mtime
          last_mtime = cur
          select
          when reload_ch.send(nil)
          when timeout(50.milliseconds)
          end
        end
      end
    end

    app.frame
    app.frame
    backend.sync_atlas(atlas)
    if demo_capture
      Dir.mkdir_p("artifacts/frames") unless Dir.exists?("artifacts/frames")
    end
    STDERR.puts "lex: loop start" if DEBUG_RENDER

    frames = 0
    reloads = 0
    until LexState.quit_requested || (frame_limit > 0 && frames >= frame_limit)
      pump_messages
      apply_input(app)
      reload_now = false
      select
      when reload_ch.receive?
        reload_now = true
      when timeout(0.seconds)
      end
      if reload_now
        app.reload_script
        reloads += 1
      end
      if LexState.key_code == VK_F2
        LexState.key_code = 0
        app.toggle_script
      end

      app.frame
      frames += 1
      render(app, backend, renderer, atlas, placement, theme)
      LexGdi32.SwapBuffers(hdc)
      if demo_capture
        # 帧序列（GIF 素材）：每 3 帧一抽，120 帧 → 40 张
        if frames % 3 == 0
          capture_bmp(sprintf("artifacts/frames/f%03d.bmp", frames), WIDTH, HEIGHT)
        end
        case frames
        when 30
          capture_bmp("artifacts/demo_1_initial.bmp", WIDTH, HEIGHT)
        when 40
          click_button(app, "Harm")   # G1 现场注入：脚本 raise → 错误条
        when 70
          capture_bmp("artifacts/demo_2_error.bmp", WIDTH, HEIGHT)
        when 80
          # G2 现场热重载：改按钮文案 → reload
          File.write(script, File.read(script).gsub("Log Explorer", "Log Explorer [reloaded]"))
          app.reload_script
        when 110
          capture_bmp("artifacts/demo_3_reload.bmp", WIDTH, HEIGHT)
        when 120
          LexState.quit_requested = true
        end
      end
    end
    unless screenshot.empty?
      capture_bmp(screenshot, WIDTH, HEIGHT)
    end
    app.close
    STDERR.puts "lex: loop done frames=#{frames}"
    "frames=#{frames} reloads=#{reloads}"
  end

  # 抓最后一帧写 BMP（GL 原点在左下，BMP 行序同为 bottom-up，直接转 BGR）。
  private def self.capture_bmp(path : String, w : Int32, h : Int32) : Nil
    LexGLCap.glFinish
    LexGLCap.glPixelStorei(LexGLCap::GL_PACK_ALIGNMENT, 1)
    buf = Bytes.new(w * h * 4)
    LexGLCap.glReadPixels(0, 0, w, h, LexGLCap::GL_RGBA, LexGLCap::GL_UNSIGNED_BYTE,
      buf.to_unsafe.as(Void*))
    row_size = (w * 3 + 3) & ~3
    data_size = row_size * h
    header = Bytes.new(54)
    io = IO::Memory.new(header)
    io.write_bytes(0x4D42_u16, IO::ByteFormat::LittleEndian) # BM
    io.write_bytes((54 + data_size).to_u32, IO::ByteFormat::LittleEndian)
    io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)      # reserved
    io.write_bytes(54_u32, IO::ByteFormat::LittleEndian)     # data offset
    io.write_bytes(40_u32, IO::ByteFormat::LittleEndian)     # DIB header size
    io.write_bytes(w.to_i32, IO::ByteFormat::LittleEndian)
    io.write_bytes(h.to_i32, IO::ByteFormat::LittleEndian)
    io.write_bytes(1_u16, IO::ByteFormat::LittleEndian)      # planes
    io.write_bytes(24_u16, IO::ByteFormat::LittleEndian)     # bpp
    io.write_bytes(0_u32, IO::ByteFormat::LittleEndian)      # compression
    io.write_bytes(data_size.to_u32, IO::ByteFormat::LittleEndian)
    File.write(path, header)
    File.open(path, "a") do |f|
      row = Bytes.new(row_size)
      y = 0
      while y < h
        x = 0
        while x < w
          si = (y * w + x) * 4
          row[x * 3] = buf[si + 2]
          row[x * 3 + 1] = buf[si + 1]
          row[x * 3 + 2] = buf[si]
          x += 1
        end
        f.write(row)
        y += 1
      end
    end
    STDERR.puts "lex: screenshot=#{path}"
  end

  private def self.pump_messages : Nil
    msg = LexUser32::MSG.new
    while LexUser32.PeekMessageW(pointerof(msg), Pointer(Void).null, 0_u32, 0_u32, PM_REMOVE) != 0
      if msg.message == WM_QUIT
        LexState.quit_requested = true
        break
      end
      LexUser32.TranslateMessage(pointerof(msg))
      LexUser32.DispatchMessageW(pointerof(msg))
    end
  end

  private def self.apply_input(app : HostApp) : Nil
    if LexState.mouse_moved
      LexState.mouse_moved = false
      app.handle_event(Input::Event.pointer_move(LexState.mouse_x.to_f32, LexState.mouse_y.to_f32))
    end
    dx, dy = LexState.mouse_down_x, LexState.mouse_down_y
    if dx >= 0
      LexState.mouse_down_x = -1
      app.handle_event(Input::Event.pointer_down(dx.to_f32, dy.to_f32, 0, Input::Modifiers.none, ms_now))
    end
    ux, uy = LexState.mouse_up_x, LexState.mouse_up_y
    if ux >= 0
      LexState.mouse_up_x = -1
      ts = ms_now
      app.handle_event(Input::Event.pointer_up(ux.to_f32, uy.to_f32, 0, Input::Modifiers.none, ts))
    end
    d = LexState.wheel_delta
    if d != 0
      LexState.wheel_delta = 0
      app.handle_event(Input::Event.wheel(WIDTH.to_f32 / 2, HEIGHT.to_f32 / 2,
        0.0_f32, (d > 0 ? 120.0_f32 : -120.0_f32)))
    end
  end

  @@ms : Int64 = 0

  private def self.ms_now : Int64
    @@ms += 16
    @@ms
  end

  private def self.render(app : HostApp, backend : Render::GL::GLBackend,
                          renderer : Render::TextRenderer, atlas : Text::GlyphAtlas,
                          placement : Array(Text::GlyphPlacement), theme : Render::Theme) : Nil
    backend.sync_atlas_dirty(atlas)
    backend.begin_frame(nil, theme)
    renderer.reset
    err_color = 0xff5544ff_u32 # BGRA 口径与 Theme 一致（红调错误条）
    i = 0
    decls = app.last_decls
    rendered = 0
    while i < decls.size
      d = decls[i]
      if d.kind == UI::DeclKind::Text
        node = app.pool.map[d.key]?
        if node && node.bounds.size.width > 0
          color = d.key == ERR_KEY ? err_color : theme.fg
          size = d.text_size.to_i32
          baseline = node.bounds.origin.y + node.bounds.size.height * 0.5_f32 + size * 0.5_f32
          rendered += 1
          renderer.append_text_cached(placement, d.text,
            node.bounds.origin.x + 6.0_f32, baseline, size, WIDTH, HEIGHT, color)
        end
      end
      i += 1
    end
    backend.draw_text(renderer.vertices, renderer.batch_runs, renderer.batch_count)
    backend.end_frame
  end
end
