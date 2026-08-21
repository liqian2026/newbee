defmodule Newbee.HotReloaderTest do
  use ExUnit.Case, async: false

  alias Newbee.HotReloader

  test "BEAM 变化后自动安全热载新版本" do
    unique = :erlang.unique_integer([:positive])
    module = Module.concat([Newbee, "HotReloadFixture#{unique}"])
    dir = Path.join(System.tmp_dir!(), "newbee_hot_reload_#{unique}")
    path = Path.join(dir, Atom.to_string(module) <> ".beam")
    File.mkdir_p!(dir)

    on_exit(fn ->
      :code.soft_purge(module)
      :code.delete(module)
      :code.purge(module)
      File.rm_rf(dir)
    end)

    write_beam(module, 1, path)
    assert {:module, ^module} = :code.load_abs(String.to_charlist(Path.rootname(path)))
    assert apply(module, :version, []) == 1

    {:ok, watcher} = HotReloader.start_link(name: nil, dirs: [dir], interval: 60_000)
    write_beam(module, 2, path)

    assert [{:ok, ^module}] = HotReloader.scan_now(watcher)
    assert apply(module, :version, []) == 2
    GenServer.stop(watcher)
  end

  defp write_beam(module, version, path) do
    forms = [
      {:attribute, 1, :module, module},
      {:attribute, 1, :export, [version: 0]},
      {:function, 1, :version, 0, [{:clause, 1, [], [], [{:integer, 1, version}]}]}
    ]

    {:ok, ^module, binary, _warnings} = :compile.forms(forms, [:return, :binary])
    File.write!(path, binary)
  end
end
