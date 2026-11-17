require "spec"
require "../src/tessell_mruby"

# 把脚本写到临时文件（load_file 需要真实路径，错误信息里的 file:line 才有意义）。
def write_script(content : String) : String
  path = File.tempname("tessell_mruby_spec", ".rb")
  File.write(path, content)
  path
end

def cleanup(path : String) : Nil
  File.delete(path) if File.exists?(path)
rescue
  nil
end
