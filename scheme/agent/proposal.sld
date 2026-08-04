;;; Public Consent Scheme model-proposal boundary.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral proposal-datum boundary that the control
;;; loop (`(agent runner)') applies to a model's emitted Scheme form before any
;;; effect runs.  A model proposal is carried as data inside an
;;; `agent-action (kind code-action) (form <quoted-datum>) ...' record; this
;;; library READS that form as data, walks it for capability requests, accounts
;;; the cost of its pure sub-forms against a bounded budget, and quarantines
;;; any
;;; control-plane sub-form to a denied `capability-decision'. The form is never
;;; evaluated here as raw authority: model output proposes, the policy gate
;;; (driven by the runner) disposes. This is the design decision recorded as D2
;;; in `docs/control-loop.md' (free-form code execution vs. capability-gated
;;; effects).
;;;
;;; The library is host-neutral and single-sourced: the Emacs interpreter and
;;; the portable hosts load this same Scheme source, so the analysis datum is
;;; cross-host identical and replayable without a separate Emacs
;;; reimplementation.

(define-library (agent proposal)
  (export proposal-control-plane-operations
          proposal-control-plane-operation?
          analyze-code-action
          code-action-analysis?
          proposal-field-value
          analysis-status
          analysis-pure-cost
          analysis-capability-requests
          analysis-quarantine-decisions
          analysis-failure-decisions
          capability-request?
          capability-decision?
          capability-decision-status)
  (import (scheme base))
  (begin
    ;; Control-plane operations are the consent machinery itself: minting or
    ;; attenuating grants, revoking or releasing authority, resolving
    ;; approvals,
    ;; and stamping a verifier as passed.  A model proposal that names any of
    ;; these is escalating its own authority or bypassing the gate, so the
    ;; boundary quarantines it rather than turning it into a capability
    ;; request.
    (define proposal-control-plane-operations
      '(grant-capability! grant-attenuate grant-revoke! handle-release!
                          approval-resolve! verifier-pass!
                          mark-verifier-passed!))

    ;; Core structural forms are not tool bindings.  In signature-gated mode
    ;; they provide AST shape whose subtrees are still walked and checked.
    (define proposal-structural-operations
      '(begin if lambda quote quasiquote set! define define-values
              define-syntax let let* letrec let-values let*-values
              let-syntax letrec-syntax cond case and or do delay delay-force
              parameterize guard))

    ;; Private sentinel for descriptor fields that are truly absent.
    (define proposal-absent-marker 'proposal-absent-marker)

    ;; Private sentinel for non-literal argument expressions.
    (define proposal-unknown-literal 'proposal-unknown-literal)

    (define (member-eq? value values)
      "Return #t when VALUE is a member of VALUES using eq?."
      (cond
       ((null? values) #f)
       ((eq? value (car values)) #t)
       (else (member-eq? value (cdr values)))))

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT when KEY is absent.  OPTIONS entrie\
s"
      "may be dotted alist cells or two-element option records."
      (let ((cell (assq key options)))
        (if cell
            (let ((value (cdr cell)))
              (if (and (pair? value) (null? (cdr value)))
                  (car value)
                  value))
            default)))

    (define (field-named? field name)
      "Return #t when FIELD is a record field named NAME."
      (and (pair? field) (eq? (car field) name)))

    (define (proposal-field-value record name . maybe-default)
      "Return RECORD field NAME, or DEFAULT when the field is absent."
      #((parameters
         (record (type pair)
          (description
           ("Proposal record represented as a tagged list, such as a"
             "`code-action-analysis', `capability-request', or"
             "`capability-decision'.")))
         (name (type symbol)
          (description "Symbol naming the field to read."))
         (maybe-default . "Optional fallback value; defaults to #f."))
        (returns . "The field value, or DEFAULT when NAME is absent.")
        (effects pure))
      (let ((default (if (null? maybe-default) #f (car maybe-default))))
        (let loop ((fields (cdr record)))
          (cond
           ((null? fields) default)
           ((field-named? (car fields) name) (cadr (car fields)))
           (else (loop (cdr fields)))))))

    (define (proposal-record? datum tag)
      "Return #t when DATUM is a tagged list whose head is TAG."
      (and (pair? datum) (eq? (car datum) tag)))

    (define (proposal-control-plane-operation? operation)
      "Return #t when OPERATION is a default control-plane operation symbol."
      #((parameters
         (operation (type symbol)
          (description
            ("Symbol naming a proposed call operator to classify."))))
        (returns (type boolean)
         (description
          ("#t when OPERATION is part of the default control-plane"
            "vocabulary; otherwise #f.")))
        (effects pure))
      (and (symbol? operation)
           (member-eq? operation proposal-control-plane-operations)))

    (define (code-action-analysis? datum)
      "Return #t when DATUM is a code-action analysis record."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description
          ("#t when DATUM is tagged as a `code-action-analysis';"
            "otherwise #f.")))
        (effects pure))
      (proposal-record? datum 'code-action-analysis))

    (define (capability-request? datum)
      "Return #t when DATUM is a capability-request record."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description
          ("#t when DATUM is tagged as a `capability-request';"
            "otherwise #f.")))
        (effects pure))
      (proposal-record? datum 'capability-request))

    (define (capability-decision? datum)
      "Return #t when DATUM is a capability-decision record."
      #((parameters
         (datum . "Value to inspect."))
        (returns (type boolean)
         (description
          ("#t when DATUM is tagged as a `capability-decision';"
            "otherwise #f.")))
        (effects pure))
      (proposal-record? datum 'capability-decision))

    (define (capability-decision-status decision)
      "Return the status symbol of a capability-decision record."
      #((parameters
         (decision (type capability-decision)
          (description "A `capability-decision' record.")))
        (returns (type symbol)
         (description "The decision status symbol, such as `denied'."))
        (effects pure))
      (proposal-field-value decision 'status))

    (define (analysis-status analysis)
      "Return the overall status of a code-action analysis."
      #((parameters
         (analysis (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns (type symbol)
         (description
          ("One of `allowed', `gated', `rejected', `quarantined', or"
            "`budget-exhausted'.")))
        (effects pure))
      (proposal-field-value analysis 'status))

    (define (analysis-pure-cost analysis)
      "Return the bounded pure-form cost charged by walking the proposal."
      #((parameters
         (analysis (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns (type exact-integer)
         (description
          ("The non-negative integer count of proposal nodes the walk"
            "visited.")))
        (effects pure))
      (proposal-field-value analysis 'pure-cost 0))

    (define (analysis-capability-requests analysis)
      "Return the capability-request datums the proposal would route to policy\
."
      #((parameters
         (analysis (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns (type (list-of capability-request))
         (description
           ("A list of `capability-request' datums in document order.")))
        (effects pure))
      (proposal-field-value analysis 'capability-requests '()))

    (define (analysis-quarantine-decisions analysis)
      "Return the denied capability-decision datums for quarantined sub-forms.\
"
      #((parameters
         (analysis (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns (type (list-of capability-decision))
         (description
          ("A list of denied `capability-decision' datums in document"
            "order.")))
        (effects pure))
      (proposal-field-value analysis 'quarantine-decisions '()))

    (define (analysis-failure-decisions analysis)
      "Return denied capability-decision datums for failed admission checks."
      #((parameters
         (analysis (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns (type (list-of capability-decision))
         (description
          ("A list of denied `capability-decision' datums for"
            "hallucinated or misapplied tool calls.")))
        (effects pure))
      (proposal-field-value analysis 'failure-decisions '()))

    (define (quote-form? node)
      "Return #t when NODE is a quote or quasiquote form whose body is inert."
      (and (pair? node)
           (or (eq? (car node) 'quote) (eq? (car node) 'quasiquote))))

    (define (operation-entry operation table)
      "Return the host-operation TABLE entry for OPERATION, or #f when absent.\
"
      (and (symbol? operation) (assq operation table)))

    (define (structural-operation? operation)
      "Return #t when OPERATION is recognized syntax shape, not a tool call."
      (and (symbol? operation)
           (member-eq? operation proposal-structural-operations)))

    (define (descriptor-field-value descriptor name default)
      "Return field NAME from DESCRIPTOR, or DEFAULT when absent."
      (let loop ((fields descriptor))
        (cond
         ((null? fields) default)
         ((and (pair? (car fields)) (eq? (car (car fields)) name))
          (if (null? (cdr (car fields)))
              default
              (car (cdr (car fields)))))
         (else (loop (cdr fields))))))

    (define (capability-signature-name signature)
      "Return SIGNATURE's binding name, or #f when absent."
      (proposal-field-value signature 'name #f))

    (define (capability-signature-parameters signature)
      "Return SIGNATURE's ordered parameter descriptors."
      (proposal-field-value signature 'parameters '()))

    (define (capability-signature-effects signature)
      "Return SIGNATURE's effect list."
      (proposal-field-value signature 'effects '(pure)))

    (define (capability-signature-entry operation signatures)
      "Return OPERATION's capability signature from SIGNATURES, or #f."
      (let loop ((rest signatures))
        (cond
         ((null? rest) #f)
         ((eq? (capability-signature-name (car rest)) operation) (car rest))
         (else (loop (cdr rest))))))

    (define (parameter-optional? parameter)
      "Return #t when PARAMETER has an explicit default or optional marker."
      (let ((descriptor (cdr parameter)))
        (or (not (eq? (descriptor-field-value descriptor 'default
                                              proposal-absent-marker)
                      proposal-absent-marker))
            (eq? (descriptor-field-value descriptor 'optional #f) #t))))

    (define (required-parameter-count parameters)
      "Return the number of non-defaulted required PARAMETERS."
      (let loop ((rest parameters) (count 0))
        (cond
         ((null? rest) count)
         ((parameter-optional? (car rest)) (loop (cdr rest) count))
         (else (loop (cdr rest) (+ count 1))))))

    (define (proper-list? value)
      "Return #t when VALUE is a proper list."
      (let loop ((rest value))
        (cond
         ((null? rest) #t)
         ((pair? rest) (loop (cdr rest)))
         (else #f))))

    (define (list-length value)
      "Return the length of proper list VALUE."
      (let loop ((rest value) (count 0))
        (if (null? rest)
            count
            (loop (cdr rest) (+ count 1)))))

    (define (quoted-literal? value)
      "Return #t when VALUE is a one-argument quote form."
      (and (pair? value)
           (eq? (car value) 'quote)
           (pair? (cdr value))
           (null? (cddr value))))

    (define (literal-value value)
      "Return VALUE's admission-time literal value, or unknown marker."
      (cond
       ((quoted-literal? value) (cadr value))
       ((or (string? value) (number? value) (boolean? value) (char? value)
            (vector? value) (null? value))
        value)
       (else proposal-unknown-literal)))

    (define (literal-known? value)
      "Return #t when VALUE is a known literal, not the unknown marker."
      (not (eq? value proposal-unknown-literal)))

    (define (every-type-match? type values)
      "Return #t when every element in VALUES matches TYPE."
      (cond
       ((null? values) #t)
       ((advisory-type-match? type (car values))
        (every-type-match? type (cdr values)))
       (else #f)))

    (define (vector-every-type-match? type vector)
      "Return #t when every element in VECTOR matches TYPE."
      (let loop ((index 0))
        (cond
         ((= index (vector-length vector)) #t)
         ((advisory-type-match? type (vector-ref vector index))
          (loop (+ index 1)))
         (else #f))))

    (define (advisory-type-match? type value)
      "Return #t when literal VALUE satisfies advisory TYPE."
      (cond
       ((not (literal-known? value)) #t)
       ((eq? type 'any) #t)
       ((eq? type 'string) (string? value))
       ((eq? type 'symbol) (symbol? value))
       ((eq? type 'boolean) (boolean? value))
       ((eq? type 'bool) (boolean? value))
       ((eq? type 'number) (number? value))
       ((eq? type 'real) (number? value))
       ((eq? type 'rational) (number? value))
       ((eq? type 'complex) (number? value))
       ((eq? type 'integer) (integer? value))
       ((eq? type 'exact-integer) (integer? value))
       ((eq? type 'nonnegative-integer)
        (and (integer? value) (>= value 0)))
       ((eq? type 'character) (char? value))
       ((eq? type 'list) (list? value))
       ((eq? type 'pair) (pair? value))
       ((eq? type 'vector) (vector? value))
       ((eq? type 'procedure) #t)
       ((eq? type #f) (eq? value #f))
       ((and (pair? type) (eq? (car type) 'or))
        (let loop ((choices (cdr type)))
          (cond
           ((null? choices) #f)
           ((advisory-type-match? (car choices) value) #t)
           (else (loop (cdr choices))))))
       ((and (pair? type) (eq? (car type) 'list-of))
        (and (list? value)
             (every-type-match? (cadr type) value)))
       ((and (pair? type) (eq? (car type) 'vector-of))
        (and (vector? value)
             (vector-every-type-match? (cadr type) value)))
       ((and (pair? type) (eq? (car type) 'pair))
        (and (pair? value)
             (advisory-type-match? (cadr type) (car value))
             (advisory-type-match? (car (cdr (cdr type))) (cdr value))))
       (else #t)))

    (define (parameter-type-matches? parameter argument)
      "Return #t when ARGUMENT satisfies PARAMETER's advisory type."
      (let* ((descriptor (cdr parameter))
             (type (descriptor-field-value descriptor 'type 'any))
             (value (literal-value argument)))
        (advisory-type-match? type value)))

    (define (signature-mismatch signature arguments)
      "Return #f when ARGUMENTS fit SIGNATURE, otherwise a mismatch symbol."
      (if (not (proper-list? arguments))
          'structural-shape
          (let* ((parameters (capability-signature-parameters signature))
                 (argument-count (list-length arguments))
                 (minimum (required-parameter-count parameters))
                 (maximum (list-length parameters)))
            (cond
             ((or (< argument-count minimum) (> argument-count maximum))
              'arity)
             (else
              (let loop ((params parameters) (args arguments))
                (cond
                 ((null? args) #f)
                 ((null? params) #f)
                 ((parameter-type-matches? (car params) (car args))
                  (loop (cdr params) (cdr args)))
                 (else 'type))))))))

    (define (signature-effect-for-request signature)
      "Return the request effect field derived from SIGNATURE."
      (capability-signature-effects signature))

    (define (signature-requires-for-request signature)
      "Return the request authority field derived from SIGNATURE."
      (let ((effects (capability-signature-effects signature)))
        (if (and (pair? effects) (null? (cdr effects)) (eq? (car effects)
          'pure))
            'none
            effects)))

    (define (pure-signature? signature)
      "Return #t when SIGNATURE describes a pure-under-budget call."
      (let ((effects (capability-signature-effects signature)))
        (and (pair? effects) (null? (cdr effects)) (eq? (car effects) 'pure))))

    (define (analyze-code-action form options)
      "Analyze a model-proposed FORM as data and return a code-action analysis\
."
      #((parameters
         (form
          . ("The model-proposed Scheme datum to read and walk; it is"
             "never evaluated as authority."))
         (options (type list)
          (description
           ("Association list configuring the walk: `operations' (alist"
             "of `(operator effect authority)' host-operation entries),"
             "`capability-signatures' or `signatures' (model-tool"
             "capability signature datums),"
             "`quarantine' (extra control-plane operator symbols),"
             "`max-pure-cost' (integer node budget), and `id-prefix'"
             "(symbol or string seeding deterministic request/decision"
             "ids)."))))
        (returns (type code-action-analysis)
         (description
          ("A `code-action-analysis' datum carrying the original form,"
            "an overall status"
            "(`allowed'/`gated'/`rejected'/`quarantined'/"
            "`budget-exhausted'), the"
            "bounded pure-form cost, the ordered capability-request"
            "datums for host calls, ordered denied admission-failure"
            "capability-decision datums, and the ordered denied"
            "capability-decision datums for quarantined control-plane"
            "sub-forms.")))
        (effects allocation))
      (let ((operations (option-ref options 'operations '()))
            (signatures
             (option-ref options 'capability-signatures
                         (option-ref options 'signatures '())))
            (extra-quarantine (option-ref options 'quarantine '()))
            (max-pure-cost (option-ref options 'max-pure-cost 100000))
            (id-prefix (proposal-id-prefix (option-ref options 'id-prefix
                                                        'proposal))))
        (let ((visited 0)
              (requests '())
              (decisions '())
              (failures '())
              (request-count 0)
              (decision-count 0))
          (define (over-budget?)
            "Return #t once the walk has visited more nodes than the budget."
            (> visited max-pure-cost))
          (define (control-plane? operation)
            "Return #t when OPERATION is a default or option-supplied trigger.\
"
            (and (symbol? operation)
                 (or (member-eq? operation proposal-control-plane-operations)
                     (member-eq? operation extra-quarantine))))
          (define (record-request! operation node entry)
            "Append a capability-request for the host call at NODE."
            (set! request-count (+ request-count 1))
            (set! requests
                  (cons (list 'capability-request
                              (list 'id (proposal-id id-prefix "req"
                                                     request-count))
                              (list 'source 'proposal)
                              (list 'operation operation)
                              (list 'effect (cadr entry))
                              (list 'requires (entry-authority entry))
                              (list 'form node))
                        requests)))
          (define (record-signature-request! operation node signature)
            "Append a capability-request admitted by SIGNATURE."
            (set! request-count (+ request-count 1))
            (set! requests
                  (cons (list 'capability-request
                              (list 'id (proposal-id id-prefix "req"
                                                     request-count))
                              (list 'source 'proposal)
                              (list 'operation operation)
                              (list 'effect
                                    (signature-effect-for-request signature))
                              (list 'requires
                                    (signature-requires-for-request signature))
                              (list 'signature (capability-signature-name
                                                signature))
                              (list 'form node))
                        requests)))
          (define (record-quarantine! operation node)
            "Append a denied capability-decision for the control-plane NODE."
            (set! decision-count (+ decision-count 1))
            (set! decisions
                  (cons (list 'capability-decision
                              (list 'id (proposal-id id-prefix "dec"
                                                     decision-count))
                              (list 'request node)
                              (list 'status 'denied)
                              (list 'operation operation)
                              (list 'reason
                                    'proposal-quarantined-control-plane))
                        decisions)))
          (define (record-failure! reason operation node mismatch)
            "Append a denied capability-decision for a failed admission NODE."
            (set! decision-count (+ decision-count 1))
            (set! failures
                  (cons (list 'capability-decision
                              (list 'id (proposal-id id-prefix "dec"
                                                     decision-count))
                              (list 'request node)
                              (list 'status 'denied)
                              (list 'operation operation)
                              (list 'reason reason)
                              (list 'mismatch mismatch))
                        failures)))
          (define (admit-signature-call! operation node)
            "Admit NODE against the registered signature for OPERATION."
            (let ((signature (capability-signature-entry operation
              signatures)))
              (cond
               ((not signature)
                (record-failure! 'hallucinated-tool operation node
                                 'unregistered-binding))
               (else
                (let ((mismatch (signature-mismatch signature (cdr node))))
                  (cond
                   (mismatch
                    (record-failure! 'misapplied-tool operation node
                                     mismatch))
                   ((pure-signature? signature) #t)
                   (else
                    (record-signature-request! operation node
                                               signature))))))))
          (define (walk-spine lst)
            "Walk the proper-list spine LST, classifying each element."
            (cond
             ((over-budget?) #t)
             ((pair? lst) (walk (car lst)) (walk-spine (cdr lst)))
             ((null? lst) #t)
             (else (walk lst))))
          (define (walk node)
            "Visit NODE: count it, classify its operator, and recurse."
            (if (over-budget?)
                #t
                (begin
                  (set! visited (+ visited 1))
                  (cond
                   ((over-budget?) #t)
                   ((not (pair? node)) #t)
                   ((quote-form? node) #t)
                   (else
                    (let ((head (car node)))
                      (cond
                       ((control-plane? head) (record-quarantine! head node))
                       ((and (pair? signatures)
                             (not (structural-operation? head)))
                        (if (symbol? head)
                            (admit-signature-call! head node)
                            (record-failure! 'hallucinated-tool head node
                                             'invalid-operator)))
                       (else
                        (let ((entry (operation-entry head operations)))
                          (if entry (record-request! head node entry)))))
                      (walk-spine node)))))))
          (walk form)
          (let ((status
                 (cond
                  ((not (null? decisions)) 'quarantined)
                  ((over-budget?) 'budget-exhausted)
                  ((not (null? failures)) 'rejected)
                  ((not (null? requests)) 'gated)
                  (else 'allowed))))
            (list 'code-action-analysis
                  (list 'form form)
                  (list 'status status)
                  (list 'pure-cost visited)
                  (list 'capability-requests (reverse requests))
                  (list 'quarantine-decisions (reverse decisions))
                  (list 'failure-decisions (reverse failures)))))))

    (define (entry-authority entry)
      "Return the authority class named by host-operation ENTRY, or `none'."
      (if (and (pair? (cdr entry)) (pair? (cddr entry)))
          (car (cddr entry))
          'none))

    (define (proposal-id-prefix prefix)
      "Return PREFIX as a string for deterministic id construction."
      (cond
       ((string? prefix) prefix)
       ((symbol? prefix) (symbol->string prefix))
       (else "proposal")))

    (define (proposal-id prefix tag index)
      "Return a deterministic id symbol from PREFIX, TAG, and INDEX."
      (string->symbol
       (string-append prefix "-" tag "-" (number->string index))))))
