# REPL Agent Harness Quick Start

This is the hands-on path from a checkout to using the REPL as an agent harness.
Start with the fifteen-minute tutorial project, then use the later sections as
the reference for each surface. The same Scheme forms work on the portable
terminal REPL and the Emacs REPL entry unless a section calls out a host-specific
boundary.

The examples start with stubbed provider steps so the harness is runnable before
any model downloads. That path exercises the real session, agent registry,
prompt verbs, task runner, result, transcript, audit, policy, and budget
surfaces. After that, set up a local role environment so the same REPL session
can route real prompts to useful local models instead of only smoke-test models.

## Fifteen-Minute Tutorial Project

The first project is a small symbolic differentiator in the SICP tradition:
represent algebra as Scheme data, implement the derivative rules, and use the
agent harness to route the work through planner, coder, reviewer, and
memory-curator roles. The project is deterministic in the portable standalone
runtime because it uses stubbed provider steps. If Ollama and the Emacs-hosted
runtime are ready, the local model section below shows the live `model-complete`
step for asking a real coder model to extend the differentiator. Large model
download time depends on your network; choose the small laptop profile if you
want the first run to stay near fifteen minutes.

Run this from the repository root:

```sh
tools/consent-repl --session symbolic-agent-tour --chrome quiet <<'SCM'
(import (scheme base) (scheme cxr) (agent prompt))

(define registry (make-agent-registry))
(register-agent registry
                (make-agent 'planner-1
                            '((role planner) (model qwen3:8b))))
(register-agent registry
                (make-agent 'scheme-coder-1
                            '((role coder) (model qwen2.5-coder:14b))))
(register-agent registry
                (make-agent 'reviewer-1
                            '((role reviewer) (model qwen2.5-coder:14b))))
(register-agent registry
                (make-agent 'memory-1
                            '((role memory-curator) (model gemma3:12b))))

(define harness (make-prompt-harness (list (list 'registry registry))))
(list (map agent-id (agents harness)) (roles harness) (models harness))

(prompt-result-agent-id
 (prompt-model harness 'qwen3:8b
               '(plan symbolic differentiation project)
               '((provider ((finish planned))) (verifier passed))))

(define (=number? expression value)
  (and (number? expression) (= expression value)))

(define (make-sum left right)
  (cond ((=number? left 0) right)
        ((=number? right 0) left)
        ((and (number? left) (number? right)) (+ left right))
        (else (list '+ left right))))

(define (make-product left right)
  (cond ((or (=number? left 0) (=number? right 0)) 0)
        ((=number? left 1) right)
        ((=number? right 1) left)
        ((and (number? left) (number? right)) (* left right))
        (else (list '* left right))))

(define (sum? expression)
  (and (pair? expression) (eq? (car expression) '+)))

(define (product? expression)
  (and (pair? expression) (eq? (car expression) '*)))

(define (deriv expression variable)
  (cond ((number? expression) 0)
        ((symbol? expression) (if (eq? expression variable) 1 0))
        ((sum? expression)
         (make-sum (deriv (cadr expression) variable)
                   (deriv (caddr expression) variable)))
        ((product? expression)
         (make-sum
          (make-product (cadr expression)
                        (deriv (caddr expression) variable))
          (make-product (deriv (cadr expression) variable)
                        (caddr expression))))
        (else '(unsupported expression))))

(define code-result
  (prompt-role harness 'coder '(implement deriv)
               '((provider ((finish complete))) (verifier passed))))
(prompt-result-agent-id code-result)

(define differentiator-tests
  (list
   (equal? (deriv 'x 'x) 1)
   (equal? (deriv 'y 'x) 0)
   (equal? (deriv '(+ (* x x) (* 3 x)) 'x)
           '(+ (+ x x) 3))
   (equal? (deriv '(* x (+ x 3)) 'x)
           '(+ x (+ x 3)))))

differentiator-tests
(deriv '(+ (* x x) (* 3 x)) 'x)

(define review-result
  (prompt-role harness 'reviewer '(review deriv tests)
               '((provider ((finish reviewed))) (verifier passed))))
(prompt-result-agent-id review-result)
(map (lambda (entry) (cadr (assq 'kind (cdr entry))))
     (prompt-result-audit review-result))

(prompt-result-agent-id
 (prompt-role harness 'memory-curator
              '(remember symbolic differentiator tutorial)
              '((provider ((finish captured))) (verifier passed))))

(exit)
SCM
```

The interesting records are:

```scheme
((default planner-1 scheme-coder-1 reviewer-1 memory-1)
 (planner coder reviewer memory-curator)
 (auto qwen3:8b qwen2.5-coder:14b gemma3:12b))
planner-1
scheme-coder-1
(#t #t #t #t)
(+ (+ x x) 3)
reviewer-1
(agent-selected model-route)
memory-1
```

