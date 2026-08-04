defmodule EmisarWeb.RunbookImportLive do
  @moduledoc """
  Imports one bounded canonical runbook JSON definition as an editable draft.
  """
  use EmisarWeb, :live_view
  alias Emisar.Runbooks
  alias EmisarWeb.CoreComponents

  @empty_params %{"title" => "", "json" => ""}

  def mount(_params, _session, socket) do
    if Runbooks.subject_can_manage_runbooks?(socket.assigns.current_subject) do
      {:ok,
       socket
       |> assign(:page_title, "Import runbook")
       |> assign(:import_file, nil)
       |> assign(:title_errors, [])
       |> assign(:json_errors, [])
       |> assign(:source_errors, [])
       |> assign_form(@empty_params)
       |> allow_upload(:runbook_json,
         accept: ~w(.json),
         max_entries: 1,
         max_file_size: Runbooks.definition_limit!(:max_definition_bytes),
         auto_upload: true,
         progress: &handle_upload_progress/3
       )}
    else
      {:ok,
       socket
       |> put_flash(:error, "You don't have permission to import runbooks.")
       |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}/runbooks")}
    end
  end

  def handle_event("validate_import", %{"import" => params}, socket) do
    params = normalize_params(params)
    json = params["json"] || ""

    {:noreply,
     socket
     |> assign_form(params)
     |> assign(:title_errors, [])
     |> assign(:json_errors, [])
     |> assign(:source_errors, conflicting_source_errors(socket.assigns.import_file, json))}
  end

  def handle_event("validate_import", _params, socket) do
    {:noreply, assign_form(socket, @empty_params)}
  end

  def handle_event("clear_import_file", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:runbook_json, ref)
     |> assign(:import_file, nil)
     |> assign(:source_errors, [])}
  end

  def handle_event("clear_import_file", _params, socket) do
    {:noreply,
     socket
     |> assign(:import_file, nil)
     |> assign(:source_errors, [])}
  end

  def handle_event("import_runbook", %{"import" => params}, socket) do
    params = normalize_params(params)
    title = String.trim(params["title"] || "")
    pasted_json = params["json"] || ""
    file = socket.assigns.import_file

    socket =
      socket
      |> assign_form(params)
      |> assign(:title_errors, required_title_errors(title))
      |> assign(:json_errors, [])
      |> assign(:source_errors, source_errors(file, pasted_json))

    cond do
      socket.assigns.source_errors != [] ->
        {:noreply, socket}

      socket.assigns.title_errors != [] ->
        encoded_definition = if file, do: file.content, else: pasted_json
        {:noreply, validate_definition(socket, encoded_definition)}

      true ->
        encoded_definition = if file, do: file.content, else: pasted_json
        import(socket, title, encoded_definition)
    end
  end

  def handle_event("import_runbook", _params, socket) do
    {:noreply,
     socket
     |> assign_form(@empty_params)
     |> assign(:title_errors, required_title_errors(""))
     |> assign(:json_errors, [])
     |> assign(:source_errors, source_errors(nil, ""))}
  end

  # Phoenix's internal upload writer creates this temporary path and passes it
  # through consume_uploaded_entry; the browser never supplies a filesystem path.
  # sobelow_skip ["Traversal.FileModule"]
  defp handle_upload_progress(:runbook_json, entry, socket) do
    if entry.done? do
      content =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          File.read(path)
        end)

      params = socket.assigns.import_form.params
      title = params["title"] || ""

      params =
        if String.trim(title) == "" do
          Map.put(params, "title", title_from_filename(entry.client_name))
        else
          params
        end

      {:noreply,
       socket
       |> assign_form(params)
       |> assign(:import_file, %{name: entry.client_name, content: content})
       |> assign(:json_errors, [])
       |> assign(
         :source_errors,
         conflicting_source_errors(%{name: entry.client_name}, params["json"] || "")
       )}
    else
      {:noreply, socket}
    end
  end

  defp import(socket, title, encoded_definition) do
    case Runbooks.import_runbook(title, encoded_definition, socket.assigns.current_subject) do
      {:ok, runbook} ->
        {:noreply,
         socket
         |> put_flash(:info, "Runbook imported as a draft.")
         |> push_navigate(
           to: ~p"/app/#{socket.assigns.current_account}/runbooks/#{runbook.id}/edit"
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_changeset_errors(socket, changeset)}

      {:error, issues} when is_list(issues) ->
        {:noreply, assign(socket, :json_errors, Enum.map(issues, &issue_message/1))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not import this runbook.")}
    end
  end

  defp validate_definition(socket, encoded_definition) do
    case Runbooks.decode_definition_json(encoded_definition) do
      {:ok, _definition} -> socket
      {:error, issues} -> assign(socket, :json_errors, Enum.map(issues, &issue_message/1))
    end
  end

  defp assign_changeset_errors(socket, changeset) do
    errors = Ecto.Changeset.traverse_errors(changeset, &CoreComponents.translate_error/1)

    case Map.get(errors, :title, []) do
      [] ->
        assign(
          socket,
          :title_errors,
          ["A runbook with this title already exists. Choose another title."]
        )

      title_errors ->
        assign(socket, :title_errors, title_errors)
    end
  end

  defp source_errors(file, pasted_json) do
    case {file, pasted_json} do
      {nil, ""} -> ["Choose a JSON file or paste the canonical JSON."]
      {%{}, ""} -> []
      {nil, _json} -> []
      {%{}, _json} -> ["Use either the selected file or pasted JSON, not both."]
    end
  end

  defp conflicting_source_errors(file, pasted_json) do
    if file && pasted_json != "",
      do: ["Use either the selected file or pasted JSON, not both."],
      else: []
  end

  defp required_title_errors(""), do: ["Title is required."]
  defp required_title_errors(_title), do: []

  defp issue_message(%{message: message, path: path}) when path not in [nil, ""],
    do: "#{message} at #{path}"

  defp issue_message(%{message: message}), do: message

  defp title_from_filename(filename) do
    filename
    |> Path.basename()
    |> Path.rootname()
    |> String.replace(~r/[-_]+/, " ")
    |> String.trim()
    |> String.capitalize()
  end

  defp assign_form(socket, params),
    do: assign(socket, :import_form, to_form(params, as: "import"))

  defp normalize_params(%{} = params) do
    %{
      "title" => binary_param(params["title"]),
      "json" => binary_param(params["json"])
    }
  end

  defp normalize_params(_params), do: @empty_params

  defp binary_param(value) when is_binary(value), do: value
  defp binary_param(_value), do: ""

  defp upload_error(:too_large), do: "The JSON file must be 64 KB or smaller."
  defp upload_error(:not_accepted), do: "Choose a .json file."
  defp upload_error(:too_many_files), do: "Choose one JSON file."
  defp upload_error(_reason), do: "The JSON file could not be uploaded."

  def render(assigns) do
    ~H"""
    <.dashboard_shell
      current_subject={@current_subject}
      current_membership={@current_membership}
      pending_approvals_count={@pending_approvals_count}
      pending_packs_count={@pending_packs_count}
      fleet_all_offline?={@fleet_all_offline?}
      no_agents?={@no_agents?}
      onboarding_incomplete?={@onboarding_incomplete?}
      current_user={@current_user}
      current_account={@current_account}
      switchable_accounts={@switchable_accounts}
      flash={@flash}
      section={:runbooks}
      width={:table}
    >
      <:title>
        <.back_link navigate={~p"/app/#{@current_account}/runbooks"}>Runbooks</.back_link>
        Import runbook
      </:title>

      <div id="runbook-import" class="max-w-3xl">
        <.simple_form
          for={@import_form}
          id="runbook-import-form"
          phx-change="validate_import"
          phx-submit="import_runbook"
        >
          <div>
            <.section_header title="Import canonical JSON">
              <:subtitle>The definition becomes an editable draft in this account.</:subtitle>
            </.section_header>
          </div>

          <.input
            type="text"
            id="runbook-import-title"
            name="import[title]"
            value={@import_form.params["title"]}
            label="Title"
            errors={@title_errors}
            maxlength="80"
            autocomplete="off"
            placeholder="Database failover"
          />

          <div>
            <.label for={@uploads.runbook_json.ref}>JSON file</.label>
            <label
              for={@uploads.runbook_json.ref}
              phx-drop-target={@uploads.runbook_json.ref}
              class="runbook-import-dropzone mt-2 flex min-h-36 cursor-pointer flex-col items-center justify-center rounded-xl border border-dashed border-zinc-700 px-6 py-8 text-center transition hover:border-zinc-500 hover:bg-zinc-900/30"
            >
              <.icon name="hero-arrow-up-tray" class="h-6 w-6 text-zinc-400" />
              <span class="mt-3 text-sm font-medium text-zinc-200">
                Drop a JSON file here or choose one
              </span>
              <span class="mt-1 text-xs text-zinc-400">.json · 64 KB maximum</span>
              <.live_file_input
                upload={@uploads.runbook_json}
                class="sr-only"
                aria-label="Choose canonical runbook JSON"
              />
            </label>

            <.error :for={error <- upload_errors(@uploads.runbook_json)}>
              {upload_error(error)}
            </.error>

            <div :for={entry <- @uploads.runbook_json.entries} class="mt-3">
              <div class="flex items-center justify-between gap-4 text-sm">
                <div class="min-w-0">
                  <div class="truncate text-zinc-200">{entry.client_name}</div>
                  <div class="mt-0.5 text-xs tabular-nums text-zinc-400">
                    Uploading {entry.progress}%
                  </div>
                </div>
                <.button
                  type="button"
                  variant={:ghost}
                  size={:sm}
                  phx-click="clear_import_file"
                  phx-value-ref={entry.ref}
                >
                  Remove
                </.button>
              </div>
              <.error :for={error <- upload_errors(@uploads.runbook_json, entry)}>
                {upload_error(error)}
              </.error>
            </div>

            <div
              :if={@import_file}
              id="selected-runbook-json"
              class="mt-3 flex items-center justify-between gap-4 rounded-lg border border-zinc-800 px-4 py-3"
            >
              <div class="min-w-0">
                <div class="truncate text-sm text-zinc-200">{@import_file.name}</div>
                <div class="mt-0.5 text-xs text-zinc-400">Ready to import</div>
              </div>
              <.button
                type="button"
                variant={:ghost}
                size={:sm}
                phx-click="clear_import_file"
              >
                Remove
              </.button>
            </div>
          </div>

          <.or_separator label="or paste JSON" class="!my-2" />

          <.input
            type="textarea"
            id="runbook-import-json"
            name="import[json]"
            value={@import_form.params["json"]}
            label="Canonical JSON"
            errors={@json_errors}
            maxlength={Runbooks.definition_limit!(:max_definition_bytes)}
            rows="14"
            spellcheck="false"
            class="min-h-72 font-mono text-xs leading-5"
            placeholder={
              ~s({"schema_version": 1, "context_markdown": "", "inputs": [], "stages": []})
            }
          />

          <.error :for={error <- @source_errors}>{error}</.error>

          <:actions>
            <.button id="runbook-import-submit" phx-disable-with="Importing…">
              Import as draft
            </.button>
          </:actions>
        </.simple_form>
      </div>
    </.dashboard_shell>
    """
  end
end
