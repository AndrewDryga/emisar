defmodule EmisarProductAnalytics do
  @moduledoc false

  def connect! do
    {:ok, connection} =
      Postgrex.start_link(
        hostname: System.fetch_env!("PGHOST"),
        port: env_integer!("PGPORT"),
        database: System.fetch_env!("PGDATABASE"),
        username: System.fetch_env!("PGUSER"),
        parameters: [application_name: "emisar_livebook_product_analytics"]
      )

    role = System.fetch_env!("EMISAR_DATABASE_ROLE")

    unless String.match?(role, ~r/^[a-z_][a-z0-9_]*$/) do
      raise "EMISAR_DATABASE_ROLE is not a PostgreSQL identifier"
    end

    Postgrex.query!(connection, ~s(SET ROLE "#{role}"), [])
    Postgrex.query!(connection, "SET default_transaction_read_only = on", [])

    Postgrex.query!(
      connection,
      "SELECT set_config('statement_timeout', $1, false)",
      [System.fetch_env!("EMISAR_DATABASE_STATEMENT_TIMEOUT_MS") <> "ms"]
    )

    connection
  end

  def query(connection, sql, params \\ []) do
    result = Postgrex.query!(connection, sql, params)
    Enum.map(result.rows, &Map.new(Enum.zip(result.columns, &1)))
  end

  def table(rows), do: Kino.DataTable.new(rows)

  def scalar([row | _], key, default \\ 0), do: Map.get(row, key, default)
  def scalar([], _key, default), do: default

  def percent(_numerator, denominator) when denominator in [0, nil], do: "0.0%"

  def percent(numerator, denominator) do
    "#{Float.round(numerator * 100.0 / denominator, 1)}%"
  end

  def kpis(items) do
    items
    |> Enum.map(fn {label, value} -> Kino.Markdown.new("### #{value}\n#{label}") end)
    |> Kino.Layout.grid(columns: min(length(items), 4))
  end

  def line(rows, x, y, opts \\ []) do
    rows
    |> base_chart(opts)
    |> VegaLite.mark(:line, point: true)
    |> VegaLite.encode_field(:x, x,
      type: Keyword.get(opts, :x_type, :temporal),
      title: Keyword.get(opts, :x_title, x)
    )
    |> VegaLite.encode_field(:y, y,
      type: :quantitative,
      title: Keyword.get(opts, :y_title, y)
    )
    |> Kino.VegaLite.new()
  end

  def bar(rows, x, y, opts \\ []) do
    rows
    |> base_chart(opts)
    |> VegaLite.mark(:bar)
    |> VegaLite.encode_field(:x, x,
      type: Keyword.get(opts, :x_type, :nominal),
      sort: Keyword.get(opts, :sort, "-y"),
      title: Keyword.get(opts, :x_title, x)
    )
    |> VegaLite.encode_field(:y, y,
      type: :quantitative,
      title: Keyword.get(opts, :y_title, y)
    )
    |> Kino.VegaLite.new()
  end

  def stacked_bar(rows, x, y, color, opts \\ []) do
    rows
    |> base_chart(opts)
    |> VegaLite.mark(:bar)
    |> VegaLite.encode_field(:x, x,
      type: Keyword.get(opts, :x_type, :temporal),
      title: Keyword.get(opts, :x_title, x)
    )
    |> VegaLite.encode_field(:y, y,
      type: :quantitative,
      title: Keyword.get(opts, :y_title, y)
    )
    |> VegaLite.encode_field(:color, color,
      type: :nominal,
      title: Keyword.get(opts, :color_title, color)
    )
    |> Kino.VegaLite.new()
  end

  defp base_chart(rows, opts) do
    VegaLite.new(
      width: Keyword.get(opts, :width, 720),
      height: Keyword.get(opts, :height, 300),
      title: Keyword.get(opts, :title)
    )
    |> VegaLite.data_from_values(rows)
  end

  defp env_integer!(name) do
    case Integer.parse(System.fetch_env!(name)) do
      {integer, ""} -> integer
      _ -> raise "#{name} must be an integer"
    end
  end
end
