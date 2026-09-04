[
  import_deps: [:phoenix],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["mix.exs", "config/*.exs", "credo/**/*.{ex,exs}"],
  subdirectories: ["apps/*"]
]
