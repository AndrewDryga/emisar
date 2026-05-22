defmodule EmisarWeb.RunbookEditorLive do
  use EmisarWeb, :live_view

  alias Emisar.Runbooks
  alias Emisar.Runbooks.Runbook
  alias EmisarWeb.Permissions

  @example_steps [
    %{
      "id" => "step1",
      "action_id" => "linux.uptime",
      "agent_selector" => %{"group" => "cassandra-us-east1"},
      "args" => %{}
    },
    %{
      "id" => "step2",
      "kind" => "assert",
      "expression" => "step1.exit_code == 0"
    }
  ]

  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New runbook")
    |> assign(:runbook, nil)
    |> assign(:title, "")
    |> assign(:slug, "")
    |> assign(:description, "")
    |> assign(:steps_json, Jason.encode!(@example_steps, pretty: true))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    account_id = socket.assigns.current_account.id

    case Runbooks.get_runbook(account_id, id) do
      nil ->
        socket
        |> put_flash(:error, "Runbook not found.")
        |> push_navigate(to: ~p"/app/runbooks")

      runbook ->
        steps = get_in(runbook.definition || %{}, ["steps"]) || []

        socket
        |> assign(:page_title, "Edit runbook")
        |> assign(:runbook, runbook)
        |> assign(:title, runbook.title || "")
        |> assign(:slug, runbook.slug || "")
        |> assign(:description, runbook.description || "")
        |> assign(:steps_json, Jason.encode!(steps, pretty: true))
    end
  end

  def handle_event("validate", params, socket) do
    {:noreply,
     socket
     |> assign(:title, params["title"] || "")
     |> assign(:slug, params["slug"] || "")
     |> assign(:description, params["description"] || "")
     |> assign(:steps_json, params["steps_json"] || socket.assigns.steps_json)}
  end

  def handle_event("save", params, socket) do
    Permissions.gated(socket, :manage_runbooks, fn s ->
      save(s, params, publish?: false)
    end)
  end

  def handle_event("publish", params, socket) do
    Permissions.gated(socket, :manage_runbooks, fn s ->
      save(s, params, publish?: true)
    end)
  end

  defp save(socket, params, publish?: publish?) do
    title = params["title"] || ""
    slug = (params["slug"] || "") |> derive_slug(title)
    description = params["description"] || ""
    steps_json = params["steps_json"] || "[]"

    socket =
      socket
      |> assign(:title, title)
      |> assign(:slug, slug)
      |> assign(:description, description)
      |> assign(:steps_json, steps_json)

    with {:ok, steps} <- decode_steps(steps_json),
         attrs <- base_attrs(title, slug, description, steps, publish?),
         {:ok, runbook} <- persist(socket, attrs),
         {:ok, runbook} <- maybe_publish(runbook, publish?: publish?) do
      {:noreply,
       socket
       |> put_flash(:info, success_message(runbook, publish?))
       |> push_navigate(to: ~p"/app/runbooks")}
    else
      {:error, :invalid_json, msg} ->
        {:noreply, put_flash(socket, :error, "Invalid steps JSON: #{msg}")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, put_flash(socket, :error, "Could not save runbook: #{format_errors(cs)}")}
    end
  end

  defp base_attrs(title, slug, description, steps, publish?) do
    %{
      "title" => title,
      "name" => title,
      "slug" => slug,
      "description" => description,
      "definition" => %{"steps" => steps},
      "status" => if(publish?, do: "published", else: "draft")
    }
  end

  defp persist(%{assigns: %{runbook: nil}} = socket, attrs) do
    Runbooks.create_runbook(
      socket.assigns.current_account.id,
      socket.assigns.current_user.id,
      attrs
    )
  end

  defp persist(%{assigns: %{runbook: %Runbook{status: "published"} = rb}} = socket, attrs) do
    Runbooks.save_new_version(rb, attrs, socket.assigns.current_user.id)
  end

  defp persist(%{assigns: %{runbook: %Runbook{} = rb}} = socket, attrs) do
    Runbooks.save_new_version(rb, attrs, socket.assigns.current_user.id)
  end

  defp maybe_publish(%Runbook{} = rb, publish?: true), do: Runbooks.publish(rb)
  defp maybe_publish(%Runbook{} = rb, publish?: false), do: {:ok, rb}

  defp success_message(_, true), do: "Runbook published."
  defp success_message(%{version: v}, false) when v > 1, do: "Draft v#{v} saved."
  defp success_message(_, false), do: "Draft saved."

  defp derive_slug(slug, title) do
    case String.trim(slug || "") do
      "" -> slugify(title)
      s -> s
    end
  end

  defp slugify(title) do
    title
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 79)
  end

  defp decode_steps(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, :invalid_json, "must be a JSON array of steps"}
      {:error, %Jason.DecodeError{} = err} -> {:error, :invalid_json, Exception.message(err)}
    end
  end

  defp format_errors(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field}: #{msg}" end)
    |> Enum.join("; ")
  end

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_user={@current_user}
      current_account={@current_account}
      flash={@flash}
      section={:runbooks}
    >
      <:title>
        <%= if @runbook do %>
          Edit runbook <span class="font-mono text-base text-zinc-400">{@runbook.slug}</span>
          <span class="ml-2 text-sm font-normal text-zinc-500">v{@runbook.version}</span>
        <% else %>
          New runbook
        <% end %>
      </:title>
      <:actions>
        <.link
          navigate={~p"/app/runbooks"}
          class="rounded-lg border border-zinc-800 px-3 py-1.5 text-sm font-medium text-zinc-300 hover:bg-zinc-900"
        >
          Cancel
        </.link>
      </:actions>

      <form
        phx-change="validate"
        phx-submit="save"
        id="runbook-form"
        class="grid grid-cols-1 gap-6 lg:grid-cols-3"
      >
        <.card class="lg:col-span-2">
          <.section_header title="Steps" />
          <p class="mt-1 text-xs text-zinc-500">
            JSON array of step descriptors. Each step has an <code class="text-indigo-300">id</code>;
            action steps add <code>action_id</code>, <code>agent_selector</code>, and
            <code>args</code>; control steps use <code>kind</code>
            (e.g. <code>assert</code>) with an <code>expression</code>.
          </p>

          <textarea
            name="steps_json"
            rows="22"
            spellcheck="false"
            class="mt-4 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
          ><%= @steps_json %></textarea>

          <div class="mt-6 flex items-center justify-end gap-3">
            <button
              type="submit"
              class="rounded-lg border border-zinc-800 px-4 py-2 text-sm font-medium text-zinc-200 hover:bg-zinc-900"
              phx-disable-with="Saving..."
            >
              Save draft
            </button>
            <.button type="button" phx-click="publish" phx-disable-with="Publishing...">
              Publish
            </.button>
          </div>
        </.card>

        <div class="space-y-6">
          <.card>
            <.section_header title="Metadata" />

            <div class="mt-4 space-y-4">
              <div>
                <label class="block text-xs font-medium text-zinc-400" for="runbook_title">
                  Title
                </label>
                <input
                  type="text"
                  id="runbook_title"
                  name="title"
                  value={@title}
                  required
                  placeholder="e.g. Cassandra: rolling repair"
                  class="mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
                />
              </div>

              <div>
                <label class="block text-xs font-medium text-zinc-400" for="runbook_slug">
                  Slug
                </label>
                <input
                  type="text"
                  id="runbook_slug"
                  name="slug"
                  value={@slug}
                  placeholder="auto-generated from title if blank"
                  class="mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 font-mono text-xs text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
                />
                <p class="mt-1 text-xs text-zinc-500">
                  Lowercase, alphanumeric with dashes / underscores.
                </p>
              </div>

              <div>
                <label class="block text-xs font-medium text-zinc-400" for="runbook_description">
                  Description
                </label>
                <textarea
                  id="runbook_description"
                  name="description"
                  rows="4"
                  placeholder="Optional human-readable summary."
                  class="mt-1 block w-full rounded-lg border-0 bg-zinc-900 px-3 py-2 text-sm text-zinc-100 ring-1 ring-zinc-800 focus:ring-indigo-500"
                ><%= @description %></textarea>
              </div>
            </div>
          </.card>

          <%= if @runbook do %>
            <.card>
              <dl class="space-y-2 text-xs text-zinc-400">
                <.kv label="Current version">v{@runbook.version}</.kv>
                <.kv label="Status"><.status_badge status={@runbook.status} /></.kv>
                <.kv label="Saving creates">v{@runbook.version + 1}</.kv>
              </dl>
              <p :if={@runbook.status == "published"} class="mt-4 text-xs text-zinc-500">
                Published runbooks are immutable — saving creates a new draft version.
              </p>
            </.card>
          <% end %>
        </div>
      </form>
    </.dashboard_shell>
    """
  end
end
