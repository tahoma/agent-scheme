;;; agent-scheme-reflect-test.el --- Runtime reflection tests  -*- lexical-binding: t; -*-

;;; Commentary:

;; Focused coverage for the `(agent reflect)' library: capability metadata,
;; budgets, imports, recent event/error inspection, and redaction at the
;; reflection boundary.

;;; Code:

(require 'ert)
(require 'agent-scheme-audit)
(require 'agent-scheme-eval)
(require 'agent-scheme-policy)
(require 'agent-scheme-redaction)
(require 'agent-scheme-reflect)
(require 'agent-scheme-result)
(require 'agent-scheme-session)

(defun agent-scheme-reflect-test--value-external (value)
  "Return VALUE as stable Agent Scheme value text."
  (agent-scheme-value->external value))

(defun agent-scheme-reflect-test--eval-value-string (source &optional options)
  "Evaluate SOURCE and return its external value string."
  (agent-scheme-reflect-test--value-external
   (agent-scheme-eval-source source nil options)))

(defun agent-scheme-reflect-test--reset ()
  "Reset shared state touched by reflection tests."
  (agent-scheme-redaction-clear!)
  (agent-scheme-session-clear!)
  (agent-scheme-audit-clear))

(ert-deftest agent-scheme-reflect-test-runtime-version-is-canonical-triple ()
  "Expose the Agent Scheme runtime version through `(agent reflect)'."
  (agent-scheme-reflect-test--reset)
  (should
   (equal
    (agent-scheme-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (let ((version (agent-scheme-version)))
        (list version
              (map exact-integer? (cdr version))
              (map (lambda (component) (>= component 0))
                   (cdr version))))")
    "((agent-scheme-version 0 14 11) (#t #t #t) (#t #t #t))")))

