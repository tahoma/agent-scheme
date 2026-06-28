# Executable Consent Scheme Scripts

A Consent Scheme source file can be marked executable and run directly from a
shell with a `#!` (shebang) line. This is the non-interactive twin of the
[portable terminal REPL shell](portable-repl.md): the REPL runs forms typed at a
prompt, an executable script runs forms from a file. Together they make the
runtime a usable program — interactive at the prompt, scriptable from the shell.

This document covers how a shebang reaches the interpreter, the two recommended
shebang forms and their tradeoffs, how the runtime recognizes and skips the
shebang line, exit-status and stream behavior, and the noninteractive
fail-closed policy posture a script inherits.

## How a shebang reaches the interpreter

When you run `./script.scm`, the operating-system kernel reads the first line.
If it begins with `#!`, the kernel treats the rest of that line as an interpreter
command and runs `interpreter [args] ./script.scm`. The interpreter then opens
the file and reads the whole thing — **including the `#!` line it was launched
from**, which the kernel does not strip. So the interpreter's reader has to skip
its own shebang line; that is what this feature adds (issue #399).

`#!` is not free in Scheme: it also prefixes reader directives (`#!fold-case`),
version flags (`#!r6rs`), named values (`#!eof`), and DSSSL keywords
(`#!optional`). So the runtime recognizes a shebang only **narrowly** — a `#!`
that is the first two bytes of the file followed by `/` or whitespace — and
consumes it at the script-loading boundary. Everywhere else, `#!fold-case` and
every other `#!`-token keep their normal reader meaning.

## Recommended forms

### Direct, with the bare interpreter name

```scheme
#!/usr/bin/env consent
(import (scheme base) (scheme write))
(display "hi\n")
```

`consent FILE` runs `FILE` as a script — the same as `consent --script FILE`, so
no flag is needed in the shebang. Make it executable and run it:

```sh
chmod +x script.scm
./script.scm
```

This requires the `consent` binary to be found by `env` on your `PATH`. The
host-compiled binary is built at `build/compile/<host>/bin/consent` (see
[development.md](development.md)); install or symlink it onto your `PATH` as
`consent`, or write the shebang with an absolute path:

```scheme
#!/absolute/path/to/consent
```

**Why no `--script` flag.** A flagged shebang such as
`#!/usr/bin/env consent --script` is fragile across systems. On Linux the kernel
passes everything after the interpreter path as a **single** argument, so `env`
receives the one token `"consent --script"` and fails to find a program by that
name. (macOS and the BSDs word-split the line, so the flagged form happens to
work there — which hides the bug on those machines.) Passing no flag avoids the
kernel's single-argument rule entirely, the same way `#!/usr/bin/env python`
works. `--script FILE` still works when you invoke the binary yourself; it is
just a poor fit for a shebang line.

### Portable `/bin/sh` polyglot

When the interpreter is **not** installed on `PATH` under a fixed name and you
want the script to locate it itself, use the `/bin/sh` polyglot. It is valid
both as a shell script and as a Consent Scheme program:

```scheme
#!/bin/sh
#|
exec consent --script "$0" "$@"
|#
(import (scheme base) (scheme write))
(display "hi\n")
```

It runs in two passes, and each program only reads part of the file:

1. **The shell.** The kernel sees `#!/bin/sh` and runs `/bin/sh ./script.scm`.
   To the shell, `#!/bin/sh` and `#|` are ordinary `#` comment lines, and
   `exec consent --script "$0" "$@"` is a command that **replaces the shell
   process** with the interpreter, pointed at this same file. The shell never
   reaches `|#` or the Scheme code below it.
2. **The interpreter.** Consent Scheme reads the same file as Scheme: it skips
   the `#!/bin/sh` shebang, reads `#| exec … |#` as a block comment — which hides
   the shell line from Scheme — and runs the program.

The polyglot's genuine advantages are that the kernel only ever needs `/bin/sh`
(always at a fixed path), the shell's word-splitting sidesteps the single-argument
rule so a flag like `--script` survives, and you can run real shell logic
(`PATH` setup, fallbacks, a path computed relative to the script) to find the
interpreter. It is **not** a way to avoid locating the interpreter: the `exec`
line still has to name something the shell can find, on `PATH` or by absolute
path.

## Exit status and streams

A script's program output goes to standard output; the runtime keeps its own
records and diagnostics off that stream, so a scripted consumer of program
output is never corrupted. A script ends successfully with exit status `0`. An
uncaught error fails the run with a nonzero status and a Scheme-readable error
record on the diagnostic stream. An explicit `(exit OBJ)` follows the standard
R7RS close-status rule: `(exit)`, `(exit #t)`, and `(exit 0)` close successfully;
any other object closes with an error status.

## Command-line arguments

Arguments after the script reach the process in both forms — the kernel appends
them after the script path for a direct shebang, and the polyglot's `"$@"`
forwards them through `exec`. Consent Scheme owns the script-facing
`(command-line)` value instead of exposing the host process vector, so the
contract is identical across hosts and invocation forms:

```scheme
;; consent --script tools/example.scm alpha beta
;; consent tools/example.scm alpha beta
(import (scheme base) (scheme process-context))
(command-line)
;; => ("tools/example.scm" "alpha" "beta")
```

The interpreter name and any `--script` token are removed. The first element is
the script path exactly as supplied to the script runner, followed by user
arguments. This value is invocation metadata, like stdio: it does not grant broad
process-environment access. Outside the script runner, `(command-line)` remains
policy-gated and fails closed without an explicit process-environment grant.

## Policy posture: noninteractive and fail-closed

A shebang script runs noninteractively. Where a script reaches the Consent
capability surface — the `(consent …)` and `(agent …)` runtime libraries — it
inherits the batch policy posture of the
[native CLI and daemon adapter contract](native-cli-daemon-adapter.md) and
**fails closed**: a confirm-gated action is denied unless it is covered by an
explicit grant, a command-line policy file, or a preloaded approval, and the
denial is recorded as a Scheme-readable audit record rather than raised as a
prompt. With no confirmation channel attached, anything that would prompt is
denied.

Both host script paths evaluate the file through the Consent interpreter
(`consent-eval-source`), so the posture applies fully and identically — the
host-compiled binary is **not** a host R7RS interpreter.

The discriminator is **standard streams vs ambient authority**. The three
standard streams are *consented by invocation* — they are what the shell handed
the process — so the CLI attaches them by default; everything else fails closed.

- **Standard streams work by default.** `consent FILE` / `--script` / `--eval`
  reads its stdin and writes stdout/stderr, so an ordinary
  `#!/usr/bin/env consent` filter (`(read-line)` in a loop, `(display …)` per
  line) just works in a pipe. Input is pulled on demand and output is flushed
  through immediately, so a filter streams a live or unbounded pipe incrementally
  rather than draining it up front. This is the program stream model in the
  [cross-host REPL interaction contract](repl-interaction-contract.md#program-stream-model):
  the host supplies the stream devices and one `port` grant per stream; the
  runtime connects `current-input-port`/`current-output-port`/`current-error-port`
  from them and audits every read/write. No raw host objects are exposed to script
  values.
- **Ambient effects still fail closed.** A confirm-gated capability — opening a
  named file, spawning a process, network, environment, clock, a provider — is
  denied in batch without a grant, policy file, or preloaded approval. An
  `(open-output-file …)` is denied and audited; the denial raises and the process
  exits non-zero. A script can shuttle data between its caller-provided stdin and
  stdout, but it cannot reach any ambient resource without an explicit grant.
- **Emacs batch runner (`consent-script-run-file`).** The same contract through
  the same `consent-eval-source`; a caller passes script arguments separately
  from evaluator options, and a caller that attaches stdio devices and grants gets
  the identical behavior.

White-box tests that `import` the runtime's internal libraries (for example
`(consent interpreter)`) are **not** scripts and do not run through this path:
they exercise the compiled libraries on a separate, non-shipped host-execution
test runner, never through `consent --script`. Host execution is not on the
product command surface.

## Promptable scripts

Batch scripts do not receive ambient model/provider authority. A script that
drives `(prompt …)` must pass a harness with an explicit `prompt-authority`
bundle. The bundle records the origin (`noninteractive`) and how authority was
preloaded (`grant`, `preloaded-approval`, or `policy-file`) so the prompt audit
distinguishes script-driven work from an interactive session.

```scheme
(import (scheme base) (agent prompt))

(define authority
  (make-prompt-authority
   '((origin noninteractive)
     (source grant)
     (grants ((capability-grant
               (id script-prompt)
               (domain provider)
               (operations complete)
               (expires never)))))))

(define harness
  (make-prompt-harness
   (list (list 'authority authority)
         (list 'max-steps 4))))

(prompt harness 'summarize
        '((provider ((finish done)))
          (verifier passed)))
```

A noninteractive bundle with no preloaded authority fails closed; it does not ask
the user at runtime:

```scheme
(import (scheme base) (agent prompt))

(define harness
  (make-prompt-harness
   (list (list 'authority
               (make-prompt-authority
                '((origin noninteractive)))))))

(define result (prompt harness 'summarize))

(prompt-result-status result)
;; => authority-missing

(cadr (assq 'reason (cdr (prompt-result-receipt result))))
;; => noninteractive-authority-unavailable
```

The denial audit is an `authority-denied` prompt audit carrying
`(origin noninteractive)` and `(source none)`. Budgets supplied on the harness or
per prompt call continue to flow to the task runner, so a trusted script still
runs under explicit resource limits. Requesting a stdio grant at runtime (rather
than by invocation) remains separate future work; connecting the standard streams
by invocation is in place here.

## Verification

The shebang-handling boundary is covered at host parity by
`tests/scheme/consent-script-test.scm` (every portable R7RS host) and
`tests/consent-script-test.el` (the Emacs host), both of which assert the narrow
recognition rule, the line-preserving strip, and that `#!fold-case` still reads
normally. The host-compiled build additionally runs end-to-end smokes that make
a real file executable and run the bare-path and `/bin/sh`-polyglot forms against
the compiled binary, and that assert the Consent-not-host discriminator: a pure
script evaluates and exits 0, while an ungranted file write through `--script`, a
bare-path script, or `--eval` is denied and leaves no file. Run the default suite
with:

```sh
make test
```
