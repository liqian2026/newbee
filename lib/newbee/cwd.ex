defmodule Newbee.Cwd do
  @moduledoc "启动时工作目录解析：优先 NEWBEE_CWD 环境变量（bin/newbee 脚本注入），否则 File.cwd!()"
  def apply! do
    case System.get_env("NEWBEE_CWD") do
      nil -> :ok
      dir ->
        dir = Path.expand(dir)
        if File.dir?(dir) do
          File.cd!(dir)
        else
          IO.puts("警告: NEWBEE_CWD=#{dir} 不存在，使用 #{File.cwd!()}")
        end
    end
  end
end