(ert-deftest agent-scheme-reflect-test-simple-string-docstrings ()
  "Expose simple procedure docstrings through `(agent reflect)'."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (define (field datum name)
             (cadr (assq name (cdr datum))))
           (define (metadata-field datum name)
             (let ((entry (assq name (field datum 'fields))))
               (if entry (cadr entry) #f)))
           (define (doc-string datum)
             (metadata-field datum 'documentation))
           (define (arguments datum)
             (metadata-field datum 'arguments))
           (define (documented x)
             \"Return X plus one.\"
             (+ x 1))
           (list (documented 4)
                 (field (documentation 'documented) 'subject)
                 (arguments (documentation 'documented))
                 (doc-string (documentation 'documented))
                 (field (documentation documented) 'subject)
                 (arguments (documentation documented))
                 (doc-string (documentation documented)))")))
    (should
     (equal external
            "(5 (binding documented) (x) \"Return X plus one.\" (procedure) (x) \"Return X plus one.\")"))))

(ert-deftest agent-scheme-reflect-test-documentation-arguments-metadata ()
  "Reflect procedure arguments as symbolic documentation metadata."
  (agent-scheme-reflect-test--reset)
  (should
   (equal
    (agent-scheme-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (metadata-field subject name)
        (let ((datum (documentation subject)))
          (if datum
              (let ((entry (assq name (field datum 'fields))))
                (if entry (cadr entry) #f))
            #f)))
      (define (proper first second)
        (+ first second))
      (define (dotted head . tail)
        tail)
      (define variadic
        (lambda all
          all))
      (define (empty)
        0)
      (list (metadata-field 'proper 'arguments)
            (metadata-field 'dotted 'arguments)
            (metadata-field 'variadic 'arguments)
            (metadata-field 'empty 'arguments)
            (map symbol? (metadata-field 'proper 'arguments))
            (symbol? (metadata-field 'variadic 'arguments)))")
    "((first second) (head . tail) all () (#t #t) #t)")))

(ert-deftest agent-scheme-reflect-test-primitive-manifest-docstrings ()
  "Reflect primitive docs supplied by manifest metadata."
  (agent-scheme-reflect-test--reset)
  (should
   (equal
    (agent-scheme-reflect-test--eval-value-string
     "(import (scheme base) (scheme time) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (metadata-field subject name)
        (let ((datum (documentation subject)))
          (if datum
              (let ((entry (assq name (field datum 'fields))))
                (if entry (cadr entry) #f))
            #f)))
      (list (field (documentation '+) 'subject)
            (field (documentation '+) 'library)
            (field (documentation '+) 'source)
            (field (documentation '+) 'origin)
            (metadata-field '+ 'documentation)
            (field (documentation +) 'subject)
            (metadata-field + 'documentation)
            (field (documentation 'current-second) 'library)
            (field (documentation 'current-second) 'source)
            (field (documentation 'current-second) 'origin)
            (metadata-field 'current-second 'documentation))")
    "((binding +) (scheme base) kernel (primitive-manifest string) \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" (procedure) \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" (scheme time) host-capability (primitive-manifest string) \"Return the current time as a real number of seconds since the Unix epoch, subject to the clock capability policy.\")")))

(ert-deftest agent-scheme-reflect-test-docstring-edge-cases ()
  "Reflect adjacent docstrings and preserve final-string body semantics."
  (agent-scheme-reflect-test--reset)
  (should
   (equal
    (agent-scheme-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (metadata-field datum name)
        (let ((entry (and datum (assq name (field datum 'fields)))))
          (if entry (cadr entry) #f)))
      (define (doc-string datum)
        (metadata-field datum 'documentation))
      (define (arguments datum)
        (metadata-field datum 'arguments))
      (define (multiline x)
        \"First line.\"
        \"Second line.\"
        x)
      (define (with-internal x)
        (define local 2)
        \"Use the local definition.\"
        (+ x local))
      (define (final-string)
        \"result\")
      (define (no-doc x)
        x)
      (list (doc-string (documentation 'multiline))
            (arguments (documentation 'multiline))
            (with-internal 3)
            (doc-string (documentation 'with-internal))
            (arguments (documentation 'with-internal))
            (final-string)
            (doc-string (documentation 'final-string))
            (arguments (documentation 'final-string))
            (doc-string (documentation 'no-doc))
            (arguments (documentation 'no-doc))
            (doc-string (documentation 'missing)))")
    "(\"First line.\\nSecond line.\" (x) 5 \"Use the local definition.\" (x) \"result\" #f () #f (x) #f)")))

(ert-deftest agent-scheme-reflect-test-rich-documentation-metadata ()
  "Reflect rich documentation records and malformed metadata behavior."
  (agent-scheme-reflect-test--reset)
  (should
   (equal
    (agent-scheme-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (metadata-fields name)
        (let ((datum (documentation name)))
          (if datum
              (field datum 'fields)
            #f)))
      (define (metadata-field name field-name)
        (let ((fields (metadata-fields name)))
          (if fields
              (let ((entry (assq field-name fields)))
                (if entry (cadr entry) #f))
            #f)))
      (define (rich config)
        \"Create an Agent Scheme session from CONFIG.\"
        \"The session is represented as a datum.\"
        #((summary . \"Open an Agent Scheme session.\")
          (parameters . ((config . \"Session configuration datum.\")))
          (returns . \"A session record.\")
          (effects . (pure))
          (examples . (((source . \"(rich cfg)\")
                        (result . (session cfg)))))
          (see-also . (current-context session-snapshot))
          (since . (agent-scheme-version 0 14 11))
          (deprecated . #f)
          (stability . experimental)
          (authority-review . \"local only\"))
        (list 'session config))
      (define (merged x)
        \"Line one.\"
        #((documentation . \"Line two.\")
          (examples . (((source . \"first\"))))
          (see-also . (alpha))
          (parameters . ((x . \"Input value.\"))))
        #((documentation . \"Line three.\")
          (examples . (((source . \"second\"))))
          (see-also . (beta))
          (custom-field . ((tag . kept))))
        x)
      (define (duplicate-scalar x)
        \"Valid documentation.\"
        #((returns . \"First result.\"))
        #((returns . \"Duplicate result.\")
          (summary . \"Ignored with malformed literal.\"))
        x)
      (define (duplicate-parameter x)
        #((parameters . ((x . \"First parameter.\")
                         (x . \"Duplicate parameter.\")))
          (returns . \"Ignored with malformed literal.\"))
        x)
      (define (malformed-vector x)
        #((summary . \"Malformed record.\") broken)
        x)
      (define (unknown-parameter x)
        #((parameters . ((y . \"Not bound by the procedure.\")))
          (returns . \"Ignored with malformed literal.\"))
        x)
      (define (rest-parameter head . tail)
        #((parameters . ((head . \"Required argument.\")
                         (tail . \"Rest arguments.\"))))
        tail)
      (define (final-rich)
        #((returns . \"ordinary result\")))
      (list (rich 'cfg)
            (metadata-field 'rich 'documentation)
            (metadata-field 'rich 'arguments)
            (metadata-field 'rich 'summary)
            (metadata-field 'rich 'parameters)
            (metadata-field 'rich 'returns)
            (metadata-field 'rich 'effects)
            (metadata-field 'rich 'examples)
            (metadata-field 'rich 'see-also)
            (metadata-field 'rich 'since)
            (metadata-field 'rich 'deprecated)
            (metadata-field 'rich 'stability)
            (metadata-field 'rich 'authority-review)
            (metadata-field 'merged 'documentation)
            (metadata-field 'merged 'arguments)
            (metadata-field 'merged 'examples)
            (metadata-field 'merged 'see-also)
            (metadata-field 'merged 'custom-field)
            (metadata-field 'duplicate-scalar 'documentation)
            (metadata-field 'duplicate-scalar 'returns)
            (metadata-field 'duplicate-scalar 'summary)
            (metadata-fields 'duplicate-parameter)
            (metadata-fields 'malformed-vector)
            (metadata-fields 'unknown-parameter)
            (metadata-field 'rest-parameter 'parameters)
            (final-rich)
            (metadata-fields 'final-rich))")
    "((session cfg) \"Create an Agent Scheme session from CONFIG.\\nThe session is represented as a datum.\" (config) \"Open an Agent Scheme session.\" ((config . \"Session configuration datum.\")) \"A session record.\" (pure) (((source . \"(rich cfg)\") (result session cfg))) (current-context session-snapshot) (agent-scheme-version 0 14 11) #f experimental \"local only\" \"Line one.\\nLine two.\\nLine three.\" (x) (((source . \"first\")) ((source . \"second\"))) (alpha beta) ((tag . kept)) \"Valid documentation.\" \"First result.\" #f ((arguments (x))) ((arguments (x))) ((arguments (x))) ((head . \"Required argument.\") (tail . \"Rest arguments.\")) #((returns . \"ordinary result\")) ((arguments ())))")))

(ert-deftest agent-scheme-reflect-test-source-library-docstrings ()
  "Reflect docstrings from checked-in source library bindings."
  (agent-scheme-reflect-test--reset)
  (should
   (equal
    (agent-scheme-reflect-test--eval-value-string
     "(import (scheme base)
              (scheme lazy)
              (agent reflect)
              (agent diff)
              (agent network)
              (agent vcs)
              (agent transcript))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (doc-string name)
        (let ((datum (documentation name)))
          (if datum
              (cadr (assq 'documentation (field datum 'fields)))
              #f)))
      (define (metadata-field name field-name)
        (let ((datum (documentation name)))
          (if datum
              (let ((entry (assq field-name (field datum 'fields))))
                (if entry (cadr entry) #f))
              #f)))
      (list (doc-string 'length)
            (doc-string 'force)
            (doc-string 'diff-render-unified)
            (doc-string 'make-network-request)
            (doc-string 'vcs-authorize-capability-request)
            (doc-string 'transcript-event->fixture-case)
            (metadata-field 'force 'parameters)
            (metadata-field 'force 'returns)
            (metadata-field 'diff-render-unified 'parameters)
            (metadata-field 'diff-render-unified 'returns)
            (metadata-field 'make-network-request 'parameters)
            (metadata-field 'make-network-request 'returns))")
    "(\"Return the number of pairs in LIST.\" \"Return PROMISE's value, evaluating and memoizing delayed thunks once.\" \"Render DIFF to deterministic unified-diff text for humans.\" \"Return a host-adapter request datum for one network operation.\" \"Return a fail-closed authorization decision for REQUEST.\" \"Generate a shared fixture case from EVENT when replay permits it.\" ((promise . \"Promise record or ordinary value to force.\")) \"PROMISE's memoized value, or PROMISE unchanged when it is not a promise.\" ((diff . \"Canonical diff datum.\")) \"Unified-diff text, or the empty string when DIFF has no changes.\" ((id . \"Stable request id assigned by the caller or host adapter.\") (operation . \"Network operation symbol such as request or stream.\") (resource . \"Association list describing scheme, host, port, method, headers, payload, response, redirect, timeout, and stream limits.\")) \"A `network-capability-request` datum ready for policy evaluation.\")")))

(ert-deftest agent-scheme-reflect-test-capability-budget-and-imports ()
  "Inspect capability metadata, active budget limits, imports, and session ids."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (list (capability-info 'buffer-text)
                 (current-budget)
                 (current-imports)
                 (current-session-info))"
          '(:max-steps 1234
            :max-host-callbacks 77
            :max-events 9
            :max-event-nodes 88
            :session-id "reflect-run"))))
    (should (string-match-p "(host-capability" external))
    (should (string-match-p (regexp-quote "(library (emacs buffer))") external))
    (should (string-match-p (regexp-quote "(name buffer-text)") external))
    (should (string-match-p (regexp-quote "(policy-category emacs-read-only)") external))
    (should (string-match-p (regexp-quote "(max-steps 1234)") external))
    (should (string-match-p (regexp-quote "(max-host-calls 77)") external))
    (should (string-match-p (regexp-quote "(max-events 9)") external))
    (should (string-match-p (regexp-quote "(max-event-nodes 88)") external))
    (should (string-match-p (regexp-quote "(agent reflect)") external))
    (should (string-match-p (regexp-quote "(id reflect-run)") external))))

(ert-deftest agent-scheme-reflect-test-current-capabilities-lists-host-capabilities ()
  "List importable host capabilities as Scheme-readable metadata records."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (current-capabilities)")))
    (should (string-match-p "(host-capability" external))
    (should (string-match-p (regexp-quote "(name emacs-current-buffer)") external))
    (should (string-match-p (regexp-quote "(name file-exists?)") external))
    (should-not (string-match-p "agent-scheme--primitive" external))
    (should-not (string-match-p "emacs-hook" external))))

(ert-deftest agent-scheme-reflect-test-time-capability-uses-clock-grant-policy ()
  "Reflect `(scheme time)` as a functional clock capability."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (capability-info 'current-second)")))
    (should (string-match-p (regexp-quote "(library (scheme time))") external))
    (should (string-match-p (regexp-quote "(name current-second)") external))
    (should (string-match-p (regexp-quote "(effect host-time)") external))
    (should (string-match-p (regexp-quote "(required-capability clock)") external))
    (should (string-match-p
             (regexp-quote "(backend-effect-path shared-capability-request)")
             external))
    (should (string-match-p (regexp-quote "(policy grant)") external))))

(ert-deftest agent-scheme-reflect-test-recent-yields-redact-secret-values ()
  "Reflect recent yield events without exposing raw credential-like data."
  (agent-scheme-reflect-test--reset)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent io) (agent reflect))
           (agent-yield '((source env)
                          (field \"OPENAI_API_KEY\")
                          (value \"sk-reflectsecret1234567890\")))
           (agent-yield '(visible ok))
           (recent-yields)")))
    (should (string-match-p "(yield (visible ok))" external))
    (should (string-match-p "(redaction (kind secret)" external))
    (should-not (string-match-p "sk-reflectsecret" external))))

(ert-deftest agent-scheme-reflect-test-recent-errors-and-policy-decisions ()
  "Reflect recent error and policy audit entries as redacted datums."
  (agent-scheme-reflect-test--reset)
  (agent-scheme-session-create! 'named '(:id "reflect-errors"))
  (should-error
   (agent-scheme-session-eval-source
    "reflect-errors"
    "(error \"sk-errorsecret1234567890\")")
   :type 'agent-scheme-eval-error)
  (agent-scheme-policy-authorize
   'pure-r7rs "reflect-policy" '((detail . "ok")) nil)
  (let ((external
         (agent-scheme-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (list (recent-errors) (recent-policy-decisions))")))
    (should (string-match-p (regexp-quote "(event session-evaluation)") external))
    (should (string-match-p (regexp-quote "(event policy-decision)") external))
    (should (string-match-p (regexp-quote "(operation \"reflect-policy\")") external))
    (should-not (string-match-p "sk-errorsecret" external))))

;;; agent-scheme-reflect-test.el ends here
