# REPL Agent Harness Quick Start

This is the five-minute path from a checkout to using the REPL as an agent
harness. It shows the same Scheme forms on the portable terminal REPL and the
Emacs REPL entry, then points to the reference documents for the full contract.

The examples use stubbed provider steps by default. They exercise the real
session, agent registry, prompt verbs, task runner, result, transcript, audit,
policy, and budget surfaces, but they do not require a model server. Add a local
provider later when you want real model text.

## Start a REPL

From the repository root, start the portable terminal REPL:

```sh
tools/consent-repl --session quickstart
```

For compact machine-readable records, use the `datum` chrome:

```sh
printf '(+ 1 2)\n(exit)\n' \
  | tools/consent-repl --session quickstart --chrome datum
```

The high-signal records are:

```scheme
(repl-result ... (display "3"))
(repl-exit (session quickstart) (reason explicit) (status closed-ok) ...)
```

The Emacs parity entry uses the same REPL contract:

```sh
printf '(+ 1 2)\n(exit)\n' \
  | emacs -Q --batch -L lisp -l consent-repl-stream \
      -f consent-repl-stream-main
```

For an interactive Emacs buffer, load the checkout and run
`M-x consent-repl-comint`:

```elisp
(add-to-list 'load-path (expand-file-name "lisp" "/path/to/consent/"))
(require 'consent-repl-comint)
```

The complete REPL reference is [Using the Consent Scheme REPL](repl.md). The
portable shell details are in [Portable Terminal REPL Shell](portable-repl.md),
and the host-neutral record vocabulary is in
[Cross-Host REPL Interaction Contract](repl-interaction-contract.md).

## Evaluate Scheme

These forms work in either REPL:

```scheme
(+ 2 3)
(define answer 21)
(+ answer answer)
missing-name
```

Successful forms produce `repl-result` records. An unbound identifier produces a
recoverable `repl-condition`, and the session keeps running. Under the `comment`
chrome you see a human transcript; under `datum` you see the raw records.

## Create and Switch Sessions

Session verbs live in `(agent session)`:

```scheme
(import (agent session))
(create-session 'named '((id work-a)))
(switch-session 'work-a)
(current-session)
(list-sessions)
```

Mutating session verbs are policy-gated by `window-session`. Without that
authority, they fail closed as `repl-condition` records and the REPL continues.
The plain `tools/consent-repl` launcher currently keeps this default-deny
posture; hosts that need to demonstrate granted session mutation pass evaluator
options to the REPL driver.

This copy-pasteable portable driver grants `window-session`, creates two
sessions, switches between them, and shows that each session keeps an isolated
binding for `marker`:

```sh
chibi-scheme -A scheme /dev/stdin <<'SCM'
(import (scheme base) (scheme write) (cli repl-shell) (consent reader))

(define source
  "(import (agent session))\n\
(create-session 'named '((id work-a)))\n\
(create-session 'named '((id work-b)))\n\
(switch-session 'work-a)\n\
(import (agent session))\n\
(define marker 'a)\n\
marker\n\
(switch-session 'work-b)\n\
(import (agent session))\n\
(define marker 'b)\n\
marker\n\
(switch-session 'work-a)\n\
marker\n\
(exit)\n")

(for-each
 (lambda (record)
   (write-string (consent-datum->external record))
   (newline))
 (cli-repl-records-from-string
  source
  "project-main"
  '((policy-actions (window-session . allow)))))
SCM
```

Look for result displays in this order:

```scheme
(display "a")
(display "b")
(display "a")
```

The Emacs driver accepts the same policy idea as an evaluator option:
`'(:policy-actions ((window-session . allow)))`. The interactive Emacs session
commands and the Scheme `switch-session` verb share the same current-session
pointer; see [Session Lifecycle and Snapshots](session-lifecycle.md).

## Prompt an Agent

The `(agent prompt)` library turns a REPL session into a small agent harness.
It re-exports the registry helpers, so one import is enough for discovery,
registration, and the three prompt verbs:

```sh
tools/consent-repl --session quickstart --chrome quiet <<'SCM'
(import (scheme base) (agent prompt))

(define registry (make-agent-registry))
(begin
  (register-agent
   registry
   (make-agent 'coder-1 '((role coder) (model local-coder))))
  (register-agent
   registry
   (make-agent 'reviewer-1 '((role reviewer) (model local-reviewer))))
  (define harness (make-prompt-harness (list (list 'registry registry))))
  (list (map agent-id (agents harness)) (roles harness) (models harness)))

(prompt-result-agent-id
 (prompt harness 'plan '((provider ((finish done))) (verifier passed))))

(prompt-result-agent-id
 (prompt-role harness 'reviewer 'review
              '((provider ((finish done))) (verifier passed))))

(prompt-result-agent-id
 (prompt-model harness 'local-coder 'code
               '((provider ((finish done))) (verifier passed))))

(exit)
SCM
```

