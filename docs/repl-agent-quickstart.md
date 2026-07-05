# REPL Agent Harness Quick Start

This is the hands-on path from a checkout to a real local model-backed REPL
workloop. Start by installing the portable runtime path and a practical local
role set, then use the same Scheme forms from either the portable terminal REPL
or the Emacs-hosted REPL.

The first tutorial builds a small symbolic differentiator in the SICP
tradition: algebra is Scheme data, the derivative rules are Scheme procedures,
and the REPL uses local models for planning, coding, review, and memory
curation. The examples use actual `model-complete` calls through an
OpenAI-compatible local endpoint and the role assignments you configure below.

## Install the Portable Runtime

For the best standalone first encounter, build and install the portable runtime
with Gambit. Gambit is the build-time host Scheme: `gsi` reads the portable R7RS
sources, `gsc` compiles them, and the resulting `consent` executable runs
without needing another Scheme implementation on `PATH`.

Install Gambit so `gsi` and `gsc` are available, then build the default
host-compiled executable:

```sh
make compile
build/compile/gambit/bin/consent --version
```

You can run it directly from the checkout:

```sh
build/compile/gambit/bin/consent --repl \
  --session symbolic-agent-tour --chrome quiet
```

Or install it under a user prefix. Use the same `PREFIX` for `make compile`
and `make install` so the installed binary knows where its runtime library tree
lives:

```sh
make compile PREFIX="$HOME/.local"
make install PREFIX="$HOME/.local"
"$HOME/.local/bin/consent" --repl \
  --session symbolic-agent-tour --chrome quiet
```

The interpreted launcher is still useful while hacking from a checkout, but it
is not hostless. It needs Chibi, Guile, or Gauche on `PATH`, and you can select
the host explicitly:

```sh
CONSENT_REPL_HOST=guile tools/consent-repl \
  --session symbolic-agent-tour --chrome quiet
```

Use the Gambit-compiled `consent --repl` path when you want the faster portable
standalone runtime without an active host Scheme. Use `tools/consent-repl` when
you specifically want to exercise the interpreted launcher against Chibi, Guile,
or Gauche.

## Install the Local Role Set

Ollama is the simplest local OpenAI-compatible provider to use while this layer
is bootstrapping. Install Ollama for your platform, then pull the profile that
matches the machine you are actually using:

| Machine profile | Pull these first |
| --- | --- |
| Small laptop, 8-16 GB memory | `qwen2.5-coder:7b`, `qwen3:4b`, `gemma3:4b` |
| Developer laptop, 16-32 GB memory | `qwen2.5-coder:14b`, `qwen3:8b`, `gemma3:12b` |
| Large local box, 48 GB+ memory | `qwen2.5-coder:32b`, `qwen3:30b`, `gemma3:12b` |

The developer-laptop profile is the recommended first setup. It gives a useful
coding model, a useful planning model, and a useful summarization/memory model
without requiring 30B+ downloads. On a large machine, add `llama3.1:70b` for
slower planning or review passes when latency and disk use are acceptable.

For the recommended profile:

```sh
ollama pull qwen2.5-coder:14b
ollama pull qwen3:8b
ollama pull gemma3:12b
ollama serve
```

For a smaller machine:

```sh
ollama pull qwen2.5-coder:7b
ollama pull qwen3:4b
ollama pull gemma3:4b
ollama serve
```

The local OpenAI-compatible endpoint is `http://127.0.0.1:11434/v1`.

## Start a REPL

If you built the Gambit standalone runtime above, start the tutorial REPL with:

```sh
build/compile/gambit/bin/consent --repl \
  --session symbolic-agent-tour --chrome quiet
```

or, after `make install PREFIX="$HOME/.local"`:

```sh
"$HOME/.local/bin/consent" --repl \
  --session symbolic-agent-tour --chrome quiet
```

The interpreted portable launcher starts from the repository root when Chibi,
Guile, or Gauche is installed:

```sh
tools/consent-repl --session symbolic-agent-tour --chrome quiet
```

The Emacs-hosted batch entry uses the same REPL contract:

```sh
emacs -Q --batch -L lisp -l consent-repl-stream \
  -f consent-repl-stream-main
```

For an interactive Emacs buffer, load the checkout and run
`M-x consent-repl-comint`:

```elisp
(add-to-list 'load-path (expand-file-name "lisp" "/path/to/consent/"))
(require 'consent-repl-comint)
```

Use the portable terminal REPL when you want the R7RS path, with the
Gambit-compiled binary as the recommended standalone entry. Use the Emacs-hosted
REPL when you want the Emacs buffer, event, audit, approval, and interactive
session surfaces. The Scheme forms below are the same in both runtimes when the
portable host can spawn `curl` and Ollama is running locally.

## Register Local Models

Paste this into the REPL. It registers Ollama as the local provider and maps the
downloaded models to concrete agent roles:

