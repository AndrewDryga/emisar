defmodule EmisarWeb.AgentClientConfig do
  @moduledoc """
  Manual local-client setup: platform paths and literal JSON, TOML, YAML, or shell arguments.
  The caller owns the reveal-once key; rendering a different platform never creates one.
  """

  @standard_clients ~w(claude_desktop cursor gemini windsurf pi)
  @max_path_bytes 4096

  def default_paths do
    %{linux: "/usr/local/bin/emisar-mcp", windows: "", macos: "/usr/local/bin/emisar-mcp"}
  end

  def path_error(path, os) when is_binary(path) and byte_size(path) <= @max_path_bytes do
    cond do
      path == "" ->
        "Enter the full path to your installed emisar-mcp executable."

      not String.valid?(path) or String.match?(path, ~r/[\x00-\x1f\x7f]/) ->
        "Enter a path without control characters."

      not absolute_path?(path, os) ->
        "Use a full path, not ~ or an environment variable."

      true ->
        nil
    end
  end

  def path_error(_path, _os), do: "The executable path is too long."

  def version_command(path, os) do
    if is_nil(path_error(path, os)) do
      prefix = if os == :windows, do: "& ", else: ""

      executable =
        if os != :windows and String.match?(path, ~r/\A[\/A-Za-z0-9_.-]+\z/),
          do: path,
          else: shell_quote(path, os)

      prefix <> executable <> " --version"
    end
  end

  def download_links(os, version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _version} ->
        platform = if os == :macos, do: "darwin", else: to_string(os)
        extension = if os == :windows, do: "zip", else: "tar.gz"

        architectures =
          if os == :macos,
            do: [{"Apple silicon", "arm64"}, {"Intel", "amd64"}],
            else: [{"x64", "amd64"}, {"ARM64", "arm64"}]

        for {label, arch} <- architectures do
          artifact = "emisar-mcp-#{version}-#{platform}-#{arch}.#{extension}"
          {label, "https://emisar.dev/releases/mcp/mcp-v#{version}/#{artifact}"}
        end

      :error ->
        []
    end
  end

  def download_links(_os, _version), do: []

  def coop_dockerfile do
    ~S"""
    ARG COOP_BASE_IMAGE=coop-box
    FROM ${COOP_BASE_IMAGE}

    USER root
    RUN install -d -m 755 /etc/apt/keyrings \
     && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
     && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
     && printf '%s\n' "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          > /etc/apt/sources.list.d/github-cli.list \
     && apt-get update \
     && apt-get install -y --no-install-recommends gh
    RUN curl -fsSL https://emisar.dev/install-mcp.sh -o /tmp/install-mcp.sh \
     && bash /tmp/install-mcp.sh --yes --install-dir /usr/local/bin \
     && install -d -m 700 -o node -g node /config
    USER node
    """
  end

  def render("coop", url, key, _os, _path) do
    %{
      kind: :coop,
      body:
        Jason.encode!(
          %{
            "mcpServers" => %{
              "emisar" => %{
                "command" => "/usr/local/bin/emisar-mcp",
                "env" => %{
                  "EMISAR_URL" => url,
                  "EMISAR_API_KEY" => key,
                  "EMISAR_CLIENT" => "coop",
                  "XDG_CONFIG_HOME" => "/config"
                }
              }
            }
          },
          pretty: true
        )
    }
  end

  def render(client, url, key, os, path) do
    %{
      kind: :local,
      location: location(client, os),
      body: if(is_nil(path_error(path, os)), do: body(client, url, key, os, path)),
      secret_separate: client == "vscode",
      auto_permit: auto_permit(client, os)
    }
  end

  def connection_steps(client, setup \\ :manual) do
    case client do
      "coop" ->
        [
          "Start a new co:op session with your preferred agent, then check that emisar appears in its MCP tools."
        ]

      "claude_code" ->
        [
          "Start a new Claude Code session and run /mcp. Confirm that emisar is connected."
        ]

      "claude_desktop" ->
        [
          "Fully quit and reopen Claude Desktop. Open Settings → Developer and confirm that emisar is running.",
          "Start a chat and enable emisar from + → Connectors."
        ]

      "cursor" ->
        [
          "Restart Cursor, open Customize, and enable the emisar MCP server. Approve the connection when prompted."
        ]

      "vscode" ->
        key_step =
          if setup == :manual,
            do: " Paste the API key above when VS Code asks for it.",
            else: ""

        [
          "In the Command Palette, run MCP: List Servers, select emisar, then Start. Confirm server trust when prompted." <>
            key_step,
          "Open Chat, choose the Local target and Agent role, and enable the emisar tools. For the Copilot session target instead, use the Copilot CLI setup on this page."
        ]

      "gemini" ->
        [
          "Start a new Gemini CLI session in a folder you trust. If prompted, review the folder before trusting it; MCP servers stay disabled in untrusted folders.",
          "Run /mcp and confirm that emisar is connected."
        ]

      "codex" ->
        [
          "Start a new Codex CLI session and run /mcp. Confirm that emisar is connected."
        ]

      "windsurf" ->
        [
          "Restart Windsurf and open Cascade's MCP settings. Enable emisar and confirm that its tools are listed."
        ]

      "zed" ->
        [
          "Restart Zed and open Settings → AI → MCP Servers. Confirm that emisar is active, then open the Agent Panel."
        ]

      "openclaw" ->
        [
          "Restart OpenClaw, then run openclaw mcp probe emisar to check the connection."
        ]

      "opencode" ->
        [
          "Start a new OpenCode session and run opencode mcp list in your terminal. Confirm that emisar is connected."
        ]

      "copilot" ->
        [
          "Start a new Copilot CLI session and run /mcp show emisar to check its status and tools."
        ]

      "grok" ->
        [
          "Run grok mcp doctor emisar to check the connection, then start a new Grok CLI session."
        ]

      "pi" ->
        [
          "Restart Pi after installing the MCP adapter and saving the configuration, then run /mcp reconnect emisar."
        ]

      "hermes" ->
        [
          "Run hermes mcp test emisar to check the connection and its tools, then start a new Hermes chat."
        ]

      "goose" ->
        [
          "Restart Goose and start a new session. If emisar is missing, check that it is enabled under Extensions."
        ]
    end
  end

  defp absolute_path?(path, :windows),
    do: String.match?(path, ~r/\A(?:[A-Za-z]:[\\\/]|\\\\[^\\]+\\[^\\]+\\).+/)

  defp absolute_path?(path, os) when os in [:linux, :macos],
    do: String.starts_with?(path, "/") and path != "/"

  defp location("claude_code", _os), do: nil
  defp location("grok", _os), do: nil

  defp location("claude_desktop", os),
    do: app_config(os, "Claude/claude_desktop_config.json")

  defp location("vscode", os), do: app_config(os, "Code/User/mcp.json")
  defp location("zed", :windows), do: app_config(:windows, "Zed/settings.json")
  defp location("hermes", :windows), do: "%LOCALAPPDATA%\\hermes\\config.yaml"
  defp location("goose", :windows), do: "%APPDATA%\\Block\\goose\\config\\config.yaml"

  defp location(client, os) do
    suffix =
      case client do
        "cursor" -> ".cursor/mcp.json"
        "gemini" -> ".gemini/settings.json"
        "codex" -> ".codex/config.toml"
        "windsurf" -> ".codeium/windsurf/mcp_config.json"
        "pi" -> ".pi/agent/mcp.json"
        "openclaw" -> ".openclaw/openclaw.json"
        "opencode" -> ".config/opencode/opencode.json"
        "copilot" -> ".copilot/mcp-config.json"
        "zed" -> ".config/zed/settings.json"
        "hermes" -> ".hermes/config.yaml"
        "goose" -> ".config/goose/config.yaml"
      end

    home_path(os, suffix)
  end

  defp home_path(:windows, suffix), do: "%USERPROFILE%\\" <> windows_path(suffix)
  defp home_path(os, suffix) when os in [:linux, :macos], do: "~/" <> suffix
  defp app_config(:windows, suffix), do: "%APPDATA%\\" <> windows_path(suffix)
  defp app_config(:linux, suffix), do: "~/.config/" <> suffix
  defp app_config(:macos, suffix), do: "~/Library/Application Support/" <> suffix
  defp windows_path(path), do: String.replace(path, "/", "\\")

  defp body(client, url, key, os, path) when client in ["claude_code", "grok"] do
    {command, env_flag, options, client_id} =
      case client do
        "claude_code" ->
          {"claude mcp add", "--env", "--transport stdio --scope user emisar --", "claude-code"}

        "grok" ->
          {"grok mcp add emisar", "-e", "--", "grok"}
      end

    # Claude's --env is variadic: the transport option terminates its final
    # value before the positional server name can be swallowed as an env entry.
    args = ["EMISAR_URL=#{url}", "EMISAR_API_KEY=#{key}", "EMISAR_CLIENT=#{client_id}"]
    env = Enum.map(args, &(env_flag <> " " <> shell_quote(&1, os)))
    separator = if os == :windows, do: " ", else: " \\\n  "
    prefix = if os == :windows, do: "", else: " "
    prefix <> Enum.join([command] ++ env ++ [options, shell_quote(path, os)], separator)
  end

  defp body("codex", url, key, _os, path) do
    """
    [mcp_servers.emisar]
    command = #{Jason.encode!(path)}
    env = { EMISAR_URL = #{Jason.encode!(url)}, EMISAR_API_KEY = #{Jason.encode!(key)}, EMISAR_CLIENT = "codex" }\
    """
  end

  defp body("hermes", url, key, _os, path) do
    """
    mcp_servers:
      emisar:
        command: #{Jason.encode!(path)}
        env:
          EMISAR_URL: #{Jason.encode!(url)}
          EMISAR_API_KEY: #{Jason.encode!(key)}
          EMISAR_CLIENT: hermes\
    """
  end

  defp body("goose", url, key, _os, path) do
    """
    extensions:
      emisar:
        name: emisar
        cmd: #{Jason.encode!(path)}
        args: []
        enabled: true
        envs:
          EMISAR_URL: #{Jason.encode!(url)}
          EMISAR_API_KEY: #{Jason.encode!(key)}
          EMISAR_CLIENT: goose
        type: stdio
        timeout: 300\
    """
  end

  defp body(client, url, key, _os, path) do
    client_id =
      case client do
        "claude_desktop" -> "claude-desktop"
        "copilot" -> "copilot-cli"
        other -> other
      end

    env = %{"EMISAR_URL" => url, "EMISAR_API_KEY" => key, "EMISAR_CLIENT" => client_id}
    entry = %{"command" => path, "env" => env}
    client |> json_config(entry) |> Jason.encode!(pretty: true)
  end

  defp json_config(client, entry) when client in @standard_clients,
    do: %{"mcpServers" => %{"emisar" => entry}}

  defp json_config("openclaw", entry), do: %{"mcp" => %{"servers" => %{"emisar" => entry}}}

  defp json_config("opencode", entry) do
    %{
      "mcp" => %{
        "emisar" => %{
          "type" => "local",
          "command" => [entry["command"]],
          "enabled" => true,
          "environment" => entry["env"]
        }
      }
    }
  end

  defp json_config("copilot", entry) do
    entry = Map.merge(entry, %{"type" => "local", "args" => [], "tools" => ["*"]})
    %{"mcpServers" => %{"emisar" => entry}}
  end

  defp json_config("zed", entry) do
    entry = Map.merge(entry, %{"source" => "custom", "args" => []})
    %{"context_servers" => %{"emisar" => entry}}
  end

  defp json_config("vscode", entry) do
    # User MCP configuration may sync; the password stays in the client's
    # local prompt storage instead of travelling with any platform's snippet.
    entry =
      entry
      |> put_in(["env", "EMISAR_API_KEY"], "${input:emisar-api-key}")
      |> Map.merge(%{"type" => "stdio", "args" => []})

    %{
      "inputs" => [
        %{
          "type" => "promptString",
          "id" => "emisar-api-key",
          "description" => "Emisar API key",
          "password" => true
        }
      ],
      "servers" => %{"emisar" => entry}
    }
  end

  defp shell_quote(value, :windows), do: "'" <> String.replace(value, "'", "''") <> "'"
  defp shell_quote(value, _os), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp auto_permit("claude_code", os) do
    %{
      installer: true,
      location: home_path(os, ".claude/settings.json") <> " (Claude Code's settings)",
      body: ~s({\n  "permissions": {\n    "allow": ["mcp__emisar__*"]\n  }\n})
    }
  end

  defp auto_permit("cursor", os) do
    %{
      pointer:
        "In Cursor Settings, choose Allowlist as the Run Mode and add emisar:* to the MCP allowlist. For file-based setup, add it to mcpAllowlist in #{home_path(os, ".cursor/permissions.json")}. Keep existing entries: this field replaces the in-app list. Your team's policy may restrict local overrides.",
      doc_url: "https://prod.cursor.com/docs/reference/permissions"
    }
  end

  defp auto_permit("gemini", os) do
    %{
      installer: true,
      location: location("gemini", os) <> " — add to the \"emisar\" server block",
      body: ~s("emisar": {\n  "trust": true\n})
    }
  end

  defp auto_permit("codex", os) do
    %{
      installer: true,
      pointer:
        "Add default_tools_approval_mode = \"approve\" below [mcp_servers.emisar] in #{location("codex", os)}. This trusts only the emisar MCP server; emisar still applies its own policies and approvals.",
      doc_url: "https://developers.openai.com/codex/mcp"
    }
  end

  defp auto_permit("grok", os) do
    %{
      installer: true,
      location:
        home_path(os, ".grok/config.toml") <> " — add to the existing [permission] section",
      body: ~s|allow = ["MCPTool(emisar__*)"]|
    }
  end

  defp auto_permit(_client, _os), do: nil
end
