defmodule Emisar.Policies.GlobTest do
  use ExUnit.Case, async: true
  alias Emisar.Policies.Glob

  describe "match?/2" do
    test "a trailing * matches any suffix" do
      assert Glob.match?("nginx_*", "nginx_reload")
      assert Glob.match?("nginx_*", "nginx_")
      refute Glob.match?("nginx_*", "apache_reload")
    end

    test "a bare * matches anything, including empty" do
      assert Glob.match?("*", "anything")
      assert Glob.match?("*", "")
    end

    test "matches case-insensitively" do
      assert Glob.match?("NginX_*", "nginx_x")
      assert Glob.match?("nginx_*", "NGINX_RELOAD")
    end

    test "a literal pattern matches only its (case-folded) equal" do
      assert Glob.match?("nginx_reload", "NGINX_RELOAD")
      refute Glob.match?("nginx_reload", "nginx_stop")
    end

    test "non-* characters stay literal — dots and underscores aren't wildcards" do
      refute Glob.match?("a.b", "axb")
      assert Glob.match?("a.b", "A.B")
    end

    test "the empty pattern matches only the empty string (as the original did)" do
      assert Glob.match?("", "")
      refute Glob.match?("", "x")
    end
  end

  describe "compile/1 + match_compiled?/2" do
    test "preserves match?/2 semantics for repeated matches" do
      cases = [
        {"nginx_*", "NGINX_RELOAD", true},
        {"nginx_*", "apache_reload", false},
        {"linux.uptime", "LINUX.UPTIME", true},
        {"linux.uptime", "linux.reboot", false}
      ]

      for {pattern, string, expected} <- cases do
        matcher = Glob.compile(pattern)

        assert Glob.match_compiled?(matcher, string) == expected
        assert Glob.match_compiled?(matcher, string) == Glob.match?(pattern, string)
      end
    end
  end

  describe "subsumes?/2 — true (L(b) ⊆ L(a))" do
    test "* subsumes everything" do
      assert Glob.subsumes?("*", "anything")
      assert Glob.subsumes?("*", "")
    end

    test "a prefix-* subsumes a longer match and a longer glob" do
      assert Glob.subsumes?("a*", "ab")
      assert Glob.subsumes?("a*", "ab*")
    end

    test "a glob subsumes a concrete string it matches" do
      assert Glob.subsumes?("nginx_*", "nginx_reload")
    end

    test "identical patterns subsume each other" do
      assert Glob.subsumes?("nginx_reload", "nginx_reload")
    end

    test "an interior * subsumes a literal that threads through it" do
      assert Glob.subsumes?("a*c", "abc")
      assert Glob.subsumes?("a*c*e", "abcde")
    end

    test "subsumption is case-insensitive" do
      assert Glob.subsumes?("NGINX_*", "nginx_reload")
    end
  end

  describe "subsumes?/2 — false" do
    test "disjoint prefixes don't subsume" do
      refute Glob.subsumes?("a*", "b*")
    end

    test "a narrower glob doesn't subsume a broader one" do
      refute Glob.subsumes?("a*", "*")
      refute Glob.subsumes?("a*b", "a*")
      refute Glob.subsumes?("a*b*c", "a*c")
    end

    test "a literal doesn't subsume a glob that also matches other strings" do
      refute Glob.subsumes?("nginx_reload", "nginx_*")
    end

    test "suffix-* and prefix-* don't subsume each other" do
      refute Glob.subsumes?("*x", "x*")
      refute Glob.subsumes?("x*", "*x")
    end

    test "a fixed-literal-after-* isn't covered by an open *" do
      refute Glob.subsumes?("a*c", "abd")
    end
  end
end