The result values are:

```scheme
((default coder-1 reviewer-1) (planner coder reviewer)
 (auto local-coder local-reviewer))
default
reviewer-1
coder-1
```

`prompt` asks the registry to select an agent automatically. With no stronger
configuration, selection falls back to the seeded `default` planner. `prompt-role`
and `prompt-model` add a requested role or model to the selection context; the
returned `agent-selection` record says whether the match was by role, by model,
or by fallback.

The first `(import (agent prompt))` can take a moment on an interpreted portable
host because it loads the single-sourced agent stack.

## Read Results, Yields, and Audit

A prompt returns one `prompt-result` record. Use accessors instead of scraping
display text:

```scheme
(define result
  (prompt (make-prompt-harness)
          'summarize-status
          '((provider ((finish done))) (verifier passed))))

(prompt-result-status result)      ; selected
(prompt-result-state result)       ; complete
(prompt-result-receipt result)     ; task-stop / task-pause / prompt-error
(prompt-result-budget result)      ; task-budget
```

The transcript contains the runner's yielded and progress events, including the
opening `agent-yield` and the fake local model route used by the stub provider:

```scheme
(map (lambda (event) (cadr (assq 'kind (cdr event))))
     (prompt-result-transcript result))
;; => (agent-yield agent-progress agent-progress model-route)
```

The prompt audit records explain selection and route decisions:

```scheme
(map (lambda (entry) (cadr (assq 'kind (cdr entry))))
     (prompt-result-audit result))
;; => (agent-selected model-route)
```

For the broader task lifecycle, see
[Task Lifecycle and Control Loop](control-loop.md). Human collaboration and
richer paused-task UX are tracked by #52; the current Emacs session, event,
audit, and approval buffers are described in
[Getting Started](getting-started.md) and
[Session Lifecycle and Snapshots](session-lifecycle.md).

## Policy and Budgets

Prompt dispatch fails closed when the harness has no granted authority:

```scheme
(define denied
  (prompt (make-prompt-harness '((authority #f)))
          'sensitive
          '((provider ((finish done))) (verifier passed))))

(list (prompt-result-status denied)
      (prompt-result-state denied)
      (prompt-result-receipt denied))
;; => (authority-missing failed-closed
;;     (prompt-error (reason authority-missing) ...))
```

Noninteractive prompts must preload authority as data:

```scheme
(define authority
  (make-prompt-authority
   '((origin noninteractive)
     (source grant)
     (grants ((capability-grant
               (id script-prompt)
               (domain provider)
               (operations complete)
               (expires never)))))))

(define script-harness
  (make-prompt-harness (list (list 'authority authority))))
```

Budgets shape how far a prompt may run. A zero step budget halts with a
structured stop receipt:

```scheme
(define exhausted
  (prompt (make-prompt-harness)
          'budget-check
          '((provider ((finish done))) (verifier passed) (max-steps 0))))

(list (prompt-result-state exhausted)
      (prompt-result-receipt exhausted)
      (prompt-result-budget exhausted))
;; => (failed
;;     (task-stop ... (stop-reason budget-exhausted))
;;     (task-budget (max-steps 0) ...))
```

For the full ledger, reasons, and `with-budget`, see
[Evaluation Budgets](budgets.md). Capability and provider authority are
described in
[Capability Environment and Effect Lowering](capability-environment.md).

## Local Models

The prompt examples above use stubbed provider steps:

```scheme
'((provider ((finish done))) (verifier passed))
```

That is intentional. It makes the harness runnable with no model installed and
keeps the first result deterministic. To call a real local model directly, use
the `(agent models)` provider setup in
[Getting Started](getting-started.md#local-model-providers). The shortest
Ollama path is:

```sh
ollama pull qwen3:0.6b
ollama serve
```

Then register the loopback OpenAI-compatible endpoint from Consent Scheme as
shown in [Ollama Setup](getting-started.md#ollama-setup). Provider hardening,
streaming, and broader protocol documentation remain separate follow-up work;
the quick-start stays on the runnable REPL harness slice.
