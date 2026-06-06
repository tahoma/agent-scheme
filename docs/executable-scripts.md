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
forwards them through `exec`. Today a script reads them through the host's R7RS
`(command-line)` from `(scheme process-context)`, which on the host-compiled
binary returns the raw process arguments: the interpreter as element 0 (on some
hosts as a non-string path object), then — for the `--script` form — the literal
`"--script"`, then the script path, then the user arguments. The layout is the
host's and differs between the bare-path and `--script` forms, so treat it as
host-defined for now.

A normalized, host-identical contract — `(command-line)` returning
`(script-path arg …)` with the interpreter name and any `--script` token removed
— is deferred to the consent-runtime script model (issue #400), where the runtime
owns `command-line` directly and can present the same clean vector on every host.
Under the host-load model used here, the interpreter cannot relocate element 0
(for example Racket pins it to the executable's run file), so a clean contract is
not deliverable without that runtime-owned evaluation.

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

How completely this applies depends on how the file is evaluated, which differs
by host — as it does throughout the project — while the shebang handling itself
is identical:

- **Host-compiled binary (`consent FILE` / `--script`).** The file is loaded as
  an ordinary R7RS program, so it may `import` standard libraries and runs with
  the host's R7RS power; raw host primitives such as the host's own
  `(scheme file)` are not themselves gated. Confirm-gated *Consent capabilities*
  still fail closed in batch. Run only scripts you trust here, the same trust
  model as `python script.py`.
- **Consent-runtime evaluation (the Emacs batch runner `consent-script-run-file`).**
  The file is evaluated through the consent runtime, where the standard library
  is itself capability-gated: a `(file-exists? …)` is denied and audited as a
  `standard-host-effect`, no raw host objects are exposed to script values, and
  even program output (`display`) is a gated host effect. This path runs scripts
  that compute and act through Consent capabilities, but does not yet stream
  captured program output — that needs the output-capturing interaction context
  (see below).

Tightening the host-compiled script path into the same fully sandboxed,
no-raw-host posture means running scripts through the consent interaction context
rather than the host loader — the non-interactive twin of the REPL. That
substrate exists on the portable host (it shipped with the terminal REPL, #360)
but not yet on the Emacs host, where it is the still-open Emacs REPL parity entry
(#391). So fully sandboxed script execution at cross-host parity is sequenced
after #391, and lands with the promptable non-interactive script authority work
(#400), which also admits *promptable* scripts that call `(prompt …)`. This
feature ships shebang handling at parity and host-R7RS execution, and ensures
Consent confirm-gated actions fail closed.

## Verification

The shebang-handling boundary is covered at host parity by
`tests/scheme/consent-script-test.scm` (every portable R7RS host) and
`tests/consent-script-test.el` (the Emacs host), both of which assert the narrow
recognition rule, the line-preserving strip, and that `#!fold-case` still reads
normally. The host-compiled build additionally runs an end-to-end smoke that
makes a real file executable and runs both the bare-path and `/bin/sh`-polyglot
forms against the compiled binary. Run the default suite with:

```sh
make test
```
