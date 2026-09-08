defmodule Emisar.Repo.Migrations.AllowIndependentGroupAccessAdditions do
  use Ecto.Migration

  def up, do: replace_checks(true)
  # No data is rewritten on rollback. PostgreSQL refuses the old constraints
  # while any newer none/empty-pack grant still needs the expanded shape.
  def down, do: replace_checks(false)

  defp replace_checks(independent?) do
    table = :sso_directory_group_runner_access_mappings
    name = :sso_directory_group_runner_access_mappings_access_check
    drop constraint(table, name)
    create constraint(table, name, check: runner_check(independent?))

    for {table, name, runner, pack} <- [
          {:account_memberships, :account_memberships_pack_access_check, "runner", "pack"},
          {:sso_identity_providers, :sso_identity_providers_default_pack_access_check,
           "default_runner", "default_pack"},
          {:sso_directory_group_runner_access_mappings,
           :sso_directory_group_runner_access_mappings_pack_access_check, "runner", "pack"}
        ] do
      drop constraint(table, name)
      canonical? = table != :sso_directory_group_runner_access_mappings or not independent?
      create constraint(table, name, check: pack_check(runner, pack, independent?, canonical?))
    end
  end

  defp runner_check(independent?) do
    """
    runner_access_mode IN ('none', 'all', 'restricted') AND (
      (runner_access_mode IN ('none', 'all') AND cardinality(runner_scope_groups) = 0
        AND cardinality(runner_scope_runner_ids) = 0)
      OR (runner_access_mode = 'restricted' AND
        cardinality(runner_scope_groups) + cardinality(runner_scope_runner_ids) > 0)
    )
    """ <> if(independent?, do: "", else: " AND runner_access_mode <> 'none'")
  end

  defp pack_check(runner, pack, independent?, canonical?) do
    minimum = if independent?, do: ">= 0", else: "> 0"

    canonical =
      if canonical?,
        do: " AND (#{runner}_access_mode <> 'none' OR #{pack}_access_mode = 'all')",
        else: ""

    """
    #{pack}_access_mode IN ('all', 'restricted') AND (
      (#{pack}_access_mode = 'all' AND cardinality(#{pack}_scope_pack_ids) = 0)
      OR (#{pack}_access_mode = 'restricted' AND cardinality(#{pack}_scope_pack_ids) #{minimum})
    )
    """ <> canonical
  end
end
