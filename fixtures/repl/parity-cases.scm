;;; parity-cases.scm --- Shared cross-host REPL parity conformance corpus
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;; This file is intentionally Scheme-readable data.  It is the host-neutral
;; conformance corpus for the cross-host REPL interaction contract
;; (docs/repl-interaction-contract.md).  Two parallel runners drive the SAME
;; cases against both REPL hosts and assert each case's expected record
;; sequence:
;;
;;   - tests/scheme/consent-repl-parity-test.scm drives the portable terminal
;;     REPL shell `(cli repl-shell)';
;;   - tests/consent-repl-parity-test.el drives the Emacs incremental stdin REPL
;;     `consent-repl-stream'.
;;
;; Each host reads this corpus with its own Consent reader and compares the
;; expectations to the records its REPL emits, so a host that drifts from the
;; contract fails its runner.  Because the corpus is one shared file, both hosts
;; are held to the same record vocabulary, field values, and ordering.
;;
;; Conformance scope (docs/repl-interaction-contract.md "Forward Compatibility"):
;; v1 cases assert synchronous, positional record ordering for a single
;; foreground turn.  The runners correlate a `repl-result'/`repl-condition' to
;; its submission by the `(submission sub-N)' field -- the durable join -- rather
;; than by record position, and they do not assume a recoverable condition always
;; continues at the same interaction level.  Those two assumptions are
;; revision-scoped, not contract-permanent.
;;
;; A case `expect' enumerates EVERY record the turn produces, in order.  The
;; runners assert per-kind record counts as well as field values, so an extra,
;; missing, or reshaped record is a failure.  Field assertions are deliberately a
;; subset of each record: only contract-meaningful, host-neutral fields are
;; pinned.  Host-specific text (condition `message'/`display' strings, the opaque
;; `value'/`budget' payloads) is intentionally NOT asserted, since the contract
;; fixes the record shape, not a host's exact human-readable rendering.

(consent-fixture-suite
  (kind repl-parity)
  (version 1)
  (contract
    (repl-interaction-contract
      (version 1)
      (session-scopes (named project))
      (interaction-environment (scheme repl))))
  (cases

    ((id repl-eval-simple)
     (description "A simple expression renders its value and closes cleanly on EOF.")
     (session "project-main")
     (options ())
     (input "(+ 1 2)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "(+ 1 2)") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "3"))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 1) (detail #f)))))

    ((id repl-session-persistence)
     (description "Imports, definitions, and macros persist across separately submitted forms.")
     (session "project-main")
     (options ())
     (input "(import (scheme base))\n(define base 20)\n(define-syntax inc (syntax-rules () ((_ v) (+ v 1))))\n(inc base)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "(import (scheme base))") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status ok))))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-submission (id sub-2) (ordinal 2) (source "(define base 20)") (complete #t) (eof #f))
        (repl-result (id res-2) (submission sub-2)
                     (evaluation-result (evaluation-result (status ok))))
        (repl-prompt (ordinal 3) (state ready) (pending #f))
        (repl-submission (id sub-3) (ordinal 3) (source "(define-syntax inc (syntax-rules () ((_ v) (+ v 1))))") (complete #t) (eof #f))
        (repl-result (id res-3) (submission sub-3)
                     (evaluation-result (evaluation-result (status ok))))
        (repl-prompt (ordinal 4) (state ready) (pending #f))
        (repl-submission (id sub-4) (ordinal 4) (source "(inc base)") (complete #t) (eof #f))
        (repl-result (id res-4) (submission sub-4)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "21"))
        (repl-prompt (ordinal 5) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 4) (detail #f)))))

    ((id repl-recoverable-eval-condition)
     (description "A recoverable evaluator condition keeps the session open for the next form.")
     (session "project-main")
     (options ())
     (input "undefined-name\n(+ 4 5)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "undefined-name") (complete #t) (eof #f))
        (repl-condition (id cond-1) (submission sub-1) (phase eval) (recoverable #t))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-submission (id sub-2) (ordinal 2) (source "(+ 4 5)") (complete #t) (eof #f))
        (repl-result (id res-2) (submission sub-2)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "9"))
        (repl-prompt (ordinal 3) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 2) (detail #f)))))

    ((id repl-recoverable-read-condition)
     (description "A recoverable reader condition resynchronizes and keeps the session open.")
     (session "project-main")
     (options ())
     (input ")\n(+ 6 7)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-condition (id cond-1) (submission sub-1) (phase read) (recoverable #t)
                        (condition (condition (type reader-error))))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-submission (id sub-2) (ordinal 2) (source "(+ 6 7)") (complete #t) (eof #f))
        (repl-result (id res-2) (submission sub-2)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "13"))
        (repl-prompt (ordinal 3) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 1) (detail #f)))))

    ((id repl-incomplete-continuation)
     (description "An incomplete form is continued under one submission, not reported as a hard error.")
     (session "project-main")
     (options ())
     (input "(+ 1\n2)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-prompt (ordinal 1) (state continuation) (pending #t))
        (repl-submission (id sub-1) (ordinal 1) (source "(+ 1\n2)") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "3"))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 1) (detail #f)))))

    ((id repl-multiple-forms-one-chunk)
     (description "Several complete forms in one input chunk evaluate in order, one submission each.")
     (session "project-main")
     (options ())
     (input "(+ 1 2) (* 3 4)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "(+ 1 2)") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "3"))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-submission (id sub-2) (ordinal 2) (source "(* 3 4)") (complete #t) (eof #f))
        (repl-result (id res-2) (submission sub-2)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "12"))
        (repl-prompt (ordinal 3) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 2) (detail #f)))))

    ((id repl-multiple-values)
     (description "A multiple-value result renders through the values evaluation-result datum.")
     (session "project-main")
     (options ())
     (input "(values 1 2)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "(values 1 2)") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status values)))
                     (display "(values 1 2)"))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 1) (detail #f)))))

    ((id repl-zero-values)
     (description "A zero-value result renders the empty values evaluation-result datum.")
     (session "project-main")
     (options ())
     (input "(values)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "(values)") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status values)))
                     (display "(values)"))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 1) (detail #f)))))

    ((id repl-eof-mid-form)
     (description "EOF while a partial form is buffered closes with the documented error status.")
     (session "project-main")
     (options ())
     (input "(+ 1\n")
     (expect
       ;; The continuation prompt is a request for more input, emitted before the
       ;; read that then returns EOF: reaching the incomplete branch always means
       ;; a partial form is buffered, so the gutter is shown and the user then
       ;; ends input (Ctrl-D).
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-prompt (ordinal 1) (state continuation) (pending #t))
        (repl-submission (id sub-1) (ordinal 1) (source "(+ 1") (complete #f) (eof #t))
        (repl-condition (id cond-1) (submission sub-1) (phase read) (recoverable #f)
                        (condition (condition (type reader-error))))
        (repl-exit (reason eof) (status closed-error) (count 0)
                   (detail "unterminated form at end of input")))))

    ((id repl-explicit-exit)
     (description "An explicit exit request closes the session after the current submission.")
     (session "project-main")
     (options ())
     (input "(+ 1 2)\n(exit)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "(+ 1 2)") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status ok)))
                     (display "3"))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-submission (id sub-2) (ordinal 2) (source "(exit)") (complete #t) (eof #f))
        (repl-exit (reason explicit) (status closed-ok) (count 2) (detail #f)))))

    ((id repl-policy-denied-default)
     (description "The default policy denies an ungranted host effect, failing closed without ending the session.")
     (session "project-main")
     (options ())
     (input "(begin (import (scheme file)) (open-output-file \"/tmp/consent-repl-parity-denied\"))\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1)
                         (source "(begin (import (scheme file)) (open-output-file \"/tmp/consent-repl-parity-denied\"))")
                         (complete #t) (eof #f))
        (repl-condition (id cond-1) (submission sub-1) (phase eval) (recoverable #t)
                        (condition (condition (type policy-denial))))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 1) (detail #f)))))

    ((id repl-policy-denied-interaction-environment)
     (description "A session-policy denial of the interaction environment fails closed as a policy denial.")
     (session "project-main")
     (options ((policy-actions ((standard-host-effect deny)))))
     (input "(import (scheme base) (scheme repl))\n(interaction-environment)\n")
     (expect
       ((repl-prompt (ordinal 1) (state ready) (pending #f))
        (repl-submission (id sub-1) (ordinal 1) (source "(import (scheme base) (scheme repl))") (complete #t) (eof #f))
        (repl-result (id res-1) (submission sub-1)
                     (evaluation-result (evaluation-result (status ok))))
        (repl-prompt (ordinal 2) (state ready) (pending #f))
        (repl-submission (id sub-2) (ordinal 2) (source "(interaction-environment)") (complete #t) (eof #f))
        (repl-condition (id cond-2) (submission sub-2) (phase eval) (recoverable #t)
                        (condition (condition (type policy-denial))))
        (repl-prompt (ordinal 3) (state ready) (pending #f))
        (repl-exit (reason eof) (status closed-ok) (count 2) (detail #f)))))))
