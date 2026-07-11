;;; consent-reflect-test.el --- Runtime reflection tests  -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

;;; Commentary:

;; Focused coverage for the `(agent reflect)' library: capability metadata,
;; budgets, imports, recent event/error inspection, and redaction at the
;; reflection boundary.

;;; Code:

(require 'ert)
(require 'consent-audit)
(require 'consent-eval)
(require 'consent-policy)
(require 'consent-redaction)
(require 'consent-reflect)
(require 'consent-result)
(require 'consent-session)

(defun consent-reflect-test--value-external (value)
  "Return VALUE as stable Consent Scheme value text."
  (consent-value->external value))

(defun consent-reflect-test--eval-value-string (source &optional options)
  "Evaluate SOURCE and return its external value string."
  (consent-reflect-test--value-external
   (consent-eval-source source nil options)))

(defun consent-reflect-test--reset ()
  "Reset shared state touched by reflection tests."
  (consent-redaction-clear!)
  (consent-session-clear!)
  (consent-audit-clear))

(ert-deftest consent-reflect-test-runtime-version-is-canonical-triple ()
  "Expose the Consent Scheme runtime version through `(agent reflect)'."
  (consent-reflect-test--reset)
  (let* ((components (consent-version-components))
         (datum-external (consent-value->external (consent-version)))
         (flags (mapconcat (lambda (_) "#t") components " ")))
    (should
     (equal
      (consent-reflect-test--eval-value-string
       "(import (scheme base) (agent reflect))
      (let ((version (consent-version)))
        (list version
              (map exact-integer? (cdr version))
              (map (lambda (component) (>= component 0))
                   (cdr version))))")
      (format "(%s (%s) (%s))" datum-external flags flags)))))

(ert-deftest consent-reflect-test-simple-string-docstrings ()
  "Expose simple procedure docstrings through `(agent reflect)'."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
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
                 (doc-string (documentation documented)))"
          '(:docstring-retention full))))
    (should
     (equal external
            "(5 (binding documented) (x) \"Return X plus one.\" (procedure) (x) \"Return X plus one.\")"))))

(ert-deftest consent-reflect-test-documentation-arguments-metadata ()
  "Reflect procedure arguments as symbolic documentation metadata."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
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
      (define (variadic . all)
        all)
      (define (empty)
        0)
      (list (metadata-field 'proper 'arguments)
            (metadata-field 'dotted 'arguments)
            (metadata-field 'variadic 'arguments)
            (metadata-field 'empty 'arguments)
            (map symbol? (metadata-field 'proper 'arguments))
            (symbol? (metadata-field 'variadic 'arguments)))"
     '(:docstring-retention full))
    "((first second) (head . tail) all () (#t #t) #t)")))

(ert-deftest consent-reflect-test-primitive-manifest-docstrings ()
  "Reflect primitive docs supplied by manifest metadata."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
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
    "((binding +) (scheme base) kernel (primitive-manifest metadata) \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" (procedure) \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" (scheme time) host-capability (primitive-manifest string) \"Return the current time as a real number of seconds since the Unix epoch, subject to the clock capability policy.\")")))

