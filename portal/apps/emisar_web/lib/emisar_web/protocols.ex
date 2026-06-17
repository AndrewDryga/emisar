defimpl Phoenix.Param, for: Emisar.Accounts.Account do
  # The slug is the canonical URL key (`~p"/app/#{account}/…"` renders it); the
  # id stays a valid fallback so the same routes resolve for API / SSO / temporary
  # redirects (resolution is id-or-slug — see `Accounts.fetch_membership_by_account_id_or_slug/2`).
  def to_param(%Emisar.Accounts.Account{slug: slug}) when is_binary(slug), do: slug
  def to_param(%Emisar.Accounts.Account{id: id}), do: id
end
