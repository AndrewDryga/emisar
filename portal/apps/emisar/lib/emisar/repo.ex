defmodule Emisar.Repo do
  use Ecto.Repo,
    otp_app: :emisar,
    adapter: Ecto.Adapters.Postgres
end
