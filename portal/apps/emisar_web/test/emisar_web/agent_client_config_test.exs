defmodule EmisarWeb.AgentClientConfigTest do
  use ExUnit.Case, async: true
  alias EmisarWeb.AgentClientConfig

  @json_clients %{
    "claude_desktop" => {["mcpServers", "emisar"], "claude-desktop"},
    "cursor" => {["mcpServers", "emisar"], "cursor"},
    "vscode" => {["servers", "emisar"], "vscode"},
    "gemini" => {["mcpServers", "emisar"], "gemini"},
    "windsurf" => {["mcpServers", "emisar"], "windsurf"},
    "pi" => {["mcpServers", "emisar"], "pi"},
    "openclaw" => {["mcp", "servers", "emisar"], "openclaw"},
    "opencode" => {["mcp", "emisar"], "opencode"},
    "copilot" => {["mcpServers", "emisar"], "copilot-cli"},
    "zed" => {["context_servers", "emisar"], "zed"}
  }
  @paths %{
    linux: ~s|/home/operator/o'"$()`&/emisar-mcp|,
    macos: ~s|/Users/Operator Name/.local/bin/emisar-mcp|,
    windows: ~S|C:\Users\O'Brien & $operator\Programs\emisar-mcp.exe|
  }

  describe "render/5" do
    test "every JSON client preserves its schema and executable literally on every platform" do
      for {client, {container, client_id}} <- @json_clients, {os, path} <- @paths do
        config = AgentClientConfig.render(client, "https://emisar.dev", "emk-test", os, path)
        document = Jason.decode!(config.body)
        entry = get_in(document, container)
        command = if client == "opencode", do: [path], else: path
        env = if client == "opencode", do: entry["environment"], else: entry["env"]

        assert entry["command"] == command
        assert env["EMISAR_URL"] == "https://emisar.dev"
        assert env["EMISAR_CLIENT"] == client_id

        if client == "vscode" do
          refute config.body =~ "emk-test"
          assert config.secret_separate
          assert env["EMISAR_API_KEY"] == "${input:emisar-api-key}"
          assert hd(document["inputs"])["password"] == true
          assert entry["type"] == "stdio"
        else
          assert env["EMISAR_API_KEY"] == "emk-test"
        end

        if client == "copilot", do: assert(entry["tools"] == ["*"])
        if client == "zed", do: assert(entry["source"] == "custom")
        if client == "opencode", do: assert(entry["enabled"] == true)
      end
    end

    test "YAML clients quote paths and environment values as literal scalars" do
      for {os, path} <- @paths,
          {client, command_key} <- [
            {"hermes", "command"},
            {"goose", "cmd"}
          ] do
        config = AgentClientConfig.render(client, "https://[::1]:4000", "emk-test", os, path)

        # JSON double-quoted strings are also YAML double-quoted scalars.
        for {name, expected} <- [
              {command_key, path},
              {"EMISAR_URL", "https://[::1]:4000"},
              {"EMISAR_API_KEY", "emk-test"}
            ] do
          [_, scalar] = Regex.run(~r/^\s+#{name}: (.+)$/m, config.body)
          assert Jason.decode!(scalar) == expected
        end

        assert config.body =~ "EMISAR_CLIENT: #{client}"
      end
    end

    test "Codex uses escaped TOML basic-string scalars on every platform" do
      for {os, path} <- @paths do
        config = AgentClientConfig.render("codex", "https://emisar.dev", "emk-test", os, path)

        assert config.body == """
               [mcp_servers.emisar]
               command = #{Jason.encode!(path)}
               env = { EMISAR_URL = "https://emisar.dev", EMISAR_API_KEY = "emk-test", EMISAR_CLIENT = "codex" }\
               """
      end
    end

    test "POSIX command snippets pass hostile-looking paths as one literal argument" do
      for {client, executable, client_id} <- [
            {"claude_code", "claude", "claude-code"},
            {"grok", "grok", "grok"}
          ],
          os <- [:linux, :macos] do
        path = @paths[os]
        config = AgentClientConfig.render(client, "https://[::1]:4000", "emk-test", os, path)
        capture = executable <> "() { printf '%s\\n' \"$@\"; }\n" <> config.body
        assert {output, 0} = System.cmd("sh", ["-c", capture])
        args = String.split(output, "\n", trim: true)

        assert List.last(args) == path
        assert "EMISAR_URL=https://[::1]:4000" in args
        assert "EMISAR_API_KEY=emk-test" in args
        assert "EMISAR_CLIENT=#{client_id}" in args

        if client == "claude_code" do
          assert Enum.take(args, -7) == [
                   "--transport",
                   "stdio",
                   "--scope",
                   "user",
                   "emisar",
                   "--",
                   path
                 ]
        end
      end
    end

    test "Windows commands use PowerShell literals and terminate Claude's variadic env option" do
      for client <- ["claude_code", "grok"] do
        config =
          AgentClientConfig.render(
            client,
            "https://emisar.dev",
            "emk-test",
            :windows,
            @paths.windows
          )

        assert String.ends_with?(
                 config.body,
                 ~S|'C:\Users\O''Brien & $operator\Programs\emisar-mcp.exe'|
               )

        refute config.body =~ "\n"
        refute config.body =~ "cmd.exe"

        if client == "claude_code" do
          assert config.body =~
                   "--env 'EMISAR_CLIENT=claude-code' --transport stdio --scope user emisar --"
        end
      end
    end

    test "missing or relative executable paths never produce a copyable body" do
      for client <- EmisarWeb.AgentsLive.local_client_ids(),
          {os, path} <- [
            windows: "",
            windows: "%LOCALAPPDATA%\\emisar-mcp.exe",
            linux: "~/bin/emisar-mcp"
          ] do
        assert AgentClientConfig.render(client, "https://emisar.dev", "emk-test", os, path).body ==
                 nil
      end
    end

    test "platform configuration locations follow each client rather than the server OS" do
      locations = %{
        "claude_desktop" =>
          {"~/.config/Claude/claude_desktop_config.json",
           "~/Library/Application Support/Claude/claude_desktop_config.json",
           ~S|%APPDATA%\Claude\claude_desktop_config.json|},
        "vscode" =>
          {"~/.config/Code/User/mcp.json", "~/Library/Application Support/Code/User/mcp.json",
           ~S|%APPDATA%\Code\User\mcp.json|},
        "zed" =>
          {"~/.config/zed/settings.json", "~/.config/zed/settings.json",
           ~S|%APPDATA%\Zed\settings.json|},
        "hermes" =>
          {"~/.hermes/config.yaml", "~/.hermes/config.yaml",
           ~S|%LOCALAPPDATA%\hermes\config.yaml|},
        "goose" =>
          {"~/.config/goose/config.yaml", "~/.config/goose/config.yaml",
           ~S|%APPDATA%\Block\goose\config\config.yaml|}
      }

      for {client, {linux, macos, windows}} <- locations do
        for {os, expected} <- [linux: linux, windows: windows, macos: macos] do
          assert AgentClientConfig.render(
                   client,
                   "https://emisar.dev",
                   "emk-test",
                   os,
                   @paths[os]
                 ).location == expected
        end
      end

      for {client, suffix} <- [
            {"cursor", ".cursor/mcp.json"},
            {"gemini", ".gemini/settings.json"},
            {"codex", ".codex/config.toml"},
            {"windsurf", ".codeium/windsurf/mcp_config.json"},
            {"pi", ".pi/agent/mcp.json"},
            {"openclaw", ".openclaw/openclaw.json"},
            {"opencode", ".config/opencode/opencode.json"},
            {"copilot", ".copilot/mcp-config.json"}
          ],
          {os, path} <- @paths do
        expected =
          if os == :windows,
            do: "%USERPROFILE%\\" <> String.replace(suffix, "/", "\\"),
            else: "~/" <> suffix

        assert AgentClientConfig.render(client, "https://emisar.dev", "emk-test", os, path).location ==
                 expected
      end
    end

    test "optional auto-permit locations follow Windows home paths" do
      for {client, suffix} <- [
            {"claude_code", ~S|.claude\settings.json|},
            {"gemini", ~S|.gemini\settings.json|},
            {"grok", ~S|.grok\config.toml|}
          ] do
        config =
          AgentClientConfig.render(
            client,
            "https://emisar.dev",
            "emk-test",
            :windows,
            @paths.windows
          )

        assert config.auto_permit.location =~ "%USERPROFILE%\\" <> suffix
      end

      config =
        AgentClientConfig.render(
          "codex",
          "https://emisar.dev",
          "emk-test",
          :windows,
          @paths.windows
        )

      assert config.auto_permit.pointer =~ ~S|%USERPROFILE%\.codex\config.toml|
    end
  end

  describe "path_error/2" do
    test "accepts absolute paths with spaces and shell punctuation but rejects incomplete paths" do
      for {os, path} <- @paths, do: assert(AgentClientConfig.path_error(path, os) == nil)
      assert AgentClientConfig.path_error(~S|\\server\share\emisar-mcp.exe|, :windows) == nil

      for {os, path} <- [
            windows: "C:emisar.exe",
            windows: "$env:LOCALAPPDATA\\emisar.exe",
            linux: "emisar-mcp",
            linux: "/"
          ] do
        assert AgentClientConfig.path_error(path, os) ==
                 "Use a full path, not ~ or an environment variable."
      end

      assert AgentClientConfig.path_error("/bin/emisar\n-mcp", :linux) ==
               "Enter a path without control characters."

      assert AgentClientConfig.path_error("/" <> String.duplicate("x", 4096), :linux) ==
               "The executable path is too long."
    end
  end
end
