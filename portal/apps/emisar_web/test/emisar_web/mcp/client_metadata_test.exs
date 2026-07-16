defmodule EmisarWeb.MCP.ClientMetadataTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.MCP.ClientMetadata

  describe "parse/1" do
    test "absent or blank header yields an empty map" do
      assert ClientMetadata.parse([]) == {:ok, %{}}
      assert ClientMetadata.parse(nil) == {:ok, %{}}
      assert ClientMetadata.parse("") == {:ok, %{}}
      assert ClientMetadata.parse("   ") == {:ok, %{}}
      assert ClientMetadata.parse("{}") == {:ok, %{}}
    end

    test "reads the first header value from a list" do
      assert ClientMetadata.parse([~s({"asset_tag":"LT-4417"}), "ignored"]) ==
               {:ok, %{"asset_tag" => "LT-4417"}}
    end

    test "accepts string values" do
      assert ClientMetadata.parse(~s({"asset_tag":"LT-4417","device_id":"d-99"})) ==
               {:ok, %{"asset_tag" => "LT-4417", "device_id" => "d-99"}}
    end

    test "accepts numeric values, storing their string representation" do
      assert ClientMetadata.parse(~s({"port":8080,"ratio":1.5})) ==
               {:ok, %{"port" => "8080", "ratio" => "1.5"}}

      assert ClientMetadata.parse(~s({"ratio":1e308})) ==
               {:ok, %{"ratio" => "1.0e308"}}

      assert ClientMetadata.parse(~s({"ratio":1e-400})) ==
               {:ok, %{"ratio" => "0.0"}}
    end

    test "rejects a floating-point value outside the decoder's range" do
      assert ClientMetadata.parse(~s({"ratio":1e309})) ==
               {:error, "client metadata is not valid JSON"}
    end

    test "allows arbitrary key names a stricter design would blacklist" do
      assert ClientMetadata.parse(~s({"password":"x","role":"admin","managed":"true"})) ==
               {:ok, %{"password" => "x", "role" => "admin", "managed" => "true"}}
    end

    test "accepts exactly 10 keys and rejects an 11th" do
      ten = for i <- 1..10, into: %{}, do: {"k#{i}", "v"}
      assert {:ok, parsed} = ClientMetadata.parse(Jason.encode!(ten))
      assert map_size(parsed) == 10

      eleven = for i <- 1..11, into: %{}, do: {"k#{i}", "v"}
      assert {:error, message} = ClientMetadata.parse(Jason.encode!(eleven))
      assert message =~ "more than 10 keys"
    end

    test "enforces the 128-character key limit" do
      assert {:ok, _} = ClientMetadata.parse(~s({"#{String.duplicate("k", 128)}":"v"}))
      assert {:error, message} = ClientMetadata.parse(~s({"#{String.duplicate("k", 129)}":"v"}))
      assert message =~ "exceeds 128 characters"
    end

    test "enforces the 512-character value limit on the string representation" do
      assert {:ok, _} = ClientMetadata.parse(~s({"a":"#{String.duplicate("v", 512)}"}))
      assert {:error, message} = ClientMetadata.parse(~s({"a":"#{String.duplicate("v", 513)}"}))
      assert message =~ "exceeds 512 characters"
    end

    test "rejects disallowed value types" do
      for value <- [~s(["x"]), ~s({"b":"c"}), "true", "null"] do
        assert {:error, message} = ClientMetadata.parse(~s({"a":#{value}}))
        assert message =~ "must be a string or number"
      end
    end

    test "fails closed on non-object and malformed JSON" do
      assert ClientMetadata.parse(~s(["a"])) == {:error, "client metadata must be a JSON object"}
      assert ClientMetadata.parse(~s("x")) == {:error, "client metadata must be a JSON object"}
      assert ClientMetadata.parse("5") == {:error, "client metadata must be a JSON object"}
      assert ClientMetadata.parse("not json") == {:error, "client metadata is not valid JSON"}
    end
  end
end
