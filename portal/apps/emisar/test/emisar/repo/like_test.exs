defmodule Emisar.Repo.LikeTest do
  use ExUnit.Case, async: true

  alias Emisar.Repo.Like

  describe "escape/1" do
    test "escapes the `_` single-char wildcard so it matches literally" do
      assert Like.escape("a_b") == "a\\_b"
    end

    test "escapes the `%` multi-char wildcard" do
      assert Like.escape("100%") == "100\\%"
    end

    test "escapes a literal backslash first, so the escapes we add aren't re-escaped" do
      assert Like.escape("a\\b") == "a\\\\b"
    end

    test "leaves a plain term untouched" do
      assert Like.escape("postgres.vacuum") == "postgres.vacuum"
    end
  end

  describe "contains/1" do
    test "wraps an escaped term in substring wildcards" do
      assert Like.contains("a_b") == "%a\\_b%"
    end

    test "an all-`%` term can no longer match everything" do
      assert Like.contains("%") == "%\\%%"
    end
  end

  describe "prefix/1" do
    test "appends a trailing wildcard to an escaped term" do
      assert Like.prefix("req_1%") == "req\\_1\\%%"
    end
  end
end