At that point you have seen the core loop: normal Scheme evaluation,
role-specific agent registration, model-id discovery, a planned implementation,
executable tests, a reviewer route, a memory-curator route, and audit entries
that explain why the reviewer agent was selected. Continue through the sections
below to mutate sessions, inspect transcripts, exercise policy and budget
failures, and connect the same role names to local models.

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
   (make-agent 'coder-1 '((role coder) (model qwen2.5-coder:14b))))
  (register-agent
   registry
   (make-agent 'reviewer-1 '((role reviewer) (model qwen2.5-coder:14b))))
  (define harness (make-prompt-harness (list (list 'registry registry))))
  (list (map agent-id (agents harness)) (roles harness) (models harness)))

(prompt-result-agent-id
 (prompt harness 'plan '((provider ((finish done))) (verifier passed))))

(prompt-result-agent-id
 (prompt-role harness 'reviewer 'review
              '((provider ((finish done))) (verifier passed))))

(prompt-result-agent-id
 (prompt-model harness 'qwen2.5-coder:14b 'code
               '((provider ((finish done))) (verifier passed))))

(exit)
SCM
```

The result values are:

```scheme
((default coder-1 reviewer-1) (planner coder reviewer)
 (auto qwen2.5-coder:14b))
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

## Practical Local Role Environment

The stubbed prompt examples above are a no-model smoke path:

```scheme
'((provider ((finish done))) (verifier passed))
```

That is useful for deterministic tests, but it is not a satisfying first local
agent setup. For a real first encounter, install a small role matrix through an
OpenAI-compatible local server such as Ollama, then register those model ids
with both `(agent models)` and the prompt agent registry.

Use the starter profile that matches your machine:

| Machine profile | Pull these first |
| --- | --- |
| Small laptop, 8-16 GB memory | `qwen2.5-coder:7b`, `qwen3:4b`, `gemma3:4b` |
| Developer laptop, 16-32 GB memory | `qwen2.5-coder:14b`, `qwen3:8b`, `gemma3:12b` |
| Large local box, 48 GB+ memory | `qwen2.5-coder:32b`, `qwen3:30b`, `gemma3:12b` |

The small profile is good enough for first coding, planning, summarizing, and
memory experiments. The developer-laptop profile is the recommended first setup
for a solid local experience without jumping to 30B+ downloads. On a large local
box, add `llama3.1:70b` when latency and disk use are acceptable.

The tiny `qwen3:0.6b`, `qwen2.5-coder:0.5b`, and `gemma3:1b` models remain
useful for CI smoke tests and quick transport checks. They should not be the
main recommendation for someone evaluating the system as an agent harness.

The recommended developer-laptop setup is:

```sh
ollama pull qwen2.5-coder:14b
ollama pull qwen3:8b
ollama pull gemma3:12b
ollama serve
```

For a smaller machine, replace that pull set with:

```sh
ollama pull qwen2.5-coder:7b
ollama pull qwen3:4b
ollama pull gemma3:4b
ollama serve
```

The Ollama OpenAI-compatible endpoint is `http://127.0.0.1:11434/v1`. Register
that endpoint and map the local models to Consent roles:

```scheme
(import (scheme base)
        (agent models)
        (agent prompt))

(model-provider-register!
 '(model-provider
   (id local-ollama)
   (kind local)
   (transport openai-compatible-http)
   (endpoint "http://127.0.0.1:11434/v1")
   (models
    (((id qwen2.5-coder:14b)
      (roles (scheme-scripter coder reviewer))
      (privacy local))
     ((id qwen3:8b)
      (roles (planner approval-explainer))
      (privacy local))
     ((id gemma3:12b)
      (roles (summarizer memory-curator))
      (privacy local))))))
```

On the small profile, use the same shape with `qwen2.5-coder:7b`, `qwen3:4b`,
and `gemma3:4b`. On a large machine, use `qwen2.5-coder:32b` for coder and
reviewer, `qwen3:30b` or `llama3.1:70b` for planner, and keep `gemma3:12b` for
summaries and memory curation.

Check routing before asking for a completion:

```scheme
(map model-route
     '(planner scheme-scripter coder reviewer summarizer memory-curator)
     '(() () () () () ()))
```

In the portable standalone runtime, stop at routing and registry checks for now;
it shares the provider datums and role assignment surface, but it does not yet
lower live HTTP model transport. In the Emacs-hosted runtime, test one real
local completion through the registered role:

```scheme
(model-complete
 'scheme-scripter
 "Write a portable Scheme procedure that returns the last element of a proper list."
 '((temperature 0.2)))
```

`model-complete` is the current Emacs-hosted live local-model surface. The
`prompt` verbs above still use injected provider steps in this bootstrap slice,
so a live model completion and a prompt-run are adjacent REPL exercises rather
than one combined streaming provider path. Keep the ids aligned anyway; the
prompt registry then selects the same role/model names your local provider knows
about:

```scheme
(define registry (make-agent-registry))
(register-agent registry
                (make-agent 'planner-1
                            '((role planner)
                              (model qwen3:8b)
                              (description "Breaks work into local steps."))))
(register-agent registry
                (make-agent 'scheme-coder-1
                            '((role coder)
                              (model qwen2.5-coder:14b)
                              (description "Writes Consent Scheme code."))))
(register-agent registry
                (make-agent 'reviewer-1
                            '((role reviewer)
                              (model qwen2.5-coder:14b)
                              (description "Reviews Scheme and docs diffs."))))
(register-agent registry
                (make-agent 'memory-1
                            '((role memory-curator)
                              (model gemma3:12b)
                              (description "Summarizes durable session state."))))

(define local-harness
  (make-prompt-harness (list (list 'registry registry))))

(list (map agent-id (agents local-harness))
      (roles local-harness)
      (models local-harness))
```

Expected shape:

```scheme
((default planner-1 scheme-coder-1 reviewer-1 memory-1)
 (planner coder reviewer memory-curator)
 (auto qwen3:8b qwen2.5-coder:14b gemma3:12b))
```

The full model-provider reference, tool-call example, and opt-in live test
targets are in [Local Model Providers](getting-started.md#local-model-providers).
Provider hardening, streaming, and broader protocol documentation remain
separate follow-up work; this quick-start focuses on the first usable REPL
harness and local-role setup.
