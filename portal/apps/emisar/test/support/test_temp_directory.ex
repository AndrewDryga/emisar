defmodule Emisar.TestTempDirectory do
  @moduledoc false

  def create!(name) when is_binary(name) do
    suffix = "#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
    path = Path.join(System.tmp_dir!(), "emisar-#{name}-#{suffix}")
    File.mkdir_p!(path)
    ExUnit.Callbacks.on_exit({__MODULE__, path}, fn -> File.rm_rf!(path) end)
    path
  end
end