(ert-deftest consent-reflect-test-primitive-manifest-rich-metadata ()
  "Reflect primitive manifest parameter and return type metadata."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (metadata-field subject name)
        (let ((datum (documentation subject)))
          (if datum
              (let ((entry (assq name (field datum 'fields))))
                (if entry (cadr entry) #f))
            #f)))
      (define (descriptor-type descriptor)
        (cadr (assq 'type descriptor)))
      (define (parameter-type subject name)
        (descriptor-type
         (cdr (assq name (metadata-field subject 'parameters)))))
      (define (return-type subject)
        (descriptor-type (metadata-field subject 'returns)))
      (list (parameter-type '+ 'numbers)
            (return-type '+)
            (metadata-field '+ 'effects)
            (parameter-type 'vector-ref 'k)
            (return-type 'floor/)
            (parameter-type 'read-char 'port)
            (return-type 'read-char)
            (parameter-type 'bytevector-u8-set! 'byte)
            (return-type 'bytevector-u8-set!)
            (metadata-field 'bytevector-u8-set! 'effects))")
    "((list-of number) number (pure) exact-non-negative-integer (values integer integer) textual-input-port (or char eof-object) byte unspecified (mutation))")))

(ert-deftest consent-reflect-test-doc-and-describe-procedures ()
  "Expose scriptable doc and describe records without REPL sigils."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (metadata-field datum name)
        (let ((entry (assq name (field datum 'fields))))
          (if entry (cadr entry) #f)))
      (define (documented x)
        \"Return X plus one.\"
        #((parameters . ((x . \"Input number.\")))
          (returns . \"Incremented number.\")
          (effects . (pure))
          (examples . (((source . \"(documented 4)\")
                        (result . 5)))))
        (+ x 1))
      (define answer 42)
      (let ((primitive (consent-describe '+))
            (compound (consent-describe 'documented))
            (plain (consent-describe 'answer))
            (doc (consent-doc 'documented)))
        (list (field primitive 'subject)
              (field primitive 'binding-kind)
              (field primitive 'value-kind)
              (field primitive 'library)
              (field primitive 'source)
              (field primitive 'value-summary)
              (metadata-field (field primitive 'documentation) 'documentation)
              (field compound 'subject)
              (field compound 'binding-kind)
              (field compound 'value-kind)
              (field compound 'library)
              (field compound 'source)
              (field compound 'value-summary)
              (metadata-field (field compound 'documentation) 'examples)
              (field plain 'value-kind)
              (field plain 'value-summary)
              (field plain 'documentation)
              (field doc 'subject)
              (metadata-field doc 'documentation)
              (consent-describe 'missing)))"
     '(:docstring-retention full))
    "((binding +) value primitive-procedure (scheme base) kernel \"#<primitive +>\" \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" (binding documented) value procedure #f #f \"#<procedure>\" (((source . \"(documented 4)\") (result . 5))) value \"42\" #f (binding documented) \"Return X plus one.\" #f)")))

(ert-deftest consent-reflect-test-docstring-edge-cases ()
  "Reflect adjacent docstrings and preserve final-string body semantics."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
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
            (doc-string (documentation 'missing)))"
     '(:docstring-retention full))
    "(\"First line. Second line.\" (x) 5 \"Use the local definition.\" (x) \"result\" #f () #f (x) #f)")))

(ert-deftest consent-reflect-test-rich-documentation-metadata ()
  "Reflect rich documentation records and malformed metadata behavior."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
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
        \"Create an Consent Scheme session from CONFIG.\"
        \"The session is represented as a datum.\"
        #((summary . \"Open an Consent Scheme session.\")
          (parameters . ((config . \"Session configuration datum.\")))
          (returns . \"A session record.\")
          (effects . (pure))
          (examples . (((source . \"(rich cfg)\")
                        (result . (session cfg)))))
          (see-also . (current-context session-snapshot))
          (since . (consent-version 0 15 4))
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
            (metadata-fields 'final-rich))"
     '(:docstring-retention full))
    "((session cfg) \"Create an Consent Scheme session from CONFIG. The session is represented as a datum.\" (config) \"Open an Consent Scheme session.\" ((config (type any) (description \"Session configuration datum.\"))) ((type any) (description \"A session record.\")) (pure) (((source . \"(rich cfg)\") (result session cfg))) (current-context session-snapshot) (consent-version 0 15 4) #f experimental \"local only\" \"Line one. Line two. Line three.\" (x) (((source . \"first\")) ((source . \"second\"))) (alpha beta) ((tag . kept)) \"Valid documentation.\" ((type any) (description \"First result.\")) #f ((arguments (x))) ((arguments (x))) ((arguments (x))) ((head (type any) (description \"Required argument.\")) (tail (type any) (description \"Rest arguments.\"))) #((returns . \"ordinary result\")) ((arguments ())))")))

(ert-deftest consent-reflect-test-typed-rich-documentation-metadata ()
  "Normalize typed parameter and return documentation descriptors."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (define (metadata-field name field-name)
        (let ((datum (documentation name)))
          (if datum
              (let ((entry (assq field-name (field datum 'fields))))
                (if entry (cadr entry) #f))
            #f)))
      (define (typed config)
        \"Create a session from CONFIG.\"
        #((parameters
           . ((config
               (type session-config)
               (description (\"Session configuration\"
                             \"datum.\")))))
          (returns
           . ((type session-record)
              (description \"A session record.\")))
          (effects . (pure)))
        (list 'session config))
      (define (legacy-shorthand x)
        #((parameters . ((x . \"Input value.\")))
          (returns . \"Output value.\"))
        x)
      (define (fragment-shorthand y)
        #((parameters . ((y . (\"Fragment\"
                               \"input.\"))))
          (returns . (\"Fragment\"
                      \"output.\")))
        y)
      (define (missing-type x)
        #((parameters
           . ((x (description (\"Wrapped\"
                               \"input.\")))))
          (returns
           . ((description (\"Wrapped\"
                            \"output.\")))))
        x)
      (define (multi-values)
        #((parameters . ())
          (returns
           . ((type (values string any))
              (description (\"String result\"
                            \"and opaque payload.\")))))
        (values \"ok\" 1))
      (list (metadata-field 'typed 'documentation)
            (metadata-field 'typed 'parameters)
            (metadata-field 'typed 'returns)
            (metadata-field 'typed 'effects)
            (metadata-field 'legacy-shorthand 'parameters)
            (metadata-field 'legacy-shorthand 'returns)
            (metadata-field 'fragment-shorthand 'parameters)
            (metadata-field 'fragment-shorthand 'returns)
            (metadata-field 'missing-type 'parameters)
            (metadata-field 'missing-type 'returns)
            (metadata-field 'multi-values 'parameters)
            (metadata-field 'multi-values 'returns))"
     '(:docstring-retention full))
    "(\"Create a session from CONFIG.\" ((config (type session-config) (description \"Session configuration datum.\"))) ((type session-record) (description \"A session record.\")) (pure) ((x (type any) (description \"Input value.\"))) ((type any) (description \"Output value.\")) ((y (type any) (description \"Fragment input.\"))) ((type any) (description \"Fragment output.\")) ((x (type any) (description \"Wrapped input.\"))) ((type any) (description \"Wrapped output.\")) () ((type (values string any)) (description \"String result and opaque payload.\")))")))

(ert-deftest consent-reflect-test-docstring-retention-options ()
  "Allow callers to step down or disable procedure body doc retention."
  (consent-reflect-test--reset)
  (let ((source
         "(import (scheme base) (agent reflect))
          (define (field datum name)
            (cadr (assq name (cdr datum))))
          (define (metadata-field subject name)
            (let ((datum (documentation subject)))
              (if datum
                  (let ((entry (assq name (field datum 'fields))))
                    (if entry (cadr entry) #f))
                #f)))
          (define (documented x)
            \"Return X plus one.\"
            #((summary . \"Increment.\")
              (returns . \"A number.\"))
            (+ x 1))
          (list (documented 4)
                (metadata-field 'documented 'documentation)
                (metadata-field 'documented 'arguments)
                (metadata-field 'documented 'summary)
                (metadata-field 'documented 'returns)
                (documentation documented)
                (if (documentation '+) 'primitive-kept 'primitive-missing))"))
    (should
     (equal
      (consent-reflect-test--eval-value-string
       source
       '(:docstring-retention simple))
      "(5 \"Return X plus one.\" (x) #f #f (documentation-metadata (subject (procedure)) (kind procedure) (library #f) (source #f) (origin (body-literal string)) (fields ((arguments (x)) (documentation \"Return X plus one.\")))) primitive-kept)"))
    (should
     (equal
      (consent-reflect-test--eval-value-string
       source
       '(:docstring-retention nil))
      "(5 #f #f #f #f #f primitive-kept)"))))

(ert-deftest consent-reflect-test-docstring-retention-strips-procedure-body ()
  "Avoid retaining recognized body doc literals in procedure bodies."
  (consent-reflect-test--reset)
  (let ((procedure
         (consent-eval-source
          "(define (documented x)
             \"Return X plus one.\"
             #((returns . \"A number.\"))
             (+ x 1))
           documented")))
    (should (consent-procedure-p procedure))
    (should
     (equal
      (mapcar #'consent-value->external
              (consent-procedure-body procedure))
      '("(+ x 1)"))))
  (let ((procedure
         (consent-eval-source
          "(define (documented x)
             \"Return X plus one.\"
             #((returns . \"A number.\"))
             (+ x 1))
           documented"
          nil
          '(:docstring-retention nil))))
    (should (consent-procedure-p procedure))
    (should
     (equal
      (mapcar #'consent-value->external
              (consent-procedure-body procedure))
      '("(+ x 1)"))))
  (let ((procedure
         (consent-eval-source
          "(define (final-string)
             \"result\")
           final-string"
          nil
          '(:docstring-retention nil))))
    (should (consent-procedure-p procedure))
    (should
     (equal
      (mapcar #'consent-value->external
              (consent-procedure-body procedure))
      '("\"result\"")))))

(ert-deftest consent-reflect-test-source-library-docstrings ()
  "Reflect docstrings from checked-in source library bindings."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
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
            (metadata-field 'make-network-request 'returns))"
     '(:docstring-retention full))
    "(\"Return the number of pairs in LIST.\" \"Return PROMISE's value, evaluating and memoizing delayed thunks once.\" \"Render DIFF to deterministic unified-diff text for humans.\" \"Return a host-adapter request datum for one network operation.\" \"Return a fail-closed authorization decision for REQUEST.\" \"Generate a shared fixture case from EVENT when replay permits it.\" ((promise (type any) (description \"Promise record or ordinary value to force.\"))) ((type any) (description \"PROMISE's memoized value, or PROMISE unchanged when it is not a promise.\")) ((diff (type diff) (description \"Canonical diff datum.\"))) ((type string) (description \"Unified-diff text, or the empty string when DIFF has no changes.\")) ((id (type (or symbol string)) (description \"Stable request id assigned by the caller or host adapter.\")) (operation (type symbol) (description \"Network operation symbol such as request or stream.\")) (resource (type list) (description \"Association list describing scheme, host, port, method, headers, payload, response, redirect, timeout, and stream limits.\"))) ((type network-capability-request) (description \"A `network-capability-request` datum ready for policy evaluation.\")))")))

(ert-deftest consent-reflect-test-capability-budget-and-imports ()
  "Inspect capability metadata, active budget limits, imports, and session ids."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (list (capability-info 'buffer-text)
                 (current-budget)
                 (current-imports)
                 (current-session-info))"
          '(:max-steps 1234
            :max-host-callbacks 77
            :max-events 9
            :max-event-nodes 88
            :max-source-metadata 1234567
            :session-id "reflect-run"))))
    (should (string-match-p "(host-capability" external))
    (should (string-match-p (regexp-quote "(library (emacs buffer))") external))
    (should (string-match-p (regexp-quote "(name buffer-text)") external))
    (should (string-match-p (regexp-quote "(policy-category emacs-read-only)") external))
    (should (string-match-p (regexp-quote "(max-steps 1234)") external))
    (should (string-match-p (regexp-quote "(max-host-calls 77)") external))
    (should (string-match-p (regexp-quote "(max-events 9)") external))
    (should (string-match-p (regexp-quote "(max-event-nodes 88)") external))
    (should (string-match-p
             (regexp-quote "(max-source-metadata 1234567)")
             external))
    (should (string-match-p (regexp-quote "(agent reflect)") external))
    (should (string-match-p (regexp-quote "(id reflect-run)") external))))

(ert-deftest consent-reflect-test-library-bindings ()
  "Reflect the actual exported binding surface for a library."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
     "(import (scheme base) (scheme generator) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (let ((bindings (library-bindings '(scheme generator))))
        (list (field (car bindings) 'name)
              (field (car bindings) 'kind)
              (field (car bindings) 'library)
              (field (car (reverse bindings)) 'name)))")
    "(generator value (stdlib generator) product-accumulator)")))

(ert-deftest consent-reflect-test-library-catalog-discovery-stress ()
  "Discover cataloged libraries without importing them into the session."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (define (field datum name)
             (cadr (assq name (cdr datum))))
           (let* ((before (current-imports))
                  (reflect (library-info '(agent reflect)))
                  (lazy (library-info '(scheme lazy)))
                  (json-read (library-info '(consent json read)))
                  (hits (library-search \"reflect\"))
                  (after (current-imports)))
             (list (field reflect 'name)
                   (field reflect 'category)
                   (field reflect 'source-kind)
                   (field lazy 'source-file)
                   (field json-read 'target)
                   (field json-read 'exports)
                   (map (lambda (hit) (field hit 'name)) hits)
                   (if (library-info '(missing library)) 'bad 'missing)
                   (equal? before after)))")))
    (should (string-match-p
             (regexp-quote
              "((agent reflect) agent primitive \"consent/lazy.sld\"")
             external))
    (should (string-match-p
             (regexp-quote
              "(stdlib json) (json-number-of-character-limit")
             external))
    (should (string-match-p
             (regexp-quote "(agent reflect)")
             external))
    (should (string-match-p
             (regexp-quote "missing #t)")
             external))))

(ert-deftest consent-reflect-test-library-catalog-visibility-tiers ()
  "Expose library visibility and availability metadata."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define (field datum name)
        (cadr (assq name (cdr datum))))
      (list
       (field (library-info '(scheme base)) 'visibility)
       (field (library-info '(consent capability)) 'visibility)
       (field (library-info '(srfi 16)) 'visibility)
       (field (library-info '(consent reader)) 'visibility)
       (field (library-info '(agent memory primitive)) 'visibility)
       (field (library-info '(emacs buffer)) 'availability)
       (field (library-info '(emacs buffer)) 'availability-condition))")
    (concat
     "(public public-consent alias internal-runtime internal-agent-primitive "
     "optional (host emacs))"))))

(ert-deftest consent-reflect-test-documented-bindings-and-apropos-stress ()
  "Search binding definitions and keep library search separate."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (define (field datum name)
             (cadr (assq name (cdr datum))))
           (define (metadata-field datum name)
             (let ((entry (assq name (field datum 'fields))))
               (if entry (cadr entry) #f)))
           (define (documented-subject? docs name)
             (cond
              ((null? docs) #f)
              ((equal? (field (car docs) 'subject) (list 'binding name)) #t)
              (else (documented-subject? (cdr docs) name))))
           (define (any-kind? matches kind)
             (cond
              ((null? matches) #f)
              ((eq? (field (car matches) 'kind) kind) #t)
              (else (any-kind? (cdr matches) kind))))
           (define (needle-procedure x)
             \"Return the needle value for discovery tests.\"
             x)
           (let* ((docs (documented-bindings))
                  (matches (apropos \"needle\"))
                  (reflect-matches (apropos \"reflect\"))
                  (library-hits (library-search \"reflect\")))
             (list (if (documented-subject? docs 'needle-procedure)
                       'documented
                       'missing)
                   (metadata-field (documentation 'needle-procedure)
                                   'documentation)
                   (map (lambda (match)
                          (list (field match 'kind)
                                (field match 'name)))
                        matches)
                   (any-kind? reflect-matches 'library)
                   (not (null? library-hits))))"
          '(:docstring-retention full))))
    (should (string-match-p
             (regexp-quote
              "(documented \"Return the needle value for discovery tests.\"")
             external))
    (should (string-match-p
             (regexp-quote "(binding needle-procedure)")
             external))
    (should (string-match-p
             (regexp-quote "#f #t)")
             external))))

(ert-deftest consent-reflect-test-apropos-sees-unmanifested-libraries ()
  "Search registered libraries that do not have manifest metadata."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(define-library (adhoc scratch)
             (export adhoc-needle)
             (import (scheme base))
             (begin
               (define (adhoc-needle x)
                 \"Return X from an ad-hoc library.\"
                 x)))
           (import (scheme base) (agent reflect) (adhoc scratch))
           (define (field datum name)
             (cadr (assq name (cdr datum))))
           (define (library-present? libraries name)
             (cond
              ((null? libraries) #f)
              ((equal? (car libraries) name) #t)
              (else (library-present? (cdr libraries) name))))
           (define (match-libraries matches name)
             (cond
              ((null? matches) '())
              ((eq? (field (car matches) 'name) name)
               (field (car matches) 'libraries))
              (else (match-libraries (cdr matches) name))))
           (let ((binding-library-names
                  (map (lambda (info) (field info 'name))
                       (binding-libraries 'adhoc-needle)))
                 (apropos-library-names
                  (match-libraries (apropos \"adhoc-needle\")
                                   'adhoc-needle)))
             (list
              (library-present? binding-library-names '(adhoc scratch))
              (library-present? apropos-library-names '(adhoc scratch))))"
          '(:docstring-retention full))))
    (should (equal external "(#t #t)"))))

(ert-deftest consent-reflect-test-manifest-input-contract ()
  "Register and remove an ad-hoc manifest through the public source record."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (define (field datum name)
             (cadr (assq name (cdr datum))))
           (define (source-has? sources id name)
             (cond
              ((null? sources) #f)
              ((and (equal? (field (car sources) 'id) id)
                    (member name (field (car sources) 'libraries)))
               #t)
              (else (source-has? (cdr sources) id name))))
           (remove-manifest! 'reflect-contract)
           (define added
             (add-manifest!
              'reflect-contract
              '(library-catalog
                (manifest-entry
                 (schema-version 1)
                 (kind library)
                 (name (project contract))
                 (owner project)
                 (provider reflect-contract)
                 (visibility public)
                 (category project)
                 (status experimental)
                 (source-kind ad-hoc)
                 (realization manifest)
                 (exports (contract-run))
                 (documentation
                  ((summary \"Contract manifest library.\")))
                 (provenance ((origin ad-hoc)))
                 (canonical #t)))))
           (define visible-before-remove
             (source-has? (catalog-sources)
                          'reflect-contract
                          '(project contract)))
           (define removed (remove-manifest! 'reflect-contract))
           (list (field added 'kind)
                 (field added 'id)
                 visible-before-remove
                 removed
                 (source-has? (catalog-sources)
                              'reflect-contract
                              '(project contract)))")))
    (should
     (equal external
            "(ad-hoc-manifest reflect-contract #t #t #f)"))))

(ert-deftest consent-reflect-test-reflection-helper-defaults ()
  "Distinguish absent helper fields from present #f values."
  (consent-reflect-test--reset)
  (should
   (equal
    (consent-reflect-test--eval-value-string
     "(import (scheme base) (agent reflect))
      (define present-false '(sample (present #f)))
      (define missing '(sample))
      (list (reflection-field present-false 'present 'default)
            (reflection-field missing 'present 'default)
            (reflection-field #f 'present 'default)
            (documentation-field (documentation '+) 'documentation)
            (documentation-field (documentation '+) 'missing 'default)
            (docstring '+)
            (docstring 'missing 'default))")
    "(#f default default \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" default \"Return the sum of all numeric arguments, or 0 when called with no arguments.\" default)")))

(ert-deftest consent-reflect-test-binding-libraries-crosswalk-stress ()
  "Find cataloged libraries that export a binding without importing them."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (define (field datum name)
             (cadr (assq name (cdr datum))))
           (let ((before (current-imports)))
             (list (map (lambda (info) (field info 'name))
                        (binding-libraries 'force))
                   (map (lambda (info) (field info 'name))
                        (binding-libraries 'json-read))
                   (equal? before (current-imports))))")))
    (should (string-match-p
             (regexp-quote "((scheme lazy))")
             external))
    (should (string-match-p
             (regexp-quote "(stdlib json)")
             external))
    (should (string-match-p
             (regexp-quote "(consent json)")
             external))
    (should (string-match-p
             (regexp-quote "#t)")
             external))))

(ert-deftest consent-reflect-test-dynamic-manifest-inputs-stress ()
  "Register ad-hoc and manifest-root catalog inputs at runtime."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (define (field datum name)
             (cadr (assq name (cdr datum))))
           (define (source-has? sources id name)
             (cond
              ((null? sources) #f)
              ((and (equal? (field (car sources) 'id) id)
                    (member name (field (car sources) 'libraries)))
               #t)
              (else (source-has? (cdr sources) id name))))
           (remove-manifest! 'reflect-test-session)
           (remove-manifest-root! \"reflect-test-root\")
           (add-manifest!
            'reflect-test-session
            '(library-catalog
              (manifest-entry
               (schema-version 1)
               (kind library)
               (name (project generated))
               (owner project)
               (provider reflect-test-session)
               (visibility public)
               (layer package)
               (category project)
               (status experimental)
               (source-kind ad-hoc)
               (realization manifest)
               (aliases ((project generated alias)))
               (exports (generated-run))
               (dependencies ((library (scheme base))))
               (documentation ((summary \"Generated project library.\")))
               (provenance ((origin ad-hoc)))
               (canonical #t))))
           (define ad-hoc-info (library-info '(project generated)))
           (define ad-hoc-libraries
             (map (lambda (info) (field info 'name))
                  (binding-libraries 'generated-run)))
           (define ad-hoc-source-visible
             (source-has? (catalog-sources)
                          'reflect-test-session
                          '(project generated)))
           (define removed-ad-hoc (remove-manifest! 'reflect-test-session))
           (add-manifest-root!
            \"reflect-test-root\"
            '(library-catalog
              (manifest-entry
               (schema-version 1)
               (kind library)
               (name (project rooted))
               (owner project)
               (provider reflect-test-root)
               (visibility public)
               (category project)
               (status available)
               (source-kind manifest-root)
               (realization manifest-root)
               (exports (rooted-run))
               (documentation ((summary \"Root manifest library.\")))
               (provenance ((origin manifest-root)))
               (canonical #t))))
           (define root-info (library-info '(project rooted)))
           (define root-libraries
             (map (lambda (info) (field info 'name))
                  (binding-libraries 'rooted-run)))
           (define root-source-visible
             (source-has? (catalog-sources)
                          \"reflect-test-root\"
                          '(project rooted)))
           (define removed-root
             (remove-manifest-root! \"reflect-test-root\"))
           (list (field ad-hoc-info 'origin)
                 (field ad-hoc-info 'source-id)
                 (field ad-hoc-info 'summary)
                 ad-hoc-libraries
                 ad-hoc-source-visible
                 removed-ad-hoc
                 (if (library-info '(project generated)) 'bad 'removed)
                 (field root-info 'origin)
                 (field root-info 'source-id)
                 root-libraries
                 root-source-visible
                 removed-root
                 (if (library-info '(project rooted)) 'bad 'root-removed))")))
    (should (string-match-p
             (regexp-quote
              "(ad-hoc-manifest reflect-test-session")
             external))
    (should (string-match-p
             (regexp-quote
              "\"Generated project library.\" ((project generated)) #t #t removed")
             external))
    (should (string-match-p
             (regexp-quote
              "manifest-root \"reflect-test-root\" ((project rooted)) #t #t root-removed)")
             external))))

(ert-deftest consent-reflect-test-library-resolution-api ()
  "Expose deterministic library resolution records through `(agent reflect)'."
  (consent-reflect-test--reset)
  (unwind-protect
      (let ((external
             (consent-reflect-test--eval-value-string
              "(import (scheme base) (agent reflect))
               (define (field datum name)
                 (cadr (assq name (cdr datum))))
               (define (has-name? names name)
                 (cond
                  ((null? names) #f)
                  ((equal? (car names) name) #t)
                  (else (has-name? (cdr names) name))))
               (define (has-resolution? records name)
                 (cond
                  ((null? records) #f)
                  ((equal? (field (car records) 'name) name) #t)
                  (else (has-resolution? (cdr records) name))))
               (remove-manifest! 'reflect-resolution-fixture)
               (add-manifest!
                'reflect-resolution-fixture
                '(library-catalog
                  (manifest-entry
                   (schema-version 1)
                   (kind library)
                   (name (project unavailable))
                   (owner project)
                   (provider reflect-resolution-fixture)
                   (visibility public)
                   (category project)
                   (status available)
                   (source-kind source-library)
                   (source (path \"missing/unavailable.sld\"))
                   (availability optional)
                   (availability-condition (host missing-host))
                   (api-version (compat 0))
                   (source-version unknown)
                   (realization portable-source)
                   (exports (unavailable-run))
                   (dependencies ((library (scheme base))))
                   (canonical #t))
                  (manifest-index-entry
                   (schema-version 1)
                   (kind library-alias)
                   (name (project duplicated))
                   (target (scheme base))
                   (owner project)
                   (provider first-duplicate)
                   (visibility public)
                   (category project)
                   (source-kind alias)
                   (api-version (inherits (scheme base)))
                   (source-version runtime)
                   (realization alias)
                   (status available)
                   (canonical #f))
                  (manifest-index-entry
                   (schema-version 1)
                   (kind library-alias)
                   (name (project duplicated))
                   (target (scheme base))
                   (owner project)
                   (provider second-duplicate)
                   (visibility public)
                   (category project)
                   (source-kind alias)
                   (api-version (inherits (scheme base)))
                  (source-version runtime)
                  (realization alias)
                  (status available)
                  (canonical #f))
                 (manifest-entry
                  (schema-version 1)
                  (kind library)
                  (name (project needs-missing))
                  (owner project)
                  (provider repo-source)
                  (visibility public)
                  (layer package)
                  (category project)
                  (source-kind source-library)
                  (source (path \"project/needs-missing.sld\"))
                  (api-version (compat 0))
                  (source-version unknown)
                  (realization portable-source)
                  (exports (run))
                  (dependencies ((library (project absent))))
                  (provenance ((origin test-fixture)))
                  (status available)
                  (canonical #t))))
               (let* ((base (library-resolve '(scheme base)))
                      (alias (library-resolve '(srfi 16)))
                      (missing (library-resolve '(missing library)))
                      (denied (library-resolve '(consent reader)))
                      (unavailable (library-resolve '(project unavailable)))
                      (loaded (library-load '(srfi 16)))
                      (dependencies
                       (library-solve-dependencies '(scheme lazy)))
                      (dependency-failure
                       (library-solve-dependencies '(project needs-missing)))
                      (conflict
                       (car (library-conflicts '(project duplicated))))
                      (paths (library-paths))
                      (snapshot (library-snapshot '(srfi 16)))
                      (vendored (vendored-srfi-manifest 16))
                      (vendored-missing (vendored-srfi-manifest 99999)))
                 (list
                  (list 'base
                        (field base 'status)
                        (field base 'name)
                        (field base 'resolved-name)
                        (field base 'root)
                        (field base 'source-kind)
                        (field base 'visibility))
                  (list 'alias
                        (field alias 'status)
                        (field alias 'name)
                        (field alias 'resolved-name)
                        (field alias 'target)
                        (field alias 'source-kind))
                  (list 'missing
                        (field missing 'status)
                        (field missing 'reason))
                  (list 'denied
                        (field denied 'status)
                        (field denied 'reason))
                  (list 'unavailable
                        (field unavailable 'status)
                        (field unavailable 'reason)
                        (field unavailable 'availability-condition))
                  (list 'conflict
                        (field conflict 'status)
                        (field conflict 'name)
                        (length (field conflict 'candidates)))
                  (list 'loaded
                        (field loaded 'status)
                        (field loaded 'loaded?))
                  (list 'dependencies
                        (field dependencies 'status)
                        (has-name? (field dependencies 'dependencies)
                                   '(scheme base)))
                  (list 'dependency-failure
                        (field dependency-failure 'status)
                        (field dependency-failure 'reason)
                        (has-name?
                         (field dependency-failure 'missing-dependencies)
                         '(project absent)))
                  (list 'paths
                        (not (null? paths))
                        (field (car paths) 'kind))
                  (list 'snapshot
                        (field snapshot 'status)
                        (field snapshot 'name)
                        (has-resolution? (field snapshot 'resolved)
                                         '(srfi 16)))
                  (list 'srfi-name (srfi-library-name 16))
                  (list 'srfi-aliases (srfi-library-aliases 16))
                  (list 'vendored
                        (field vendored 'classification)
                        (field vendored 'library)
                        (field vendored 'target))
                  (list 'vendored-missing
                        (field vendored-missing 'status)
                        (field vendored-missing 'reason))))")))
        (dolist (needle
                 '("((base resolved (scheme base) (scheme base) builtin base-snapshot public)"
                   "(alias resolved (srfi 16) (scheme case-lambda) (scheme case-lambda) alias)"
                   "(missing missing missing-library)"
                   "(denied denied internal-library)"
                   "(unavailable unavailable availability-condition (host missing-host))"
                   "(conflict conflict (project duplicated) 2)"
                   "(loaded resolved #t)"
                   "(dependencies resolved #t)"
                   "(dependency-failure unsatisfied-dependency missing-dependency #t)"
                   "(paths #t ad-hoc-manifest)"
                   "(snapshot resolved (srfi 16) #t)"
                   "(srfi-name (srfi 16))"
                   "(srfi-aliases ((srfi 16) (srfi srfi-16) (srfi :16) (srfi :16 case-lambda)))"
                   "(vendored shim (srfi 16) (scheme case-lambda))"
                   "(vendored-missing missing missing-srfi)"))
          (should (string-match-p (regexp-quote needle) external))))
    (consent--library-catalog-remove-manifest 'reflect-resolution-fixture)))

(ert-deftest consent-reflect-test-current-capabilities-lists-host-capabilities ()
  "List importable host capabilities as Scheme-readable metadata records."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (current-capabilities)")))
    (should (string-match-p "(host-capability" external))
    (should (string-match-p (regexp-quote "(name emacs-current-buffer)") external))
    (should (string-match-p (regexp-quote "(name file-exists?)") external))
    (should-not (string-match-p "consent--primitive" external))
    (should-not (string-match-p "emacs-hook" external))))

(ert-deftest consent-reflect-test-time-capability-uses-clock-grant-policy ()
  "Reflect `(scheme time)` as a functional clock capability."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
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

(ert-deftest consent-reflect-test-recent-yields-redact-secret-values ()
  "Reflect recent yield events without exposing raw credential-like data."
  (consent-reflect-test--reset)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent io) (agent reflect))
           (agent-yield '((source env)
                          (field \"OPENAI_API_KEY\")
                          (value \"sk-reflectsecret1234567890\")))
           (agent-yield '(visible ok))
           (recent-yields)")))
    (should (string-match-p "(yield (visible ok))" external))
    (should (string-match-p "(redaction (kind secret)" external))
    (should-not (string-match-p "sk-reflectsecret" external))))

(ert-deftest consent-reflect-test-recent-errors-and-policy-decisions ()
  "Reflect recent error and policy audit entries as redacted datums."
  (consent-reflect-test--reset)
  (consent-session-create! 'named '(:id "reflect-errors"))
  (should-error
   (consent-session-eval-source
    "reflect-errors"
    "(error \"sk-errorsecret1234567890\")")
   :type 'consent-eval-error)
  (consent-policy-authorize
   'pure-r7rs "reflect-policy" '((detail . "ok")) nil)
  (let ((external
         (consent-reflect-test--eval-value-string
          "(import (scheme base) (agent reflect))
           (list (recent-errors) (recent-policy-decisions))")))
    (should (string-match-p (regexp-quote "(event session-evaluation)") external))
    (should (string-match-p (regexp-quote "(event policy-decision)") external))
    (should (string-match-p (regexp-quote "(operation \"reflect-policy\")") external))
    (should-not (string-match-p "sk-errorsecret" external))))

;;; consent-reflect-test.el ends here
