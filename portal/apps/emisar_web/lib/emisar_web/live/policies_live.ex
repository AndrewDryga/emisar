defmodule EmisarWeb.PoliciesLive do
  @moduledoc """
  Policy editor. One page, everything live-editable:

    * **Default policy** — the base (the account-scoped policy, `scope_type:
      :account`, labeled "Default policy" in the UI). Risk-tier defaults +
      per-action overrides. Applies to every runner.
    * **Targeted rulesets** — an inline list of per-runner / per-group
      policies. Add one, pick a runner or group, edit its rules. A ruleset
      **replaces** the default policy for that target (most specific wins:
      runner > group > account), it doesn't layer on top — so what a unit
      shows is exactly what runs there.

  Each editor unit is its own form with its own Save (a scoped ruleset is its
  own policy row, version, and audit entry). Events carry an `editor`
  discriminator — `"account"` or a ruleset uid — so one set of handlers
  drives every unit.
  """
  use EmisarWeb, :live_view
  alias Emisar.Policies
  alias EmisarWeb.{LiveTable, Permissions}

  # Non-breaking spaces so the browser keeps the indent (ASCII whitespace in an
  # <option> is stripped) — nests runners under their group in the target picker.
  @runner_indent "    "

  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        page_title: "Policy",
        loading?: not connected?(socket),
        load_error?: false,
        account_error?: false,
        rulesets: [],
        summaries: [],
        metadata: %Emisar.Repo.Paginator.Metadata{},
        filter_params: %{},
        preview_active: nil,
        preview_cancel: nil,
        preview_queue: []
      )
      |> stream(:policies, [])

    # Gate BEFORE any policy read: a role without view_policies must see
    # nothing, not the account posture with only the scoped read errored.
    cond do
      not Policies.subject_can_view_policies?(socket.assigns.current_subject) ->
        {:ok,
         socket
         |> put_flash(:error, "You don't have access to policies.")
         |> push_navigate(to: ~p"/app/#{socket.assigns.current_account}")}

      connected?(socket) ->
        {:ok, load_all(socket)}

      true ->
        {:ok, socket}
    end
  end

  def handle_params(params, _uri, socket) do
    if connected?(socket) and not is_nil(socket.assigns[:account]) do
      socket =
        if policy_cursor(params) != policy_cursor(socket.assigns.filter_params) or
             socket.assigns.loading?, do: load_summaries(socket, params), else: socket

      socket =
        Enum.reduce(socket.assigns.rulesets, socket, fn editor, socket ->
          if is_nil(editor.policy) and
               target_cursor(params, editor.uid) !=
                 target_cursor(socket.assigns.filter_params, editor.uid),
             do: load_target_options(socket, editor.uid, params),
             else: socket
        end)

      {:noreply, assign(socket, filter_params: params, loading?: false)}
    else
      {:noreply, socket}
    end
  end

  defp load_all(socket) do
    subject = socket.assigns.current_subject

    {account_policy, account_error?} =
      case Policies.fetch_policy(subject) do
        {:ok, policy} -> {policy, false}
        {:error, :not_found} -> {nil, false}
        {:error, _} -> {nil, true}
      end

    socket
    |> assign(:loading?, not account_error?)
    |> assign(:account_error?, account_error?)
    |> refresh_management_capabilities()
    |> assign(:account, if(account_error?, do: nil, else: build_account_editor(account_policy)))
    |> refresh_target_availability()
    |> schedule_preview("account", 0)
  end

  defp refresh_management_capabilities(socket) do
    targets =
      Enum.flat_map(socket.assigns.rulesets, fn editor ->
        selected =
          if editor.scope_type in [:runner, :group],
            do: [{editor.scope_type, editor.scope_value}],
            else: []

        options =
          for option <- Map.get(editor, :target_options, []) do
            {if(option.scope_type == "runner", do: :runner, else: :group), option.scope_value}
          end

        selected ++ options
      end)

    capabilities =
      Policies.policy_management_capabilities(socket.assigns.current_subject, targets)

    assign(socket,
      can_manage?: capabilities.can_manage?,
      has_runner_access?: capabilities.has_runner_access?,
      can_manage_scoped?: capabilities.can_manage_scoped?,
      can_manage_account?: capabilities.can_manage_account?,
      target_management: capabilities.targets
    )
  end

  defp load_summaries(socket, params, keep_uid \\ nil) do
    opts = LiveTable.params_to_opts(params, [], prefix: "policies_")

    case Policies.list_scoped_policy_summaries(socket.assigns.current_subject, opts) do
      {:ok, summaries, metadata} ->
        ids = MapSet.new(summaries, & &1.id)

        socket =
          Enum.reduce(socket.assigns.rulesets, socket, fn editor, socket ->
            if editor.policy && editor.uid != keep_uid && not MapSet.member?(ids, editor.uid) &&
                 not editor_dirty?(editor), do: drop_editor(socket, editor.uid), else: socket
          end)

        socket
        |> assign(summaries: summaries, metadata: metadata, load_error?: false)
        |> stream(:policies, summaries, reset: true)

      {:error, _} ->
        socket |> assign(summaries: [], load_error?: true) |> stream(:policies, [], reset: true)
    end
  end

  defp policy_cursor(params), do: {params["policies_after"], params["policies_before"]}

  defp target_cursor(params, uid),
    do: {params["target_#{uid}_after"], params["target_#{uid}_before"]}

  defp build_account_editor(policy) do
    rules = (policy && policy.rules) || Policies.default_rules()
    input = Policies.editor_input(rules)

    Map.merge(input, %{
      uid: "account",
      scope_type: :account,
      scope_value: "",
      show_override_errors?: false,
      # Snapshot of the saved rules: editor_dirty?/1 compares the live edits to
      # this, so reverting a change back clears the Save button (not a one-way flag).
      baseline_rules: stored_baseline(policy, input),
      policy: policy,
      rules_errors: [],
      preview: :pending,
      preview_generation: nil,
      preview_timer: nil
    })
  end

  defp build_ruleset_editor(%Policies.Policy{} = policy) do
    input = Policies.editor_input(policy.rules || Policies.default_rules())

    Map.merge(input, %{
      uid: policy.id,
      scope_type: policy.scope_type,
      scope_value: policy.scope_value,
      show_override_errors?: false,
      baseline_rules: stored_baseline(policy, input),
      policy: policy,
      rules_errors: [],
      target_label: policy.scope_value,
      preview: :pending,
      preview_generation: nil,
      preview_timer: nil
    })
  end

  # A blank, not-yet-targeted ruleset, seeded from the default policy so the
  # operator tweaks the live posture rather than starting from an empty one —
  # important under replace-semantics, where a ruleset that dropped the
  # account's deny-overrides would silently widen access for that target.
  defp new_ruleset(account) do
    input = policy_input(account)

    Map.merge(input, %{
      uid: "new-" <> Integer.to_string(System.unique_integer([:positive])),
      scope_type: nil,
      scope_value: "",
      show_override_errors?: false,
      baseline_rules: Policies.build_rules(input),
      policy: nil,
      rules_errors: [],
      target_label: "",
      target_search: "",
      target_options: [],
      target_metadata: %Emisar.Repo.Paginator.Metadata{},
      target_error: nil,
      selected_target: nil,
      preview: :pending,
      preview_generation: nil,
      preview_timer: nil
    })
  end

  defp stored_baseline(nil, input), do: Policies.build_rules(input)
  defp stored_baseline(%Policies.Policy{rules: rules}, _input), do: rules

  # -- Events ---------------------------------------------------------

  # An unavailable default is not the implicit default of an unconfigured
  # account. Never seed drafts or compare approval gates against invented rules.
  def handle_event(_event, _params, %{assigns: %{account_error?: true}} = socket),
    do: {:noreply, socket}

  def handle_event("open_ruleset", %{"uid" => uid}, socket) when is_binary(uid) do
    if find_ruleset(socket, uid) do
      {:noreply, socket}
    else
      case Policies.fetch_scoped_policy_by_id(uid, socket.assigns.current_subject) do
        {:ok, policy} ->
          summary = Enum.find(socket.assigns.summaries, &(&1.id == uid))

          editor = %{
            build_ruleset_editor(policy)
            | target_label: if(summary, do: summary.target_label, else: policy.scope_value)
          }

          {:noreply,
           socket
           |> assign(:rulesets, socket.assigns.rulesets ++ [editor])
           |> refresh_management_capabilities()
           |> schedule_preview(uid, 0)}

        {:error, _} ->
          {:noreply,
           put_flash(socket, :error, "Couldn't open this ruleset. Your access may have changed.")}
      end
    end
  end

  def handle_event("open_ruleset", _params, socket), do: {:noreply, socket}

  def handle_event("close_ruleset", %{"uid" => uid}, socket) do
    case find_ruleset(socket, uid) do
      nil ->
        {:noreply, socket}

      editor ->
        if editor_dirty?(editor) do
          {:noreply, put_flash(socket, :error, "Save your changes before closing this ruleset.")}
        else
          {:noreply, drop_editor(socket, uid)}
        end
    end
  end

  def handle_event("close_ruleset", _params, socket), do: {:noreply, socket}

  def handle_event("search_targets", %{"uid" => uid, "search" => search}, socket)
      when is_binary(uid) do
    case find_ruleset(socket, uid) do
      %{policy: nil} ->
        params =
          Map.drop(socket.assigns.filter_params, ["target_#{uid}_after", "target_#{uid}_before"])

        {:noreply, load_target_options(socket, uid, params, search)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("search_targets", _params, socket), do: {:noreply, socket}

  def handle_event("retry_preview", %{"editor" => uid}, socket) when is_binary(uid),
    do: {:noreply, schedule_preview(socket, uid, 0)}

  def handle_event("retry_preview", _params, socket), do: {:noreply, socket}

  def handle_event("form_change", %{"editor" => editor_id, "policy" => params}, socket),
    do: {:noreply, apply_policy_params(socket, editor_id, params)}

  # A crafted event that drops a required key would otherwise match no clause
  # and crash the socket, taking the page's unsaved state with it. Every
  # mutating handler on this page ends in this no-op.
  def handle_event("form_change", _params, socket), do: {:noreply, socket}

  def handle_event("add_override", %{"editor" => editor_id}, socket) do
    {:noreply,
     update_editor(socket, editor_id, fn editor ->
       if length(editor.overrides) < 200,
         do: %{editor | overrides: editor.overrides ++ [Policies.empty_override()]},
         else: editor
     end)}
  end

  def handle_event("add_override", _params, socket), do: {:noreply, socket}

  def handle_event("remove_override", %{"editor" => editor_id, "index" => idx}, socket)
      when is_binary(editor_id) and is_binary(idx) do
    case Integer.parse(idx) do
      {i, _} ->
        {:noreply,
         update_editor(socket, editor_id, fn editor ->
           %{editor | overrides: List.delete_at(editor.overrides, i)}
         end)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_override", _params, socket), do: {:noreply, socket}

  def handle_event("add_ruleset", _params, socket) do
    socket = refresh_target_availability(socket)

    if Policies.subject_can_manage_scoped_policies?(socket.assigns.current_subject) and
         socket.assigns.target_available == {:ok, true} do
      editor = new_ruleset(socket.assigns.account)

      {:noreply,
       socket
       |> assign(:rulesets, socket.assigns.rulesets ++ [editor])
       |> load_target_options(editor.uid, socket.assigns.filter_params)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("set_target", %{"uid" => uid, "target" => target}, socket)
      when is_binary(uid) and is_binary(target) do
    case find_ruleset(socket, uid) do
      %{policy: nil} -> {:noreply, select_target(socket, uid, parse_target(target))}
      _ -> {:noreply, socket}
    end
  end

  def handle_event("set_target", _params, socket), do: {:noreply, socket}

  def handle_event("remove_ruleset", %{"uid" => uid}, socket) do
    case find_ruleset(socket, uid) do
      # Saved ruleset — deleting it is a real mutation, so gate + audit.
      %{policy: %Policies.Policy{} = policy} ->
        Permissions.gated(
          socket,
          Policies.subject_can_manage_scoped_policies?(socket.assigns.current_subject),
          &delete_ruleset(&1, policy, uid)
        )

      # Not-yet-saved card — just drop it from the page.
      %{} ->
        {:noreply, socket |> drop_editor(uid) |> refresh_target_availability()}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("remove_ruleset", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"editor" => editor_id} = params, socket) do
    Permissions.gated(
      socket,
      subject_can_save_editor?(socket.assigns.current_subject, editor_id),
      fn socket ->
        socket = apply_policy_params(socket, editor_id, params["policy"])
        save_editor(socket, get_editor(socket, editor_id))
      end
    )
  end

  def handle_event("save", _params, socket), do: {:noreply, socket}

  defp subject_can_save_editor?(subject, "account"),
    do: Policies.subject_can_manage_account_policy?(subject)

  defp subject_can_save_editor?(subject, _editor_id),
    do: Policies.subject_can_manage_scoped_policies?(subject)

  defp save_editor(socket, %{scope_type: :account} = editor),
    do: persist(socket, editor, &Policies.save_rules/2)

  # Scope ownership is the context's call: `Policies.save_scoped_rules/4` rejects
  # a runner or group outside the subject's own fleet (a crafted `set_target`
  # event can carry either — IL-15); `persist_rules` maps the denial.
  defp save_editor(socket, %{scope_type: scope_type, scope_value: value} = editor)
       when scope_type in [:runner, :group] and is_binary(value) and value != "" do
    persist(socket, editor, fn rules, subject ->
      Policies.save_scoped_rules(rules, scope_type, value, subject)
    end)
  end

  defp save_editor(socket, _editor),
    do: {:noreply, put_flash(socket, :error, "Choose a runner or group for this ruleset first.")}

  defp persist(socket, editor, save_fun) do
    if Enum.any?(editor.overrides, &partial_override?/1) do
      {:noreply,
       update_editor(socket, editor.uid, fn editor ->
         %{editor | show_override_errors?: true}
       end)}
    else
      persist_rules(socket, editor, save_fun)
    end
  end

  defp persist_rules(socket, editor, save_fun) do
    rules = Policies.build_rules(policy_input(editor))

    case save_fun.(rules, socket.assigns.current_subject) do
      {:ok, policy} ->
        message =
          if editor.scope_type == :account, do: "Default policy saved.", else: "Ruleset saved."

        {:noreply, socket |> put_flash(:info, message) |> replace_saved(editor.uid, policy)}

      # The UI prevents invalid policies (constrained selects + monotonic
      # enforcement + partial rows blocked + untouched blank rows dropped), so
      # this is a defensive net: show the rules-level error inline on the card
      # it belongs to, not a flash.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         update_editor(socket, editor.uid, fn editor ->
           %{editor | rules_errors: changeset_rules_errors(changeset)}
         end)}

      {:error, :runner_not_found} ->
        {:noreply, put_flash(socket, :error, "That runner isn't in your fleet.")}

      {:error, :group_not_found} ->
        {:noreply, put_flash(socket, :error, "That group isn't in your fleet.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't save your changes. Try again.")}
    end
  end

  # Swap the just-saved editor for one rebuilt from the returned row (a new
  # ruleset's uid flips from `new-…` to the policy id), leaving every other
  # card's in-progress edits untouched — no full reload, no lost work.
  # Only this editor gets a fresh, bounded preview; sibling drafts stay intact.
  defp replace_saved(socket, "account", policy) do
    socket
    |> cancel_preview("account")
    |> assign(:account, build_account_editor(policy))
    |> schedule_preview("account", 0)
  end

  defp replace_saved(socket, old_uid, policy) do
    previous = find_ruleset(socket, old_uid)
    rebuilt = %{build_ruleset_editor(policy) | target_label: previous.target_label}
    socket = cancel_preview(socket, old_uid)

    rulesets =
      Enum.map(socket.assigns.rulesets, fn ruleset ->
        if ruleset.uid == old_uid, do: rebuilt, else: ruleset
      end)

    socket
    |> assign(:rulesets, rulesets)
    |> refresh_target_availability()
    |> refresh_open_target_options()
    |> load_summaries(socket.assigns.filter_params, policy.id)
    |> schedule_preview(policy.id, 0)
  end

  defp delete_ruleset(socket, policy, uid) do
    case Policies.delete_scoped_policy(policy, socket.assigns.current_subject) do
      {:ok, _deleted} ->
        {:noreply,
         socket
         |> put_flash(:info, "Ruleset removed.")
         |> drop_editor(uid)
         |> refresh_target_availability()
         |> refresh_open_target_options()
         |> load_summaries(socket.assigns.filter_params)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't remove this ruleset. Try again.")}
    end
  end

  # -- Editor state ---------------------------------------------------

  defp get_editor(socket, "account"), do: socket.assigns.account
  defp get_editor(socket, uid), do: find_ruleset(socket, uid)

  defp find_ruleset(socket, uid), do: Enum.find(socket.assigns.rulesets, &(&1.uid == uid))

  # Dirtiness isn't a stored flag — editor_dirty?/1 computes it against the
  # editor's baseline_rules, so reverting an edit back to the saved value clears
  # the Save button (a one-way latch left it stuck emerald).
  defp update_editor(socket, uid, fun) do
    if get_editor(socket, uid),
      do: socket |> put_editor(uid, fun) |> schedule_preview(uid),
      else: socket
  end

  defp put_editor(socket, "account", fun),
    do: assign(socket, :account, fun.(socket.assigns.account))

  defp put_editor(socket, uid, fun) do
    rulesets =
      Enum.map(socket.assigns.rulesets, fn ruleset ->
        if ruleset.uid == uid, do: fun.(ruleset), else: ruleset
      end)

    assign(socket, :rulesets, rulesets)
  end

  # The Save button is emerald only while the editor differs from what's saved: a
  # new (unsaved) ruleset is always dirty; otherwise the live rules are compared
  # to the baseline snapshot, so a revert flips it back to outlined.
  defp editor_dirty?(%{scope_type: :account} = editor), do: rules_changed?(editor)
  defp editor_dirty?(%{policy: nil}), do: true
  defp editor_dirty?(editor), do: rules_changed?(editor)

  defp rules_changed?(editor) do
    Enum.any?(editor.overrides, &partial_override?/1) or
      Policies.build_rules(policy_input(editor)) != editor.baseline_rules
  end

  # The browser adapter: the form posts overrides as an index-keyed map and the
  # approval gate as strings, so translate both into the domain's shape and let
  # `Policies` own what an edit may change.
  defp apply_policy_params(socket, editor_id, params) when is_map(params) do
    update_editor(socket, editor_id, fn editor ->
      changes = %{
        defaults: params["defaults"] || %{},
        overrides: normalize_indexed(params["overrides"] || []),
        approval: parse_approval(editor.approval, params["approval"] || %{})
      }

      input = Policies.update_editor_input(policy_input(editor), changes)

      editor |> Map.merge(input) |> Map.put(:rules_errors, rules_errors(input))
    end)
  end

  defp apply_policy_params(socket, _editor_id, _params), do: socket

  # The domain-shaped slice of an editor (or of a rail's assigns) — `Policies`
  # owns the rules; every other key on the map is this page's own state.
  defp policy_input(state),
    do: Map.take(state, [:defaults, :overrides, :approval])

  defp parse_target(target) do
    case String.split(target, ":", parts: 2) do
      ["runner", id] -> {:runner, id}
      ["group", name] -> {:group, name}
      _ -> {nil, ""}
    end
  end

  # The choice cards post an explicit boolean string. Treat a missing value as
  # false, and floor the number input at 1 to mirror the changeset.
  defp parse_approval(current, form) when is_map(form) do
    %{
      "min_approvals" => parse_min_approvals(form["min_approvals"], current["min_approvals"]),
      "allow_self_approval" => form["allow_self_approval"] == "true"
    }
  end

  defp parse_approval(current, _form), do: current

  defp parse_min_approvals(value, fallback) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {n, _} when n >= 1 -> n
      _ -> fallback
    end
  end

  defp parse_min_approvals(_value, fallback), do: fallback

  # The ways a scoped ruleset's approval gate is laxer than the account default
  # (fewer required approvals, or self-approval the default forbids). Empty when
  # it's at least as strict. The account default itself is never compared.
  defp approval_weakenings(scoped, default) do
    fewer_approvals =
      if scoped["min_approvals"] < default["min_approvals"],
        do: [
          "Requires #{scoped["min_approvals"]} #{approval_approvers_noun(scoped["min_approvals"])} instead of #{default["min_approvals"]}."
        ],
        else: []

    self_approval =
      if scoped["allow_self_approval"] and not default["allow_self_approval"],
        do: ["Allows self-approval, which the default policy does not."],
        else: []

    fewer_approvals ++ self_approval
  end

  # A "require approval" gate that adds no SECOND party — one approval needed and
  # the requester may supply it.
  defp single_reviewer_gate?(approval),
    do: approval["allow_self_approval"] && approval["min_approvals"] == 1

  defp approval_people_noun(min_approvals) do
    if min_approvals == 1, do: "person", else: "different people"
  end

  defp approval_approvers_noun(min_approvals) do
    if min_approvals == 1, do: "approver", else: "approvers"
  end

  # LiveView posts a repeated field group as an index-keyed map; the domain
  # takes an ordered list.
  defp normalize_indexed(list) when is_list(list), do: list

  defp normalize_indexed(%{} = map) do
    map
    |> Enum.sort_by(fn {key, _} ->
      case Integer.parse(to_string(key)) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> Enum.map(fn {_, value} -> value end)
  end

  defp normalize_indexed(_), do: []

  defp rules_errors(input) do
    input
    |> Policies.build_rules()
    |> Policies.change_policy()
    |> changeset_rules_errors()
  end

  defp changeset_rules_errors(changeset),
    do: for({:rules, {msg, _opts}} <- changeset.errors, do: msg)

  defp partial_override?(override) do
    blank_action?(override) and
      (not blank?(override["name"]) or override["decision"] != "allow")
  end

  defp blank_action?(override), do: blank?(override["action"])

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: false

  # -- Bounded target options and editor previews ----------------------

  defp refresh_target_availability(socket) do
    result =
      if socket.assigns.account_error?,
        do: {:error, :unavailable},
        else:
          Policies.scope_target_available?(
            reserved_targets(socket.assigns.rulesets),
            socket.assigns.current_subject
          )

    assign(socket, :target_available, result)
  end

  defp reserved_targets(rulesets, except_uid \\ nil) do
    for editor <- rulesets,
        is_nil(editor.policy),
        editor.uid != except_uid,
        editor.scope_type in [:runner, :group],
        do: {editor.scope_type, editor.scope_value}
  end

  defp load_target_options(socket, uid, params) do
    load_target_options(socket, uid, params, find_ruleset(socket, uid).target_search)
  end

  defp load_target_options(socket, uid, params, search) do
    editor = find_ruleset(socket, uid)
    opts = LiveTable.params_to_opts(params, [], prefix: "target_#{uid}_")

    case Policies.list_scope_target_options(search, socket.assigns.current_subject, opts) do
      {:ok, options, metadata} ->
        selected =
          if editor.selected_target do
            case Policies.fetch_scope_target_option(
                   editor.scope_type,
                   editor.scope_value,
                   socket.assigns.current_subject
                 ) do
              {:ok, target} ->
                target

              _ ->
                editor.selected_target
                |> Map.put(:label, editor.scope_value)
                |> Map.put(:unavailable?, true)
            end
          end

        socket
        |> assign(:filter_params, params)
        |> put_editor(
          uid,
          &%{
            &1
            | target_search: search,
              target_options: options,
              target_metadata: metadata,
              selected_target: selected,
              target_error: nil
          }
        )
        |> refresh_management_capabilities()

      {:error, :invalid_search} ->
        put_editor(socket, uid, fn editor ->
          %{editor | target_error: "Use valid text without null characters, up to 512 bytes."}
        end)

      {:error, _} ->
        put_editor(socket, uid, fn editor ->
          %{
            editor
            | target_options: [],
              target_error: "Couldn't load targets. Change the search to try again."
          }
        end)
    end
  end

  defp refresh_open_target_options(socket) do
    Enum.reduce(socket.assigns.rulesets, socket, fn editor, socket ->
      if is_nil(editor.policy),
        do: load_target_options(socket, editor.uid, socket.assigns.filter_params),
        else: socket
    end)
  end

  defp select_target(socket, uid, {type, value}) when type in [:runner, :group] do
    taken = reserved_targets(socket.assigns.rulesets, uid)

    case Policies.fetch_scope_target_option(type, value, socket.assigns.current_subject) do
      {:ok, %{taken?: false} = target} ->
        if {type, value} in taken do
          put_flash(socket, :error, "That target already has an open draft.")
        else
          socket
          |> update_editor(
            uid,
            &%{
              &1
              | scope_type: type,
                scope_value: value,
                target_label: target.label,
                selected_target: target
            }
          )
          |> refresh_management_capabilities()
          |> refresh_target_availability()
        end

      _ ->
        socket
        |> select_target(uid, {nil, ""})
        |> put_flash(
          :error,
          "That runner or group isn't in your fleet, or already has a ruleset."
        )
    end
  end

  defp select_target(socket, uid, _) do
    socket
    |> update_editor(
      uid,
      &%{&1 | scope_type: nil, scope_value: "", target_label: "", selected_target: nil}
    )
    |> refresh_management_capabilities()
    |> refresh_target_availability()
  end

  defp target_options(ruleset, rulesets, management) do
    reserved = MapSet.new(reserved_targets(rulesets, ruleset.uid))

    rows =
      if ruleset.selected_target,
        do: [ruleset.selected_target | ruleset.target_options],
        else: ruleset.target_options

    rows
    |> Enum.uniq_by(&{&1.scope_type, &1.scope_value})
    |> Enum.map(fn row ->
      type = if row.scope_type == "runner", do: :runner, else: :group
      taken? = row.taken? or MapSet.member?(reserved, {type, row.scope_value})
      unavailable? = not Map.get(management, {type, row.scope_value}, false)

      suffix =
        cond do
          unavailable? -> " — unavailable"
          taken? -> " — has a ruleset"
          true -> ""
        end

      %{
        value: "#{type}:#{row.scope_value}",
        label:
          if(type == :runner, do: @runner_indent, else: "") <>
            row.label <> suffix,
        disabled: taken? or unavailable?,
        selected: ruleset.scope_type == type and ruleset.scope_value == row.scope_value
      }
    end)
  end

  defp drop_editor(socket, uid) do
    socket
    |> cancel_preview(uid)
    |> assign(:rulesets, Enum.reject(socket.assigns.rulesets, &(&1.uid == uid)))
  end

  defp schedule_preview(socket, uid, delay \\ 300) do
    if get_editor(socket, uid) do
      socket = cancel_preview(socket, uid)
      generation = System.unique_integer([:positive, :monotonic])
      timer = Process.send_after(self(), {:preview_due, uid, generation}, delay)

      put_editor(
        socket,
        uid,
        &%{&1 | preview: :pending, preview_generation: generation, preview_timer: timer}
      )
    else
      socket
    end
  end

  defp cancel_preview(socket, uid) do
    if editor = get_editor(socket, uid) do
      if editor.preview_timer, do: Process.cancel_timer(editor.preview_timer)
    end

    socket =
      case socket.assigns.preview_active do
        {:policy_preview, ^uid, _} ->
          :atomics.put(socket.assigns.preview_cancel, 1, 1)
          socket

        _ ->
          socket
      end

    socket
    |> assign(:preview_queue, Enum.reject(socket.assigns.preview_queue, &(&1 == uid)))
    |> start_next_preview()
  end

  def handle_info({:preview_due, uid, generation}, socket) do
    case get_editor(socket, uid) do
      %{preview_generation: ^generation, preview_timer: timer} when not is_nil(timer) ->
        {:noreply,
         socket
         |> put_editor(uid, &%{&1 | preview_timer: nil})
         |> assign(:preview_queue, Enum.uniq(socket.assigns.preview_queue ++ [uid]))
         |> start_next_preview()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(
        {:list_changed, :team, "membership.runner_access_changed", user_id},
        %{assigns: %{current_user: %{id: user_id}}} = socket
      ) do
    {:noreply, socket |> refresh_management_capabilities() |> refresh_target_availability()}
  end

  # Badge/fleet broadcasts do not change an operator's working draft.
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp start_next_preview(
         %{assigns: %{preview_active: nil, preview_queue: [uid | rest]}} = socket
       ) do
    editor = get_editor(socket, uid)
    subject = socket.assigns.current_subject
    input = policy_input(editor)

    ref =
      cond do
        uid == "account" -> :account
        editor.policy -> editor.policy.id
        true -> {editor.scope_type, editor.scope_value}
      end

    key = {:policy_preview, uid, editor.preview_generation}
    cancel = :atomics.new(1, [])

    socket
    |> assign(preview_active: key, preview_cancel: cancel, preview_queue: rest)
    |> start_async(key, fn ->
      Policies.preview_policy(input, ref, subject,
        cancelled?: fn -> :atomics.get(cancel, 1) == 1 end
      )
    end)
  end

  defp start_next_preview(socket), do: socket

  def handle_async({:policy_preview, uid, generation} = key, result, socket) do
    if socket.assigns.preview_active == key do
      socket =
        case get_editor(socket, uid) do
          %{preview_generation: ^generation} ->
            preview = completed_preview(result, socket.assigns.current_subject)
            put_editor(socket, uid, &%{&1 | preview: preview})

          _ ->
            socket
        end

      {:noreply,
       socket |> assign(preview_active: nil, preview_cancel: nil) |> start_next_preview()}
    else
      {:noreply, socket}
    end
  end

  defp completed_preview({:ok, {:ok, preview}}, subject) do
    if Policies.preview_current?(preview, subject),
      do: {:ok, preview},
      else: {:error, :unauthorized}
  end

  defp completed_preview({:ok, {:error, reason}}, _subject), do: {:error, reason}
  defp completed_preview({:exit, _}, _subject), do: {:error, :load_failed}

  defp preview_unmatched({:ok, preview}), do: preview.unmatched_override_indexes
  defp preview_unmatched(_), do: MapSet.new()

  # -- Render ---------------------------------------------------------

  def render(assigns) do
    ~H"""
    <.console_shell
      chrome={@shell_chrome}
      current_membership={@current_membership}
      current_subject={@current_subject}
      current_user={@current_user}
      current_account={@current_account}
      section={:policies}
      width={:table}
    >
      <:title>Policy</:title>

      <.loading_state :if={@loading?} />

      <.empty_state
        :if={not @loading? and @account_error?}
        tone={:danger}
        icon="state.warning"
        title="Couldn't load the default policy"
      >
        Refresh the page to try again.
      </.empty_state>

      <div :if={not @loading? and not @account_error?} class="space-y-12">
        <div class="space-y-4">
          <.page_intro>
            Choose how to handle actions at each risk level: allow them, require approval, or block them.
            Set rules for specific runners or runner groups, and add exceptions for individual actions.
            Otherwise, your default rules apply.
            <.doc_link href={~p"/docs/policies-and-approvals"}>Policy docs</.doc_link>
          </.page_intro>

          <p :if={not @can_manage?} class="text-xs text-zinc-400">
            You can view the policy, but only owners and admins can change it.
          </p>
          <p :if={@can_manage? and not @has_runner_access?} class="text-xs text-zinc-400">
            You can view all policies. Editing requires access to the affected runners and all packs.
          </p>
          <p
            :if={@has_runner_access? and @can_manage? and not @can_manage_scoped?}
            class="text-xs text-zinc-400"
          >
            Access to all packs is required to edit policy rules.
          </p>
        </div>

        <%!-- Each policy — the default and every targeted ruleset — pairs its
             editor with a rail that PREVIEWS the decision: the live rules run
             over that target's catalog, shown as allow / needs-approval / deny.
             The editor sits naked on the canvas; the only boxes are the
             self-contained controls and the earned amber warnings. --%>
        <section id="default-policy">
          <.section_header title="Default policy">
            <:badge :if={not @can_manage_account?}>
              <.chip
                id="policy-read-only"
                tone={:neutral}
                icon="state.locked"
                baseline
              >
                Read-only
              </.chip>
            </:badge>
            <:subtitle>
              Applies when a runner has no matching runner or group ruleset.
            </:subtitle>
            <%!-- Navigation, but the SAME verb repeats on every targeted-ruleset
                 header below, where the Remove peer forces the bordered face —
                 and one repeated verb wears ONE face per page (the founder read
                 the mixed faces as the rulesets lacking the affordance). --%>
            <:actions :if={@account.policy}>
              <.button
                navigate={
                  ~p"/app/#{@current_account}/audit?#{[target_kind: "policy", target_id: @account.policy.id]}"
                }
                variant={:secondary}
                size={:lg}
                class="h-10"
              >
                View audit trail
              </.button>
            </:actions>
          </.section_header>

          <p
            :if={@can_manage_scoped? and not @can_manage_account?}
            class="mb-4 text-xs text-zinc-400"
          >
            Access to all runners is required to edit the default policy.
          </p>

          <div class="grid grid-cols-1 gap-8 lg:grid-cols-4 lg:items-start">
            <div class="lg:col-span-3">
              <.policy_fields
                editor_id="account"
                defaults={@account.defaults}
                overrides={@account.overrides}
                unmatched_overrides={preview_unmatched(@account.preview)}
                approval={@account.approval}
                rules_errors={@account.rules_errors}
                show_override_errors={@account.show_override_errors?}
                can_manage={@can_manage_account?}
                save_label="Save default policy"
                dirty={editor_dirty?(@account)}
                top_margin="mt-0"
              />
            </div>
            <aside class="lg:col-span-1">
              <.policy_rail
                editor_id="account"
                preview={@account.preview}
                defaults={@account.defaults}
                overrides={@account.overrides}
                approval={@account.approval}
                catalog_path={~p"/app/#{@current_account}/packs"}
              />
            </aside>
          </div>
        </section>

        <section>
          <.section_header title="Targeted rulesets">
            <:subtitle>
              A ruleset <strong class="text-zinc-300">replaces</strong>
              the default policy, including action overrides and approval requirements.
              Runner rules take priority over group rules.
            </:subtitle>
          </.section_header>

          <.empty_state
            :if={@load_error?}
            tone={:danger}
            icon="state.warning"
            title="Couldn't load targeted rulesets"
          >
            Refresh the page to try again.
          </.empty_state>

          <%!-- Viewer with nothing to see gets the quiet fact; for a manager
               the Add-ruleset composer below IS the empty state (the runbook
               precedent — no dashed hint above a dashed composer). --%>
          <p
            :if={
              not @load_error? and @summaries == [] and @rulesets == [] and not @can_manage_scoped?
            }
            class="text-sm text-zinc-400"
          >
            No targeted rulesets yet.
          </p>

          <div id="saved-policies" phx-update="stream" class="divide-y divide-zinc-800/70">
            <div
              :for={{dom_id, summary} <- @streams.policies}
              id={dom_id}
              class="flex items-center justify-between gap-4 py-4"
            >
              <div class="min-w-0 flex items-center gap-2">
                <.chip upcase>{summary.scope_type}</.chip>
                <span class="truncate text-sm font-semibold text-zinc-100">{summary.target_label}</span>
                <span class="text-xs tabular-nums text-zinc-400">v{summary.vsn}</span>
              </div>
              <.button variant={:secondary} phx-click="open_ruleset" phx-value-uid={summary.id}>
                Open ruleset
              </.button>
            </div>
          </div>
          <LiveTable.paginator
            id="saved-policies"
            path={~p"/app/#{@current_account}/policies"}
            metadata={@metadata}
            filter_params={@filter_params}
            prefix="policies_"
            page_count={length(@summaries)}
          />

          <div :if={@rulesets != []} class="mt-8 space-y-8">
            <div :for={ruleset <- @rulesets}>
              <.ruleset_unit
                ruleset={ruleset}
                current_account={@current_account}
                account_approval={@account.approval}
                rulesets={@rulesets}
                filter_params={@filter_params}
                can_choose_target={@can_manage_scoped?}
                can_remove={
                  @can_manage_account? or
                    Map.get(@target_management, {ruleset.scope_type, ruleset.scope_value}, false)
                }
                can_manage={
                  Map.get(@target_management, {ruleset.scope_type, ruleset.scope_value}, false)
                }
                target_management={@target_management}
                catalog_path={~p"/app/#{@current_account}/packs"}
              />
            </div>
          </div>

          <div
            :if={@can_manage_scoped? and not @load_error?}
            id="add-ruleset-row"
            class={["grid grid-cols-1 gap-8 lg:grid-cols-4", @rulesets != [] && "mt-8"]}
          >
            <div id="add-ruleset-control" class="lg:col-span-3">
              <.add_row
                label="Add ruleset"
                phx-click="add_ruleset"
                disabled={@target_available != {:ok, true}}
              />
              <p
                :if={@target_available != {:ok, true}}
                id="add-ruleset-disabled-reason"
                class="mt-2 text-xs text-zinc-400"
              >
                <%= if @target_available == {:ok, false} do %>
                  No runners or groups are available for a new ruleset.
                <% else %>
                  Couldn't load runners and groups. Refresh the page to try again.
                <% end %>
              </p>
            </div>
          </div>
        </section>
      </div>
    </.console_shell>
    """
  end

  attr :preview, :any, required: true
  attr :editor_id, :string, required: true
  attr :defaults, :map, required: true
  attr :overrides, :list, required: true
  attr :approval, :map, required: true
  attr :catalog_path, :string, required: true, doc: "link to the full action catalog (Packs)"

  # The side rail: apply the LIVE rules to the target's catalog and preview the
  # decision — allow / needs-approval / deny, with a few example actions — so the
  # operator sees what the policy DOES, live as they edit. Below it, the catalog's
  # risk profile. Rendering reads only the bounded background preview result.
  defp policy_rail(assigns) do
    result =
      case assigns.preview do
        {:ok, preview} -> preview
        _ -> %{total: nil, outcome: %{}, breakdown: %{}}
      end

    assigns =
      assign(assigns,
        outcome: result.outcome,
        breakdown: result.breakdown,
        single_reviewer?: single_reviewer_gate?(assigns.approval),
        total: result.total
      )

    ~H"""
    <div id={"policy-rail-" <> @editor_id} class="space-y-5">
      <div>
        <h3 class="text-[11px] font-semibold uppercase tracking-wider text-zinc-400">
          Policy preview
        </h3>
        <p :if={@preview == :pending} class="mt-1 text-xs text-zinc-400" role="status">
          Updating preview…
        </p>
        <div :if={match?({:error, _}, @preview)} class="mt-1 space-y-2 text-xs text-zinc-400">
          <%= if @preview == {:error, :no_access} do %>
            No actions are available to preview with your current access.
          <% else %>
            Couldn't update the preview. Your edits are preserved.
            <.button
              variant={:secondary}
              size={:sm}
              phx-click="retry_preview"
              phx-value-editor={@editor_id}
            >Retry preview</.button>
          <% end %>
        </div>
        <p :if={is_integer(@total) and @total > 0} class="mt-1 text-xs leading-relaxed text-zinc-400">
          How these rules would handle <span class="font-medium text-zinc-300">{@total}</span>
          reported {ngettext_action(@total)}. Includes unsaved changes; other rulesets aren't included.
        </p>
        <%!-- No catalog yet: the empty note stands in as the subtitle — no
             "…for your fleet's 0 actions." line to state a count of nothing. --%>
        <p
          :if={@total == 0}
          class="mt-1 text-xs leading-relaxed text-zinc-400"
        >
          <%= if @editor_id == "account" do %>
            No actions reported by your runners yet.
          <% else %>
            No actions reported for this runner or group yet.
          <% end %>
        </p>
      </div>

      <div :if={is_integer(@total) and @total > 0} class="space-y-3">
        <.outcome_row tone={:brand} label="Allowed" stat={@outcome["allow"]} />
        <.outcome_row tone={:amber} label="Needs approval" stat={@outcome["require_approval"]} />
        <.outcome_row tone={:rose} label="Denied" stat={@outcome["deny"]} />
      </div>

      <%!-- The catalog's danger profile — the counts the tier decisions above act
           on. Compact: pill + count, most-severe first. "View packs" opens the full
           action catalog (Packs) in a new tab, so an in-flight edit is untouched. --%>
      <div :if={is_integer(@total) and @total > 0} class="border-t border-zinc-800/70 pt-4">
        <div class="flex items-baseline justify-between">
          <h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
            Actions by risk
          </h3>
          <.link
            href={@catalog_path}
            target="_blank"
            class="text-[10px] font-medium text-zinc-400 hover:text-zinc-300"
          >
            View packs <.icon name="action.external_link" class="h-2.5 w-2.5" />
          </.link>
        </div>
        <dl class="mt-3 space-y-2">
          <div
            :for={tier <- ["critical", "high", "medium", "low"]}
            class="flex items-center justify-between"
          >
            <dt>
              <.risk_pill
                id={"policy-breakdown-#{@editor_id}-#{tier}-risk"}
                risk={tier}
                variant={:track}
              />
            </dt>
            <dd class="text-xs tabular-nums text-zinc-400">{@breakdown[tier]}</dd>
          </div>
        </dl>
      </div>

      <div
        :if={@single_reviewer?}
        id={"policy-single-reviewer-warning-#{@editor_id}"}
        class="border-t border-zinc-800/70 pt-4"
      >
        <.single_reviewer_warning />
      </div>
    </div>
    """
  end

  # The preview rail is the warning's one home. The approval controls
  # already show the selected posture; repeating the consequence there makes
  # the same warning compete with itself on the page.
  defp single_reviewer_warning(assigns) do
    ~H"""
    <.event_block
      tone={:amber}
      icon="security.posture_warning"
      title="No independent approval required"
      size={:compact}
    >
      <:body>A requester with approval permission can provide the only approval needed.</:body>
    </.event_block>
    """
  end

  attr :tone, :atom, required: true
  attr :label, :string, required: true
  attr :stat, :map, required: true, doc: "%{count, examples}"

  # One decision line in the rail: a semantic dot + label + count, with a muted
  # mono example line under it (the WHICH, not just how many).
  defp outcome_row(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <.status_dot tone={@tone} />
          <span class="text-sm text-zinc-300">{@label}</span>
        </div>
        <span class="text-sm font-semibold tabular-nums text-zinc-100">{@stat.count}</span>
      </div>
      <p
        :if={@stat.examples != []}
        class="mt-1 truncate pl-4 font-mono text-[10px] text-zinc-400"
        title={Enum.join(@stat.examples, ", ")}
      >
        {Enum.join(@stat.examples, ", ")}
      </p>
    </div>
    """
  end

  defp ngettext_action(1), do: "action"
  defp ngettext_action(_), do: "actions"

  attr :ruleset, :map, required: true
  attr :current_account, :map, required: true
  attr :account_approval, :map, required: true
  attr :rulesets, :list, required: true
  attr :filter_params, :map, required: true
  attr :can_manage, :boolean, required: true
  attr :can_choose_target, :boolean, required: true
  attr :can_remove, :boolean, required: true
  attr :target_management, :map, required: true
  attr :catalog_path, :string, required: true, doc: "link to the full action catalog (Packs)"

  # A NAKED unit in the rulesets stack (the runbook step grammar) — the
  # hairline + header row delimit it; a card wash around a whole editor was
  # the island §8.1 bans.
  defp ruleset_unit(assigns) do
    ~H"""
    <div class="grid grid-cols-1 gap-8 lg:grid-cols-4 lg:items-start">
      <div class="lg:col-span-3">
        <%= if @ruleset.policy do %>
          <%!-- Saved ruleset: entity chip + name, and a red modal-confirmed Remove
           (removing it loses the overrides, so it earns the confirm). --%>
          <header class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <.chip upcase>{@ruleset.scope_type}</.chip>
                <span class="truncate text-sm font-semibold text-zinc-100">
                  {@ruleset.target_label}
                </span>
              </div>
              <p class="mt-1 text-xs text-zinc-400">
                Replaces the default policy for this {@ruleset.scope_type}.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <.button
                variant={:secondary}
                phx-click="close_ruleset"
                phx-value-uid={@ruleset.uid}
                disabled={editor_dirty?(@ruleset)}
              >Close editor</.button>
              <%!-- Navigation, but it shares this header row with the bordered
                   Remove — one button grammar per row, at the peer's optical
                   height (§7.47). --%>
              <.button
                navigate={
                  ~p"/app/#{@current_account}/audit?#{[target_kind: "policy", target_id: @ruleset.policy.id]}"
                }
                variant={:secondary}
                size={:lg}
                class="h-10"
              >
                View audit trail
              </.button>
              <.confirm_button
                :if={@can_remove}
                id={"remove-ruleset-#{@ruleset.uid}"}
                title="Remove this ruleset?"
                confirm_label="Remove"
                variant={:secondary}
                tone={:rose}
                size={:lg}
                icon="action.delete"
                class="h-10"
                on_confirm={JS.push("remove_ruleset", value: %{uid: @ruleset.uid})}
              >
                <:body>
                  <%= if @ruleset.scope_type == :runner do %>
                    This runner will use its group's ruleset, if one exists. Otherwise, the default policy applies.
                  <% else %>
                    Runners in this group will use the default policy unless they have their own ruleset.
                  <% end %>
                </:body>
                Remove
              </.confirm_button>
            </div>
          </header>
        <% else %>
          <form
            id={"policy-target-search-#{@ruleset.uid}"}
            phx-change="search_targets"
            class="mb-3 sm:max-w-xs"
          >
            <input type="hidden" name="uid" value={@ruleset.uid} />
            <.input
              type="search"
              name="search"
              id={"target-search-#{@ruleset.uid}"}
              label="Find a runner or group"
              value={@ruleset.target_search}
              phx-debounce="300"
              disabled={not @can_choose_target}
            />
          </form>
          <%!-- Unsaved ruleset: the target picker with a red Remove aligned to the
           select box (items-end + matching size). Nothing's persisted, so Remove
           drops the card directly — no confirm modal. A form (not a lone select)
           carries the uid as a hidden field on the change event. --%>
          <header class="flex items-end gap-3">
            <form
              id={"policy-target-form-#{@ruleset.uid}"}
              phx-change="set_target"
              class="w-full sm:max-w-xs"
            >
              <input type="hidden" name="uid" value={@ruleset.uid} />
              <%!-- One tree: each group is a selectable header with its runners
               indented beneath it. A native <optgroup> label can't be picked,
               so groups are plain options; a target another ruleset already
               claims is shown disabled. --%>
              <.select
                id={"policy-target-#{@ruleset.uid}"}
                name="target"
                label="Apply this ruleset to"
                label_variant={:eyebrow}
                disabled={not @can_choose_target}
                prompt="Choose a runner or group…"
                prompt_selected={is_nil(@ruleset.scope_type)}
                options={target_options(@ruleset, @rulesets, @target_management)}
              />
            </form>
            <.button
              variant={:secondary}
              tone={:rose}
              size={:lg}
              type="button"
              phx-click="remove_ruleset"
              phx-value-uid={@ruleset.uid}
              icon="action.delete"
              class="h-10"
            >
              Remove
            </.button>
          </header>
          <p :if={@ruleset.target_error} role="alert" class="mt-2 text-xs text-rose-300">
            {@ruleset.target_error}
          </p>
          <p class="mt-4 text-xs text-zinc-400">
            Starts with the current default rules. Later changes to the default won't update this ruleset.
          </p>
          <LiveTable.paginator
            id={"policy-targets-#{@ruleset.uid}"}
            path={~p"/app/#{@current_account}/policies"}
            metadata={@ruleset.target_metadata}
            filter_params={@filter_params}
            prefix={"target_#{@ruleset.uid}_"}
            page_count={length(@ruleset.target_options)}
          />
        <% end %>

        <p :if={@ruleset.scope_type && not @can_manage} class="mt-4 text-xs text-zinc-400">
          Read-only. Editing requires permission for every runner in this target and all packs.
        </p>

        <.policy_fields
          :if={@ruleset.scope_type}
          editor_id={@ruleset.uid}
          defaults={@ruleset.defaults}
          overrides={@ruleset.overrides}
          unmatched_overrides={preview_unmatched(@ruleset.preview)}
          approval={@ruleset.approval}
          approval_weakenings={approval_weakenings(@ruleset.approval, @account_approval)}
          rules_errors={@ruleset.rules_errors}
          show_override_errors={@ruleset.show_override_errors?}
          can_manage={@can_manage}
          save_label="Save ruleset"
          dirty={editor_dirty?(@ruleset)}
        />
      </div>
      <aside :if={@ruleset.scope_type} class="lg:col-span-1">
        <.policy_rail
          editor_id={@ruleset.uid}
          preview={@ruleset.preview}
          defaults={@ruleset.defaults}
          overrides={@ruleset.overrides}
          approval={@ruleset.approval}
          catalog_path={@catalog_path}
        />
      </aside>
    </div>
    """
  end

  attr :editor_id, :string, required: true
  attr :defaults, :map, required: true
  attr :overrides, :list, required: true

  attr :unmatched_overrides, :any, required: true

  attr :approval, :map, required: true

  attr :approval_weakenings, :list,
    default: [],
    doc: "ways this scoped gate is laxer than the account default (empty for the default itself)"

  attr :rules_errors, :list, required: true
  attr :show_override_errors, :boolean, required: true
  attr :can_manage, :boolean, required: true
  attr :save_label, :string, required: true
  attr :dirty, :boolean, default: false

  attr :top_margin, :string,
    default: "mt-6",
    doc:
      "top gap above the box. `mt-6` separates a ruleset box from its header; the default policy passes `mt-0` — its section header already spaces it (and it lines up with the rail)"

  defp policy_fields(assigns) do
    # Self-approval + a single approval adds no SECOND party — the one case worth an
    # amber callout (guidance folded in). A healthy gate shows none.
    assigns =
      assign(assigns,
        shadowed_overrides: shadowed_overrides_by_index(assigns.overrides),
        single_reviewer?: single_reviewer_gate?(assigns.approval)
      )

    ~H"""
    <%!-- Each policy — the default and every targeted ruleset — is a dashed
         card (the runbook-editor section grammar). A dashed frame with no wash
         is the sanctioned placeholder shape, not a solid island (§8.1). --%>
    <%!-- `@container`: this card sits beside a rail, so its own width — not the
         viewport's — decides how many tier tracks fit. Keyed to the viewport, a
         1024px window put four selects in a 509px card and clipped "Require
         approval" against its chevron. --%>
    <form
      id={"policy-form-" <> @editor_id}
      phx-change="form_change"
      phx-submit="save"
      class={[
        @top_margin,
        "@container space-y-8 rounded-xl border border-dashed border-zinc-800 p-5 sm:p-6"
      ]}
    >
      <input type="hidden" name="editor" value={@editor_id} />

      <%!-- The policy is structured data assembled server-side into one
           `rules` map, so a validation error keys to `:rules`, not a field.
           Render it inline (rose border) on this card — never a flash. The
           constrained selects + monotonic enforcement keep it empty in
           practice; this is the defensive net. --%>
      <.callout :for={msg <- @rules_errors} tone={:rose}>{msg}</.callout>

      <%!-- No "Risk-tier defaults" heading — it just echoes the panel title "Default
           policy". The tier grid is the card's primary content; the panel subtitle
           labels it ("by risk tier") and the tier cards are self-evident. --%>
      <div>
        <div class="grid grid-cols-1 gap-x-4 gap-y-4 @md:grid-cols-2 @2xl:grid-cols-4">
          <.tier_field
            :for={tier <- ["low", "medium", "high", "critical"]}
            editor_id={@editor_id}
            tier={tier}
            value={@defaults[tier]}
            floor_rank={tier_floor_rank(@defaults, tier)}
            can_manage={@can_manage}
          />
        </div>
      </div>

      <div>
        <h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          Action overrides
        </h3>
        <p class="mt-0.5 text-xs text-zinc-400">
          The first matching override applies instead of the risk-level rule.
          Use <code class="font-mono text-zinc-300">*</code> to match multiple actions,
          such as <code class="font-mono text-zinc-300">linux.*</code>.
        </p>

        <%!-- Read-only emptiness uses the shared placeholder; editable policies
             keep the Add override composer as their empty state. --%>
        <.empty_state
          :if={@overrides == [] and not @can_manage}
          variant={:hint}
          class="mt-4 px-4 py-3 [&>p]:leading-4"
        >
          No action overrides
        </.empty_state>

        <div :if={@overrides != []} class="mt-2 divide-y divide-zinc-800/70">
          <%!-- First-match wins, so an override whose glob is subsumed by an
               earlier one is dead. Surface it inline (display-only, pure CPU on
               the in-memory rows) so an operator doesn't believe a deny they
               buried under a broader allow is in force. --%>
          <div
            :for={{override, idx} <- Enum.with_index(@overrides)}
            class="py-4 first:pt-0 last:pb-0"
          >
            <.override_row
              editor_id={@editor_id}
              override={override}
              index={idx}
              shadowed_by={Map.get(@shadowed_overrides, idx)}
              unmatched={MapSet.member?(@unmatched_overrides, idx)}
              show_error={@show_override_errors}
              can_manage={@can_manage}
            />
          </div>
        </div>

        <%!-- Composer standard: the add affordance sits where the next row
             lands — no twin header button, no dashed hint above a dashed
             composer. --%>
        <div :if={@can_manage} class="mt-4">
          <.add_row label="Add override" phx-click="add_override" phx-value-editor={@editor_id} />
        </div>
      </div>

      <%!-- Approval requirements: WHO may approve (allow_self_approval) and HOW MANY
           (min_approvals) — two independent NAKED knobs (the choice cards and the
           count input are self-contained controls; the recessed wash that used to
           group them was one more island). The brand ring marks the active input;
           the neutral card surface and check avoid turning that choice into a safe
           verdict. The verdict below resolves who + count into English. --%>
      <div>
        <h3 class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">
          Approval requirements
        </h3>
        <p class="mt-0.5 text-xs text-zinc-400">
          Applies to actions that require approval.
          For AI-agent requests, self-approval also includes the agent's owner.
        </p>

        <%!-- The two cards name WHO may approve — self-labeling, so no separate
             "Who can approve" eyebrow above them (under the section h3 it read as
             a second title in a row). --%>
        <.choice_cards
          name="policy[approval][allow_self_approval]"
          value={@approval["allow_self_approval"]}
          disabled={!@can_manage}
          columns={2}
          class="mt-3"
        >
          <:card value="false" icon="identity.group" title="No self-approval">
            Requesters can't approve their own requests.
          </:card>
          <:card value="true" icon="identity.person" title="Allow self-approval">
            Requesters can approve their own requests if they have permission to approve.
          </:card>
        </.choice_cards>

        <div class="mt-6">
          <.label variant={:eyebrow} for={"policy-#{@editor_id}-min-approvals"}>
            Required approvers
          </.label>
          <%!-- The eyebrow labels from above; the input and the trailing clause
               share one centered row so they align — an inline eyebrow beside the
               input never lined up with the trailing text. --%>
          <div class="mt-2 flex items-center gap-x-2.5">
            <input
              type="number"
              id={"policy-#{@editor_id}-min-approvals"}
              name="policy[approval][min_approvals]"
              value={@approval["min_approvals"]}
              min="1"
              max={Policies.max_min_approvals()}
              step="1"
              disabled={!@can_manage}
              class="w-14 rounded-lg border-0 bg-zinc-900 px-2 py-1.5 text-center text-sm font-medium text-zinc-100 ring-1 ring-inset ring-zinc-800 focus:ring-2 focus:ring-inset focus:ring-brand-500 disabled:opacity-50"
            />
            <span class="text-xs text-zinc-400">
              {approval_people_noun(@approval["min_approvals"])}
            </span>
          </div>
        </div>

        <%!-- A scoped ruleset REPLACES the default wholesale, so an override
             seeded from a pre-gate template can silently weaken the approval
             gate for its target. Nudge the operator when that's the case. --%>
        <.event_block
          :if={@approval_weakenings != []}
          tone={:amber}
          icon="security.posture_warning"
          title="Less restrictive approval requirements"
          class="mt-4"
        >
          <:body>
            {Enum.join(@approval_weakenings, " ")}
          </:body>
        </.event_block>
      </div>

      <%!-- The Save button IS the dirty indicator: emerald (primary) when there
           are unsaved edits, quiet outlined (secondary) when the form is clean —
           the house pattern that replaced a trailing "Unsaved changes" chip. --%>
      <div :if={@can_manage} class="flex items-center border-t border-zinc-800/70 pt-5">
        <.button
          type="submit"
          variant={if @dirty, do: :primary, else: :secondary}
          phx-disable-with="Saving..."
        >
          {@save_label}
        </.button>
      </div>
    </form>
    """
  end

  attr :editor_id, :string,
    required: true,
    doc: "scopes the lock tooltip id — unique per policy card"

  attr :tier, :string, required: true
  attr :value, :string, required: true
  attr :floor_rank, :integer, required: true
  attr :can_manage, :boolean, required: true

  # NAKED tier field (§8.1: fields are self-contained controls) — a box around
  # one labelled select was an island. The wrapping <label> keeps the
  # click-to-focus association. A decision-colored dot beside the eyebrow reads
  # the tier's verdict at a glance (allow=brand, require approval=amber,
  # deny=rose), the same pass/pending/deny palette as everywhere else.
  defp tier_field(assigns) do
    ~H"""
    <label class="block">
      <span class="flex items-center gap-1.5">
        <.status_dot tone={decision_tone(@value)} />
        <span class="text-[10px] font-semibold uppercase tracking-wider text-zinc-400">{@tier}</span>
      </span>
      <%!-- Options below the floor are disabled — they'd make this tier more
           permissive than a lower-risk one, which the server rejects. Kept
           visible (not hidden) so the operator sees why. When the floor leaves
           exactly ONE choice, the whole select locks (no click on a foregone
           decision) and a hover tooltip carries the why — the rule that used to
           sit as a standing line under the grid. --%>
      <%!-- flex-col so the select (a block wrapper) stretches to the tooltip's
           full width on the cross axis — the tooltip's own inline-flex row would
           shrink it to content. --%>
      <.tooltip
        :if={locked_tier?(@floor_rank)}
        id={"tier-lock-#{@editor_id}-#{@tier}"}
        text="Higher-risk tiers can't be more permissive than lower ones."
        class="w-full flex-col"
      >
        <.tier_select tier={@tier} value={@value} floor_rank={@floor_rank} can_manage={@can_manage} />
      </.tooltip>
      <.tier_select
        :if={not locked_tier?(@floor_rank)}
        tier={@tier}
        value={@value}
        floor_rank={@floor_rank}
        can_manage={@can_manage}
      />
    </label>
    """
  end

  attr :tier, :string, required: true
  attr :value, :string, required: true
  attr :floor_rank, :integer, required: true
  attr :can_manage, :boolean, required: true

  # The tier's decision select. A locked tier (only one legal choice) is
  # disabled even for a manager — the value is already forced by monotonic
  # enforcement, so a non-posting disabled select stays correct on save.
  defp tier_select(assigns) do
    ~H"""
    <.select
      name={"policy[defaults][#{@tier}]"}
      disabled={!@can_manage or locked_tier?(@floor_rank)}
      options={
        Enum.map(decision_options(), fn {label, value} ->
          %{
            value: value,
            label: label,
            disabled: Policies.decision_rank(value) < @floor_rank,
            selected: @value == value
          }
        end)
      }
    />
    """
  end

  # One legal choice left — every decision below the floor is disabled, and the
  # three decisions span ranks 0/1/2, so a floor at the top rank (deny) leaves
  # only deny.
  defp locked_tier?(floor_rank), do: floor_rank >= 2

  defp decision_tone("allow"), do: :brand
  defp decision_tone("require_approval"), do: :amber
  defp decision_tone("deny"), do: :rose
  defp decision_tone(_), do: :neutral

  attr :editor_id, :string, required: true
  attr :override, :map, required: true
  attr :index, :integer, required: true
  attr :shadowed_by, :integer, required: true

  attr :unmatched, :boolean,
    required: true,
    doc: "no action in the target's catalog matches this glob — advisory, never blocking"

  attr :show_error, :boolean, required: true
  attr :can_manage, :boolean, required: true

  # A NAKED override row — compact fields in the runbook-editor grid grammar,
  # a hairline between rows; the wash box around each row was an island.
  defp override_row(assigns) do
    ~H"""
    <%!-- Name and action share the flexible width; Decision takes a `max-content`
         track, so the select is always exactly as wide as its longest option
         needs and a new decision label can never clip it. The trailing track is
         a FIXED trash width, not `auto` — a view-only row renders no trash, and
         a content-sized track would collapse there, sliding every field sideways
         between the editable and blocked states. It reserves the icon button's
         full 40px target even though its visible face matches the 32px fields.
         Field padding owns horizontal spacing: 8px between inputs, then 4px
         before the button target + its 4px face inset = the same visible gap. --%>
    <div class={[
      "space-y-2 @md:grid @md:items-start @md:gap-y-2 @md:space-y-0",
      "@md:grid-cols-[minmax(0,3fr)_minmax(0,5fr)_max-content_2.5rem]"
    ]}>
      <div class="@md:pr-2">
        <.input
          id={"policy-#{@editor_id}-override-#{@index}-name"}
          name={"policy[overrides][#{@index}][name]"}
          value={@override["name"]}
          label="Name (optional)"
          label_variant={:eyebrow}
          size={:compact}
          disabled={!@can_manage}
        />
      </div>
      <div class="@md:pr-2">
        <.input
          id={"policy-#{@editor_id}-override-#{@index}-action"}
          name={"policy[overrides][#{@index}][action]"}
          value={@override["action"]}
          label="Action"
          label_variant={:eyebrow}
          size={:compact}
          class="font-mono text-xs"
          placeholder="e.g. cassandra.repair or linux.*"
          errors={override_action_errors(@show_error, @override)}
          disabled={!@can_manage}
        />
      </div>
      <div class="@md:pr-1">
        <.input
          id={"policy-#{@editor_id}-override-#{@index}-decision"}
          name={"policy[overrides][#{@index}][decision]"}
          type="select"
          label="Decision"
          label_variant={:eyebrow}
          size={:compact}
          class="text-xs"
          value={@override["decision"]}
          options={decision_options()}
          disabled={!@can_manage}
        />
      </div>
      <%!-- Trash sits right after Decision (justify-start), not floated to the
           far edge of its cell. pt-4 centers the 40px target on the compact
           field box; the preceding field already accounts for its face inset. --%>
      <div class="@md:flex @md:items-start @md:justify-start @md:pt-4">
        <.icon_button
          :if={@can_manage}
          icon="action.delete"
          label="Remove override"
          tone={:rose}
          size={:compact}
          phx-click="remove_override"
          phx-value-editor={@editor_id}
          phx-value-index={@index}
        />
      </div>
    </div>

    <%!-- A dead rule (its glob is covered by an earlier one) — advisory, not
         blocking. `shadowed_by` is the 0-based index of the earlier rule, so
         +1 for the operator's 1-based count. Sharpen the copy for a deny:
         that's the case where the operator believes they blocked something. --%>
    <p
      :if={@shadowed_by != nil}
      class="mt-2 flex items-start gap-1.5 text-xs text-amber-300"
    >
      <.icon name="state.warning" class="mt-0.5 h-3.5 w-3.5 flex-none" />
      <span :if={@override["decision"] == "deny"}>
        Override {@shadowed_by + 1} matches first, so this <strong>deny</strong> rule never applies.
      </span>
      <span :if={@override["decision"] != "deny"}>
        Override {@shadowed_by + 1} matches first, so this override never applies.
      </span>
    </p>

    <%!-- A glob that matches nothing today. Not an error: the pack may simply
         not be installed yet. Shown only when the row isn't already shadowed,
         so one row carries one diagnosis. The preview is limited to the
         visible catalog; actions may also be reported later. --%>
    <p
      :if={@unmatched and @shadowed_by == nil}
      class="mt-2 flex items-start gap-1.5 text-xs text-amber-300"
    >
      <.icon name="state.warning" class="mt-0.5 h-3.5 w-3.5 flex-none" />
      <span>
        No actions in this preview match this pattern. It can still apply to actions reported later.
      </span>
    </p>
    """
  end

  defp override_action_errors(true, override) do
    if partial_override?(override),
      do: ["Enter an action name or pattern, or remove this override."],
      else: []
  end

  defp override_action_errors(false, _override), do: []

  defp decision_options,
    do: [{"Allow", "allow"}, {"Require approval", "require_approval"}, {"Deny", "deny"}]

  # The index of the earlier override that shadows each row, keyed by the
  # shadowed row's index. Derived once per editor render from the live
  # (possibly-unsaved) rows via the pure `Policies` accessor — first-match means
  # an override under a broader earlier glob is dead.
  defp shadowed_overrides_by_index(overrides) do
    %{"overrides" => overrides}
    |> Policies.shadowed_overrides()
    |> Map.new(fn %{index: index, shadowed_by: shadowed_by} -> {index, shadowed_by} end)
  end

  # The rank below which a tier's decision can't drop: 0 for `low` (anything
  # goes), otherwise the rank of the immediately-lower tier. Reads the lower
  # tier directly because the state is already monotonized.
  defp tier_floor_rank(_defaults, "low"), do: 0
  defp tier_floor_rank(defaults, "medium"), do: Policies.decision_rank(defaults["low"])
  defp tier_floor_rank(defaults, "high"), do: Policies.decision_rank(defaults["medium"])
  defp tier_floor_rank(defaults, "critical"), do: Policies.decision_rank(defaults["high"])
end
