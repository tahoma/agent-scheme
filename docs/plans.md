# First-Class Plans

Agent Scheme plans are Scheme-readable records shared through the `(agent plan)`
library. They keep an agent's current intention structure editable in the REPL
instead of burying it in prose status messages.

```scheme
(import (scheme base)
        (agent plan))

(plan-create!
 '(plan
    (id repl-plan)
    (scope project)
    (goal "Expose a shared plan through the REPL.")
    (steps (((id inspect) (status done))
            ((id implement) (status active))
            ((id verify) (status pending))))))

(plan-step-status! 'repl-plan 'implement 'done)
(plan-step-status! 'repl-plan 'verify 'active)
(plan-yield 'repl-plan)
```

The canonical plan shape is ordinary data:

```scheme
(plan
  (id repl-plan)
  (scope project)
  (status active)
  (goal "Expose a shared plan through the REPL.")
  (steps
    (((id inspect) (status done))
     ((id implement) (status done))
     ((id verify) (status active)))))
```

## Procedures

- `(plan-create! datum)` creates or replaces a plan record.
- `(plan-ref plan-id)` returns one plan, or `#f` when the id is unknown.
- `(plan-list scope)` returns plans in `fresh`, `session`, or `project` scope.
- `(plan-step-add! plan-id step-datum)` appends a stable step record.
- `(plan-step-status! plan-id step-id status)` updates one step status.
- `(plan-status! plan-id status)` updates the overall plan status.
- `(plan-yield plan-id)` emits the plan through `(agent io)` for the outer loop.

Use `session` scope when a plan belongs to a durable REPL session and `project`
scope when the user and agent should see the same project-level plan. A plan
created with `(memory important)` is summarized through `(agent memory)` so it
can be found with normal memory queries.
