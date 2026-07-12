defmodule EmisarWeb.PacksRegistry.PackTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.PacksRegistry.Pack

  defp pack(version, previous_versions) do
    %Pack{
      id: "redis",
      name: "redis operations",
      version: version,
      description: "Ops for redis.",
      vendor: "emisar",
      source_url: "https://github.com/andrewdryga/emisar/tree/main/packs/redis",
      content_hash: "sha256:#{String.duplicate("a", 64)}",
      tarball_url: "https://registry.emisar.dev/v1/packs/redis/#{version}/x.tar.gz",
      previous_versions: previous_versions,
      actions: []
    }
  end

  defp previous(version) do
    %{
      version: version,
      content_hash: "sha256:#{String.duplicate("b", 64)}",
      tarball_url: "https://registry.emisar.dev/v1/packs/redis/#{version}/y.tar.gz"
    }
  end

  describe "tarball_url/2" do
    test "resolves the current version to its own tarball" do
      pack = pack("0.2.0", [previous("0.1.0")])
      assert Pack.tarball_url(pack, "0.2.0") == {:ok, pack.tarball_url}
    end

    test "resolves a remembered prior version to its historical tarball" do
      history = previous("0.1.0")
      pack = pack("0.2.0", [history])
      assert Pack.tarball_url(pack, "0.1.0") == {:ok, history.tarball_url}
    end

    test "is :error for a version that is neither current nor remembered" do
      pack = pack("0.2.0", [previous("0.1.0")])
      assert Pack.tarball_url(pack, "9.9.9") == :error
    end

    test "is :error for any prior version when the window is empty" do
      pack = pack("0.2.0", [])
      assert Pack.tarball_url(pack, "0.1.0") == :error
    end
  end
end
