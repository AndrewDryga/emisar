defmodule EmisarWeb.SandboxRisks do
  @moduledoc """
  The "Limits & risks" copy for each agent sandbox, once. The Console's sandbox
  setup and the public sandboxes guide both render it, each with its own
  components, so a corrected warning cannot leave the other surface stating the
  old risk. Fifteen of these sentences used to be hand-copied between the two.

  Each risk is a list of segments: plain text, `{:code, text}`, `{:guide, label,
  anchor}` for a link into the sandboxes guide, `{:link, label, url}` for an
  external page, or `{:agents, label}` for the Console's AI agents page.
  `rotation`, when present, is one paragraph in the same segment form.
  """

  @sandboxes %{
    "coop" => %{
      title: "Recommendations",
      risks: [
        [
          "Only add the files, secrets, and host tools the agent needs. Use ",
          {:code, ".coopignore"},
          " for project-specific secrets; ",
          {:code, ".gitignore"},
          " does not hide them from the agent."
        ],
        [
          "Anything you mount or pass into the sandbox remains available to the agent. Keep production credentials and privileged host sockets out."
        ],
        [
          "Run ",
          {:code, "coop doctor"},
          " after setup to verify the sandbox. Run ",
          {:code, "coop check-secrets"},
          " regularly to find secrets hidden in your repository."
        ]
      ],
      rotation: nil
    },
    "docker_sandboxes" => %{
      title: "Limits & risks",
      risks: [
        [
          "Docker shares the project directory with the VM, so the agent can see and potentially leak anything stored there, including secrets in ",
          {:code, ".env"},
          " files and temporary artifacts. For stronger isolation from local files, use ",
          {:guide, "co:op", "coop"},
          "."
        ],
        [
          "The registered MCP launcher runs on the host with your permissions. Keep it and its environment file outside the shared project and do not let the agent edit them."
        ],
        [
          "We recommend reviewing the sandbox's network policy and allowing access only to the services the agent needs."
        ]
      ],
      rotation: nil
    },
    "nono" => %{
      title: "Limits & risks",
      risks: [
        [
          "The agent can see any file, secret, tool, or network destination allowed by the profile, including everything in its working directory."
        ],
        [
          "The agent can read the emisar key in its MCP configuration. Allow network access only to the services the agent needs."
        ],
        [
          "Review the profile after adding file, command, environment-variable, or network access."
        ]
      ],
      rotation: [
        "Rotate the key manually from ",
        {:agents, "AI agents"},
        ", replace it in the private agent configuration, and start a fresh nono session. Do not give the sandbox the whole credential directory to automate this."
      ]
    },
    "dev_containers" => %{
      title: "Limits & risks",
      risks: [
        [
          "The agent can see and potentially leak anything mounted into the container, including secrets in ",
          {:code, ".env"},
          " files and temporary artifacts. Mount only the files it needs. For stronger isolation from local files, use ",
          {:guide, "co:op", "coop"},
          "."
        ],
        [
          "VS Code can share Git credentials or forward an SSH agent into the container. Review its ",
          {:link, "credential-sharing settings",
           "https://code.visualstudio.com/remote/advancedcontainers/sharing-git-credentials"},
          " before starting the agent, and never mount the host's Docker socket."
        ],
        [
          "The default configuration does not restrict outbound network access. We recommend allowing access only to the services the agent needs."
        ]
      ],
      rotation: [
        "Keep the bridge's named volume when rebuilding the container so rotated credentials are retained. If you remove the volume or private configuration, create a fresh key from ",
        {:agents, "AI agents"},
        " and reconnect."
      ]
    }
  }

  @doc "The sandbox ids with shared copy, in no particular order."
  def ids, do: Map.keys(@sandboxes)

  @doc "The title, risks, and optional rotation paragraph for one sandbox id."
  def fetch!(id), do: Map.fetch!(@sandboxes, id)
end
