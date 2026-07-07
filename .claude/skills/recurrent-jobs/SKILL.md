---
name: recurrent-jobs
description: Build or review a recurrent background job / scheduled sweep in portal/ the emisar way - context-owned jobs/, supervised by the owning context, idempotent durable-row work, testable. Use when adding/changing a recurrent job or debugging job ticks.
allowed-tools: Read, Grep, Glob, Bash, Write, Edit
---

# Recurrent Jobs

Runtime jobs are first-party supervised processes, not Oban workers.

## Shape

Domain jobs live under the owning context's `jobs/`, and the context module
supervises them:

```elixir
defmodule Emisar.Runs.Jobs.DispatchTimeout do
  use Emisar.Jobs.Job,
    otp_app: :emisar,
    every: :timer.minutes(1),
    executor: Emisar.Jobs.Executors.GloballyUnique

  @impl Emisar.Jobs.Executors.GloballyUnique
  def execute(config) do
    # Poll durable rows and make idempotent transitions.
    :ok
  end
end
```

The owning context starts its jobs:

```elixir
defmodule Emisar.Runs do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__.Supervisor)

  @impl Supervisor
  def init(_opts) do
    Supervisor.init([Jobs.DispatchTimeout], strategy: :one_for_one)
  end
end
```

`Emisar.Jobs` is infrastructure only: declaration macro + executors. Do not put
domain sweep engines in top-level `Emisar.Jobs` and do not recreate
`lib/emisar/workers/`.

## Iron Law IL-13

1. **Idempotent.** A tick may run more than once after restarts, failover, or a
   crash. Check current row state before acting.
2. **Durable rows, not scheduler memory.** The scheduler has no persistent queue;
   each tick polls rows with durable state and bounded queries.
3. **No overlapping-work assumptions.** `GloballyUnique` elects one leader per
   job across the cluster, but the job logic must still be safe if a previous
   tick's side effects partially completed.

## Wiring

- Keep the job under the owning context's `jobs/`.
- Add that context to `Emisar.Application` if it is not already a supervised
  child.
- Disable job modules explicitly in `config/test.exs`; tests call `execute/1`
  directly so all DB work stays inside the test sandbox checkout.
- If a job needs another context's table shape, add a narrow internal function on
  the owning context instead of building a sibling context's Query pipeline.

## Testing

- Run the job directly: `JobModule.execute([])` or with keyword config.
- Cover the idempotency path: run `execute/1` twice, assert the second is a no-op.
- For a sweep, cover happy, nothing-to-do, cross-account scoping, and bounded
  pagination/batch behavior.

## Finish

`cd portal && mix compile --warnings-as-errors && mix format --check-formatted && mix credo && mix test`.
