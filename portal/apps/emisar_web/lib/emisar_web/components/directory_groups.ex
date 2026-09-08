defmodule EmisarWeb.DirectoryGroups do
  @moduledoc "Bounded directory relationships for connection members."
  use Phoenix.Component
  import EmisarWeb.CoreComponents
  alias Emisar.SSO
  alias EmisarWeb.LiveTable

  def filters(base_filters, nil), do: base_filters

  def filters(base_filters, picker) do
    base_filters ++
      [
        %Emisar.Repo.Filter{
          name: :directory_group_id,
          title: "IdP group",
          type: {:list, :string},
          values: picker.options
        }
      ]
  end

  def load_filter(socket, selected, opts \\ [], search \\ nil, page \\ nil) do
    subject = socket.assigns.current_subject

    selected =
      if selected in [nil, ""] or is_binary(selected), do: selected, else: "__unavailable__"

    previous = socket.assigns[:directory_group_picker]

    {search, page} =
      if is_nil(search) and is_map(previous) and previous.selected == selected and
           previous.opts == opts do
        {previous.search, previous.page}
      else
        {search || "", page || []}
      end

    if SSO.subject_can_manage_sso?(subject) do
      group =
        case SSO.fetch_directory_group_facts(selected, subject, opts) do
          {:ok, group} -> group
          {:error, _} -> nil
        end

      read_opts =
        Keyword.merge(opts, filter: [search: search], page: Keyword.put(page, :limit, 10))

      {groups, metadata, error} =
        case SSO.list_directory_groups(subject, read_opts) do
          {:ok, groups, metadata} ->
            {groups, metadata, nil}

          {:error, _} ->
            {[], %Emisar.Repo.Paginator.Metadata{},
             "Couldn't load groups. Search again to retry."}
        end

      options = Enum.map(groups, &{&1.id, group_name(&1)})

      options =
        cond do
          selected in [nil, ""] -> options
          Enum.any?(groups, &(&1.id == selected)) -> options
          group -> [{group.id, group_name(group)} | options]
          is_binary(selected) -> [{selected, "Group unavailable"} | options]
          true -> options
        end

      assign(socket, :directory_group_picker, %{
        selected: selected,
        group: group,
        search: search,
        options: options,
        empty?: groups == [],
        error: error,
        metadata: metadata,
        opts: opts,
        page: page
      })
    else
      picker =
        if selected in [nil, ""] do
          nil
        else
          selected = if is_binary(selected), do: selected, else: "__unavailable__"

          %{
            selected: selected,
            group: nil,
            search: "",
            options: [{selected, "Group unavailable"}],
            empty?: false,
            error: "You don't have access to directory groups.",
            metadata: %Emisar.Repo.Paginator.Metadata{},
            opts: opts,
            page: []
          }
        end

      assign(socket, :directory_group_picker, picker)
    end
  end

  def search_filter(socket, %{
        "_target" => ["option_search", "directory_group_id"],
        "option_search" => %{"directory_group_id" => search}
      })
      when is_binary(search) do
    case socket.assigns.directory_group_picker do
      nil -> socket
      picker -> load_filter(socket, picker.selected, picker.opts, String.slice(search, 0, 200))
    end
  end

  def search_filter(socket, _params), do: socket

  def page_filter(socket, %{"field" => "directory_group_id", "direction" => "first"}) do
    case socket.assigns.directory_group_picker do
      nil -> socket
      picker -> load_filter(socket, picker.selected, picker.opts, picker.search, [])
    end
  end

  def page_filter(socket, %{"field" => "directory_group_id", "direction" => direction})
      when direction in ["next", "previous"] do
    case socket.assigns.directory_group_picker do
      nil ->
        socket

      picker ->
        cursor =
          if direction == "next",
            do: picker.metadata.next_page_cursor,
            else: picker.metadata.previous_page_cursor

        if cursor,
          do: load_filter(socket, picker.selected, picker.opts, picker.search, cursor: cursor),
          else: socket
    end
  end

  def page_filter(socket, _params), do: socket

  def init(socket) do
    socket
    |> assign(:member_group_summaries, %{})
    |> assign(:member_groups_error?, false)
    |> assign(:member_group_list, nil)
  end

  def load_summaries(socket, user_ids, opts \\ []) do
    case SSO.member_group_summaries(user_ids, socket.assigns.current_subject, opts) do
      {:ok, summaries} ->
        socket
        |> assign(:member_group_summaries, summaries)
        |> assign(:member_groups_error?, false)
        |> refresh_details()

      {:error, _} ->
        socket
        |> init()
        |> assign(
          :member_groups_error?,
          SSO.subject_can_manage_sso?(socket.assigns.current_subject)
        )
    end
  end

  defp refresh_details(socket) do
    case socket.assigns.member_group_list do
      nil ->
        socket

      list ->
        case Map.get(socket.assigns.member_group_summaries, list.user_id) do
          %{count: count} when count > 0 -> load_member_groups(socket, list, list.page)
          _ -> assign(socket, :member_group_list, nil)
        end
    end
  end

  def toggle_member_groups(socket, params, opts \\ [])

  def toggle_member_groups(socket, %{"user_id" => user_id}, opts) do
    cond do
      not Map.has_key?(socket.assigns.member_group_summaries, user_id) ->
        socket

      socket.assigns.member_group_list && socket.assigns.member_group_list.user_id == user_id ->
        assign(socket, :member_group_list, nil)

      true ->
        load_member_groups(socket, %{user_id: user_id, search: "", opts: opts, page: []}, [])
    end
  end

  def toggle_member_groups(socket, _params, _opts), do: socket

  def search_member_groups(socket, %{"search" => term}) when is_binary(term) do
    case socket.assigns.member_group_list do
      nil ->
        socket

      list ->
        if Map.has_key?(socket.assigns.member_group_summaries, list.user_id),
          do: load_member_groups(socket, %{list | search: String.slice(term, 0, 200)}, []),
          else: assign(socket, :member_group_list, nil)
    end
  end

  def search_member_groups(socket, _params), do: socket

  def page_member_groups(socket, %{"direction" => "first"}) do
    case socket.assigns.member_group_list do
      nil -> socket
      list -> load_member_groups(socket, list, [])
    end
  end

  def page_member_groups(socket, %{"direction" => direction})
      when direction in ["next", "previous"] do
    case socket.assigns.member_group_list do
      %{metadata: %{} = metadata} = list ->
        cursor =
          if direction == "next",
            do: metadata.next_page_cursor,
            else: metadata.previous_page_cursor

        if cursor, do: load_member_groups(socket, list, cursor: cursor), else: socket

      _ ->
        socket
    end
  end

  def page_member_groups(socket, _params), do: socket

  defp load_member_groups(socket, list, page) do
    if Map.has_key?(socket.assigns.member_group_summaries, list.user_id) do
      do_load_member_groups(socket, list, page)
    else
      assign(socket, :member_group_list, nil)
    end
  end

  defp do_load_member_groups(socket, list, page) do
    opts =
      Keyword.merge(list.opts, filter: [search: list.search], page: Keyword.put(page, :limit, 10))

    case SSO.list_member_groups(list.user_id, socket.assigns.current_subject, opts) do
      {:ok, groups, metadata} ->
        assign(
          socket,
          :member_group_list,
          Map.merge(list, %{groups: groups, metadata: metadata, page: page, error?: false})
        )

      {:error, _} ->
        assign(
          socket,
          :member_group_list,
          Map.merge(list, %{groups: [], metadata: nil, page: page, error?: true})
        )
    end
  end

  attr :id, :string, required: true
  attr :group, :map, required: true
  attr :path, :string, required: true
  attr :filter_params, :map, required: true
  attr :prefix, :string, default: ""

  def group_badge(assigns) do
    active? = assigns.filter_params["#{assigns.prefix}directory_group_id"] == assigns.group.id
    value = if active?, do: "", else: assigns.group.id

    assigns =
      assigns
      |> assign(:active?, active?)
      |> assign(
        :filter_path,
        LiveTable.filter_option_path(
          assigns.path,
          assigns.filter_params,
          :directory_group_id,
          value,
          assigns.prefix
        )
      )

    ~H"""
    <.link
      id={@id}
      patch={@filter_path}
      aria-current={if @active?, do: "true"}
      aria-label={
        if @active?,
          do: "Clear #{group_name(@group)} filter",
          else: "Filter members by #{group_name(@group)}"
      }
      class="inline-flex min-w-0 max-w-full items-center"
    >
      <.chip tone={if @active?, do: :brand, else: :neutral}>
        <span class="max-w-48 truncate">{group_name(@group)}</span>
      </.chip>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :user_id, :string, required: true
  attr :summary, :any, default: nil
  attr :list, :any, default: nil
  attr :error?, :boolean, default: false
  attr :path, :string, required: true
  attr :filter_params, :map, required: true
  attr :prefix, :string, default: ""
  attr :active_group, :any, default: nil

  def member_groups(assigns) do
    assigns =
      assign(assigns, :expanded?, assigns.list != nil and assigns.list.user_id == assigns.user_id)

    groups = if assigns.summary, do: assigns.summary.groups, else: []

    groups =
      if assigns.active_group && assigns.summary && assigns.summary.count > 0,
        do: Enum.take(Enum.uniq_by([assigns.active_group | groups], & &1.id), 3),
        else: groups

    assigns = assign(assigns, :visible_groups, groups)

    ~H"""
    <div :if={@error? or (@summary && @summary.count > 0)} id={@id} class="mt-1 min-w-0 text-xs">
      <div class="flex min-w-0 flex-wrap items-baseline gap-x-2 gap-y-1">
        <span class="text-[10px] uppercase tracking-wider text-zinc-400">IdP groups:</span>
        <span :if={@error?} class="text-zinc-400">Unavailable</span>
        <%= if @summary do %>
          <div :if={not @expanded?} class="flex min-w-0 flex-wrap items-center gap-1">
            <.group_badge
              :for={group <- @visible_groups}
              id={"#{@id}-#{group.id}"}
              group={group}
              path={@path}
              filter_params={@filter_params}
              prefix={@prefix}
            />
          </div>
          <.button
            :if={@summary.count > length(@summary.groups) or @expanded?}
            id={"#{@id}-toggle"}
            variant={:ghost}
            size={:sm}
            phx-click="toggle_member_groups"
            phx-value-user_id={@user_id}
            aria-expanded={to_string(@expanded?)}
            aria-controls={"#{@id}-list"}
          >
            {if @expanded?,
              do: "Close groups",
              else: "+#{@summary.count - length(@summary.groups)} groups"}
          </.button>
        <% end %>
      </div>
      <div :if={@expanded?} id={"#{@id}-list"} class="mt-2 space-y-3">
        <form
          id={"#{@id}-search-form"}
          phx-change="search_member_groups"
          phx-submit="search_member_groups"
        >
          <.input
            id={"#{@id}-search"}
            name="search"
            type="search"
            size={:compact}
            value={@list.search}
            placeholder="Search groups"
            aria-label="Search this member's groups"
            maxlength="200"
            phx-debounce="300"
          />
        </form>
        <p :if={@list.error?} role="status" class="text-zinc-400">
          Couldn't load groups. Search again to retry.
        </p>
        <p :if={not @list.error? and @list.groups == []} class="text-zinc-400">
          {if @list.metadata.count > 0,
            do: "This page changed as the directory synced.",
            else: "No matching groups."}
        </p>
        <div class="flex flex-wrap items-center gap-1">
          <.group_badge
            :for={group <- @list.groups}
            id={"#{@id}-expanded-#{group.id}"}
            group={group}
            path={@path}
            filter_params={@filter_params}
            prefix={@prefix}
          />
        </div>
        <nav :if={@list.metadata} aria-label="Member groups pages" class="flex items-center gap-3">
          <span class="tabular-nums text-zinc-400">{@list.metadata.count} groups</span>
          <.button
            :if={@list.groups == [] and @list.page != []}
            variant={:secondary}
            size={:sm}
            phx-click="page_member_groups"
            phx-value-direction="first"
          >Back to first page</.button>
          <.button
            :if={@list.metadata.previous_page_cursor}
            variant={:secondary}
            size={:sm}
            phx-click="page_member_groups"
            phx-value-direction="previous"
          >Previous</.button>
          <.button
            :if={@list.metadata.next_page_cursor}
            variant={:secondary}
            size={:sm}
            phx-click="page_member_groups"
            phx-value-direction="next"
          >Next</.button>
        </nav>
      </div>
    </div>
    """
  end

  def group_name(group),
    do: present(group[:display]) || present(group[:external_group_id]) || "Unnamed group"

  defp present(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp present(_), do: nil
end
