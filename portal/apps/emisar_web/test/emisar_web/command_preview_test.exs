defmodule EmisarWeb.CommandPreviewTest do
  @moduledoc """
  The approval-page command renderer — a port of the runner's argv templating
  + shell quoting + secret masking. These assertions pin it to the runner's
  behaviour so the preview an operator approves against matches what actually
  runs (mismatched semantics would show a misleading command on the highest-
  stakes screen).
  """
  use ExUnit.Case, async: true
  alias EmisarWeb.CommandPreview

  describe "render/3" do
    test "substitutes scalar args and fills declared defaults for omitted ones" do
      command = %{
        binary: "cloud-init",
        argv: ["single", "--name={{ args.module }}", "--frequency={{ args.frequency }}"]
      }

      specs = [%{"name" => "frequency", "default" => "always"}]

      assert CommandPreview.render(command, %{"module" => "ssh"}, specs) ==
               {:ok, "cloud-init single --name=ssh --frequency=always"}
    end

    test "renders a literal (zero-arg) command with no placeholders" do
      command = %{binary: "cloud-init", argv: ["status", "--long"]}

      assert CommandPreview.render(command, %{}, []) == {:ok, "cloud-init status --long"}
    end

    test "expands a whole-expression array element into multiple argv tokens" do
      command = %{binary: "grep", argv: ["-e", "pattern", "{{ args.paths }}"]}

      assert CommandPreview.render(command, %{"paths" => ["/a", "/b c"]}, []) ==
               {:ok, "grep -e pattern /a '/b c'"}
    end

    test "formats integer and boolean args the runner's way" do
      command = %{binary: "tool", argv: ["--count={{ args.n }}", "--force={{ args.force }}"]}

      assert CommandPreview.render(command, %{"n" => 3, "force" => true}, []) ==
               {:ok, "tool --count=3 --force=true"}
    end

    test "shell-quotes values with spaces or metacharacters" do
      command = %{binary: "sh", argv: ["-c", "{{ args.script }}"]}

      assert CommandPreview.render(command, %{"script" => "echo hi; rm x"}, []) ==
               {:ok, "sh -c 'echo hi; rm x'"}
    end

    test "renders an empty-string arg as a quoted empty token" do
      command = %{binary: "tool", argv: ["{{ args.empty }}"]}

      assert CommandPreview.render(command, %{"empty" => ""}, []) == {:ok, "tool ''"}
    end

    test "masks a sensitive arg's value even when embedded in a larger flag" do
      command = %{binary: "curl", argv: ["-H", "Authorization: Bearer {{ args.token }}"]}
      specs = [%{"name" => "token", "sensitive" => true}]

      assert CommandPreview.render(command, %{"token" => "sk-secret"}, specs) ==
               {:ok, "curl -H 'Authorization: Bearer [REDACTED]'"}
    end

    test "errors when a referenced arg is absent (no default) rather than guess" do
      command = %{binary: "tool", argv: ["{{ args.missing }}"]}

      assert CommandPreview.render(command, %{}, []) == :error
    end

    test "errors when a value can't be formatted as a scalar" do
      command = %{binary: "tool", argv: ["{{ args.obj }}"]}

      assert CommandPreview.render(command, %{"obj" => %{"nested" => 1}}, []) == :error
    end

    test "errors for a nil command (a script-kind action has no template)" do
      assert CommandPreview.render(nil, %{}, []) == :error
    end
  end
end
