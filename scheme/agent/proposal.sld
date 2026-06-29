;;; Public Consent Scheme model-proposal boundary.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library owns the host-neutral proposal-datum boundary that the control
;;; loop (`(agent runner)') applies to a model's emitted Scheme form before any
;;; effect runs.  A model proposal is carried as data inside an
;;; `agent-action (kind code-action) (form <quoted-datum>) ...' record; this
;;; library READS that form as data, walks it for capability requests, accounts
;;; the cost of its pure sub-forms against a bounded budget, and quarantines any
;;; control-plane sub-form to a denied `capability-decision'.  The form is never
;;; evaluated here as raw authority: model output proposes, the policy gate
;;; (driven by the runner) disposes.  This is the design decision recorded as D2
;;; in `docs/control-loop.md' (free-form code execution vs. capability-gated
;;; effects).
;;;
;;; The library is host-neutral and single-sourced: the Emacs interpreter and
;;; the portable hosts load this same Scheme source, so the analysis datum is
;;; cross-host identical and replayable without a separate Emacs reimplementation.

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
          capability-request?
          capability-decision?
          capability-decision-status)
  (import (scheme base))
  (begin
    ;; Control-plane operations are the consent machinery itself: minting or
    ;; attenuating grants, revoking or releasing authority, resolving approvals,
    ;; and stamping a verifier as passed.  A model proposal that names any of
    ;; these is escalating its own authority or bypassing the gate, so the
    ;; boundary quarantines it rather than turning it into a capability request.
    (define proposal-control-plane-operations
      '(grant-capability! grant-attenuate grant-revoke! handle-release!
                          approval-resolve! verifier-pass!
                          mark-verifier-passed!))

    (define (member-eq? value values)
      "Return #t when VALUE is a member of VALUES using eq?."
      (cond
       ((null? values) #f)
       ((eq? value (car values)) #t)
       (else (member-eq? value (cdr values)))))

    (define (option-ref options key default)
      "Return KEY from OPTIONS, or DEFAULT when KEY is absent.  OPTIONS entries"
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
         (record
          (type pair)
          (description
           ("Proposal record represented as a tagged list, such as a"
             "`code-action-analysis', `capability-request', or"
             "`capability-decision'.")))
         (name
          (type symbol)
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
         (operation
          (type symbol)
          (description ("Symbol naming a proposed call operator to classify."))))
        (returns
         (type boolean)
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
        (returns
         (type boolean)
         (description
          ("#t when DATUM is tagged as a `code-action-analysis';"
            "otherwise #f.")))
        (effects pure))
      (proposal-record? datum 'code-action-analysis))

    (define (capability-request? datum)
      "Return #t when DATUM is a capability-request record."
      #((parameters
         (datum . "Value to inspect."))
        (returns
         (type boolean)
         (description
          ("#t when DATUM is tagged as a `capability-request';"
            "otherwise #f.")))
        (effects pure))
      (proposal-record? datum 'capability-request))

    (define (capability-decision? datum)
      "Return #t when DATUM is a capability-decision record."
      #((parameters
         (datum . "Value to inspect."))
        (returns
         (type boolean)
         (description
          ("#t when DATUM is tagged as a `capability-decision';"
            "otherwise #f.")))
        (effects pure))
      (proposal-record? datum 'capability-decision))

    (define (capability-decision-status decision)
      "Return the status symbol of a capability-decision record."
      #((parameters
         (decision
          (type capability-decision)
          (description "A `capability-decision' record.")))
        (returns
         (type symbol)
         (description "The decision status symbol, such as `denied'."))
        (effects pure))
      (proposal-field-value decision 'status))

    (define (analysis-status analysis)
      "Return the overall status of a code-action analysis."
      #((parameters
         (analysis
          (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns
         (type symbol)
         (description
          ("One of `allowed', `gated', `quarantined', or"
            "`budget-exhausted'.")))
        (effects pure))
      (proposal-field-value analysis 'status))

    (define (analysis-pure-cost analysis)
      "Return the bounded pure-form cost charged by walking the proposal."
      #((parameters
         (analysis
          (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns
         (type exact-integer)
         (description
          ("The non-negative integer count of proposal nodes the walk"
            "visited.")))
        (effects pure))
      (proposal-field-value analysis 'pure-cost 0))

    (define (analysis-capability-requests analysis)
      "Return the capability-request datums the proposal would route to policy."
      #((parameters
         (analysis
          (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns
         (type (list-of capability-request))
         (description ("A list of `capability-request' datums in document order.")))
        (effects pure))
      (proposal-field-value analysis 'capability-requests '()))

    (define (analysis-quarantine-decisions analysis)
      "Return the denied capability-decision datums for quarantined sub-forms."
      #((parameters
         (analysis
          (type code-action-analysis)
          (description "A `code-action-analysis' record.")))
        (returns
         (type (list-of capability-decision))
         (description
          ("A list of denied `capability-decision' datums in document"
            "order.")))
        (effects pure))
      (proposal-field-value analysis 'quarantine-decisions '()))

    (define (quote-form? node)
      "Return #t when NODE is a quote or quasiquote form whose body is inert."
      (and (pair? node)
           (or (eq? (car node) 'quote) (eq? (car node) 'quasiquote))))

    (define (operation-entry operation table)
      "Return the host-operation TABLE entry for OPERATION, or #f when absent."
      (and (symbol? operation) (assq operation table)))

    (define (analyze-code-action form options)
      "Analyze a model-proposed FORM as data and return a code-action analysis."
      #((parameters
         (form
          . ("The model-proposed Scheme datum to read and walk; it is"
             "never evaluated as authority."))
         (options
          (type list)
          (description
           ("Association list configuring the walk: `operations' (alist"
             "of `(operator effect authority)' host-operation entries),"
             "`quarantine' (extra control-plane operator symbols),"
             "`max-pure-cost' (integer node budget), and `id-prefix'"
             "(symbol or string seeding deterministic request/decision"
             "ids)."))))
        (returns
         (type code-action-analysis)
         (description
          ("A `code-action-analysis' datum carrying the original form,"
            "an overall status"
            "(`allowed'/`gated'/`quarantined'/`budget-exhausted'), the"
            "bounded pure-form cost, the ordered capability-request"
            "datums for host calls, and the ordered denied"
            "capability-decision datums for quarantined control-plane"
            "sub-forms.")))
        (effects allocation))
      (let ((operations (option-ref options 'operations '()))
            (extra-quarantine (option-ref options 'quarantine '()))
            (max-pure-cost (option-ref options 'max-pure-cost 100000))
            (id-prefix (proposal-id-prefix (option-ref options 'id-prefix
                                                        'proposal))))
        (let ((visited 0)
              (requests '())
              (decisions '())
              (request-count 0)
              (decision-count 0))
          (define (over-budget?)
            "Return #t once the walk has visited more nodes than the budget."
            (> visited max-pure-cost))
          (define (control-plane? operation)
            "Return #t when OPERATION is a default or option-supplied trigger."
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
                       (else
                        (let ((entry (operation-entry head operations)))
                          (if entry (record-request! head node entry)))))
                      (walk-spine node)))))))
          (walk form)
          (let ((status
                 (cond
                  ((not (null? decisions)) 'quarantined)
                  ((over-budget?) 'budget-exhausted)
                  ((not (null? requests)) 'gated)
                  (else 'allowed))))
            (list 'code-action-analysis
                  (list 'form form)
                  (list 'status status)
                  (list 'pure-cost visited)
                  (list 'capability-requests (reverse requests))
                  (list 'quarantine-decisions (reverse decisions)))))))

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