```scheme
(import (scheme base)
        (agent models))

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

If you pulled the smaller profile, replace those model ids with
`qwen2.5-coder:7b`, `qwen3:4b`, and `gemma3:4b`. If you pulled the large profile,
use `qwen2.5-coder:32b` for `scheme-scripter`, `coder`, and `reviewer`;
`qwen3:30b` for `planner`; and `gemma3:12b` for `summarizer` and
`memory-curator`.

Check that the roles route to the expected local models:

```scheme
(list (model-route 'planner '())
      (model-route 'scheme-scripter '())
      (model-route 'reviewer '())
      (model-route 'memory-curator '()))
```

Look for `status selected`, provider `local-ollama`, and the model ids you
registered.

## Fifteen-Minute Tutorial Project

This project uses the local role set to build and review a small symbolic
differentiator. Model download time depends on your network; the tutorial itself
is about fifteen minutes once the models are available.

First ask the planner for the work breakdown:

```scheme
(model-complete
 'planner
 "Plan a tiny R7RS Scheme symbolic differentiator tutorial. Use lists for
  sums and products, keep the implementation small, and include tests for
  d/dx of x, y, (+ (* x x) (* 3 x)), and (* x (+ x 3)). Reply with a compact
  ordered plan."
 '((temperature 0.2) (timeout-seconds 180)))
```

Then ask the Scheme coding role to draft the implementation:

```scheme
(model-complete
 'scheme-scripter
 "Write portable R7RS Scheme code for a tiny symbolic differentiator. Represent
  sums as '(+ left right), products as '(* left right), simplify addition by 0,
  simplify multiplication by 0 and 1, and implement (deriv expression variable).
  Include a four-result test list for x, y, (+ (* x x) (* 3 x)), and
  (* x (+ x 3))."
 '((temperature 0.2) (timeout-seconds 240)))
```

If the coder gives you a different valid implementation, paste that into the
REPL and run its tests. The version below is a known-good baseline you can use
to keep the tutorial moving or to compare against the model's draft:

```scheme
(import (scheme cxr))

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
```

The expected evaluation records include:

```scheme
(#t #t #t #t)
(+ (+ x x) 3)
```

Now send the result to the reviewer role:

```scheme
(model-complete
 'reviewer
 "Review this tiny Scheme symbolic differentiator result. The tests returned
  (#t #t #t #t), and d/dx of (+ (* x x) (* 3 x)) returned (+ (+ x x) 3).
  Identify one strength, one limitation, and one next extension that would be
  useful for a new Scheme user."
 '((temperature 0.2) (timeout-seconds 180)))
```

Finally capture a durable session note:

```scheme
(model-complete
 'memory-curator
 "Summarize the durable facts from this tutorial in three bullets: local role
  setup, the symbolic differentiator behavior, and the next extension to try."
 '((temperature 0.2) (timeout-seconds 180)))
```

At that point the first encounter has exercised the real local model path:
planner, Scheme coder, evaluator, reviewer, and memory curator. It has also
produced an inspectable Scheme program rather than only a transport check.

## Runtime Notes

The Emacs-hosted runtime and the portable standalone runtime share the
`(agent models)` registration, routing, and `model-complete` surface. The
portable implementation lowers OpenAI-compatible HTTP through the process host
shim and `curl`, so live completion needs a portable runtime that can spawn
processes. The Gambit-compiled binary is the recommended standalone runtime:
Gambit is required to build it, but not to run the installed `consent`
executable. The plain `tools/consent-repl` launcher is the interpreted
development path and works on Chibi, Guile, or Gauche when that host can spawn
`curl`.

If a portable host reports that process spawning is unavailable, use the
Emacs-hosted REPL for the live local-model tutorial and keep the portable REPL
for host-neutral Scheme evaluation, sessions, role registration, and route
inspection until that host adapter is available.

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

For compact machine-readable records, use:

```sh
printf '(+ 1 2)\n(exit)\n' \
  | tools/consent-repl --session quickstart --chrome datum
```

The installed standalone binary accepts the same REPL options:

```sh
printf '(+ 1 2)\n(exit)\n' \
  | consent --repl --session quickstart --chrome datum
```

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
The plain `tools/consent-repl` launcher keeps this default-deny posture; hosts
that need to demonstrate granted session mutation pass evaluator options to the
REPL driver.

## Inspect Providers

Use route and diagnostics records instead of scraping model output:

```scheme
(model-route 'scheme-scripter '())
(model-provider-diagnostics)
```

The route record tells you which provider and model were selected for a role.
Diagnostics records show provider ids, transports, endpoints, roles, model
status, and redacted credentials.

## References

The complete REPL reference is [Using the Consent Scheme REPL](repl.md). The
portable shell details are in [Portable Terminal REPL Shell](portable-repl.md),
and the host-neutral record vocabulary is in
[Cross-Host REPL Interaction Contract](repl-interaction-contract.md).

The model-provider reference, tool-call example, and opt-in live test targets
are in [Local Model Providers](getting-started.md#local-model-providers). The
broader task lifecycle is in [Task Lifecycle and Control Loop](control-loop.md).
Capability and provider authority are described in
[Capability Environment and Effect Lowering](capability-environment.md), and
budget behavior is in [Evaluation Budgets](budgets.md).
