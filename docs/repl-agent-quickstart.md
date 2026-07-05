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
The small-laptop profile is a real local setup, but keep its first encounter
bounded: use it for route checks, grounded review, and the scaffolded tutorial
below rather than expecting reliable greenfield Scheme from the 7B coder.

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
session surfaces. The Scheme forms below are the same in both runtimes. The
current portable OpenAI-compatible transport lowers the host effect through the
portable process host and `curl`, so live completions need a portable host that
can spawn local processes and an Ollama server listening on the loopback
endpoint.

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
is about fifteen minutes once the models are available. The prompts are
intentionally grounded and bounded: the model suggests the work, drafts a small
piece of Scheme, the REPL evaluates it, and the reviewer and memory roles see
the actual evaluation facts rather than guessing from an empty prompt.

First capture the planner's work breakdown in `plan`, then print it so the
next prompt has a named value to reuse:

```scheme
(import (scheme write))

(define plan
  (model-complete
   'planner
   "Plan a tiny R7RS Scheme symbolic differentiator tutorial.
    Use only ASCII text. Do not write code.
    The implementation will represent sums as (+ left right), products as
    (* left right), and will test d/dx of x, y, (+ (* x x) (* 3 x)), and
    (* x (+ x 3)). Reply with exactly five numbered steps for a
    beginner-friendly REPL workloop."
   '((temperature 0.1) (timeout-seconds 300))))

(display plan)
```

Then capture the Scheme coding role's draft in `code`. The prompt includes the
planner's output plus strict constraints so the model works inside the small
R7RS surface that the tutorial will evaluate:

```scheme
(define code
  (model-complete
   'scheme-scripter
   (string-append
    plan
    "

Return plain portable R7RS Scheme source only.
Do not use Markdown fences, prose, #lang, library forms, square brackets,
quasiquote, display, printf, for-each, pass/fail symbols, or implementation
extensions. Use only define, cond, and, or, if, number?, symbol?, pair?,
car, eq?, =, +, *, list, cadr, caddr, and equal?.
Return exactly seven top-level forms in this order:
1. (define (=number? expression value) ...)
2. (define (make-sum left right) ...)
3. (define (make-product left right) ...)
4. (define (sum? expression) ...)
5. (define (product? expression) ...)
6. (define (deriv expression variable) ...)
7. (define differentiator-tests (list ...))
Sums are (+ left right). Products are (* left right).
Simplify addition by 0, multiplication by 0 and 1, and numeric constant
folding. differentiator-tests must be a four-result boolean list, and every
element must use equal?:
(equal? (deriv 'x 'x) 1)
(equal? (deriv 'y 'x) 0)
(equal? (deriv '(+ (* x x) (* 3 x)) 'x) '(+ (+ x x) 3))
(equal? (deriv '(* x (+ x 3)) 'x) '(+ x (+ x 3)))
The expected value of differentiator-tests is exactly (#t #t #t #t).")
   '((temperature 0.1) (timeout-seconds 300))))

(display code)
```

If the model returns a fenced code block, paste only the Scheme inside the
fence. Evaluate the model's draft when it has the seven requested forms. Keep
`code` available for inspection, but let the REPL's evaluated values drive the
review and memory prompts. The REPL is the authority: if the draft does not
produce the expected test value, use the known-good baseline below to keep the
tutorial moving and compare the model's differences against a working program.

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
```

After either the model draft or the known-good baseline has defined `deriv` and
`differentiator-tests`, capture the facts that later model prompts will reuse:

```scheme
(import (scheme write))

(define (datum->text datum)
  (let ((port (open-output-string)))
    (write datum port)
    (get-output-string port)))

(define test-results differentiator-tests)
(define sample-derivative
  (deriv '(+ (* x x) (* 3 x)) 'x))

(list test-results sample-derivative)
```

The expected evaluation record is:

```scheme
((#t #t #t #t) (+ (+ x x) 3))
```

Now capture the reviewer response in `review`, building its prompt from the
actual evaluated values:

```scheme
(define review
  (model-complete
   'reviewer
   (string-append
    "Review this R7RS Scheme symbolic differentiator result.
Facts: tests returned "
    (datum->text test-results)
    ".
The derivative of (+ (* x x) (* 3 x)) returned "
    (datum->text sample-derivative)
    ".
Use only these facts. Reply with exactly three bullets:
strength, limitation, next extension.")
   '((temperature 0.1) (timeout-seconds 300))))

(display review)
```

Finally capture a durable session note in `session-note`, reusing the same
evaluated facts and the reviewer response:

```scheme
(define session-note
  (model-complete
   'memory-curator
   (string-append
    "Summarize durable facts from this exact Consent Scheme REPL tutorial.
Use only facts in this prompt. Do not add external platforms, frameworks,
APIs, deployment details, or cloud-service details.
Facts:
- Local Ollama provider local-ollama was registered with roles planner,
  scheme-scripter, reviewer, and memory-curator.
- The tutorial built a tiny R7RS Scheme symbolic differentiator using
  Scheme lists for sums and products.
- Evaluation returned "
    (datum->text test-results)
    " for the four tests.
- d/dx of (+ (* x x) (* 3 x)) returned "
    (datum->text sample-derivative)
    ".
- Reviewer response:
"
    review
    "
Reply with exactly three ASCII bullets.")
   '((temperature 0.1) (timeout-seconds 300))))

(display session-note)
```

At that point the first encounter has exercised the real local model path:
planner, Scheme coder, evaluator, reviewer, and memory curator. It has also
produced an inspectable Scheme program rather than only a transport check.

## Runtime Notes

The Emacs-hosted runtime and the portable standalone runtime share the
`(agent models)` registration, routing, and `model-complete` surface. The
portable implementation lowers OpenAI-compatible HTTP through the process host
shim and `curl` today because R7RS-small standardizes ports but not sockets,
TLS, HTTP, proxies, or certificate handling. That `curl` backend is a host
adapter detail, not part of the Scheme-facing model API; future host adapters
can replace it with native networking while preserving the same Scheme forms.
The Gambit-compiled binary is the recommended standalone runtime: Gambit is
required to build it, but not to run the installed `consent` executable. The
plain `tools/consent-repl` launcher is the interpreted development path and
works on Chibi, Guile, or Gauche when that host can spawn `curl`.

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
