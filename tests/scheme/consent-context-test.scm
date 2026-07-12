;;; Portable Agent Context semantic tests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (agent context)
        (testing harness)
        (stdlib testing)
        (stdlib random-bits)
        (stdlib random-data-generators)
        (stdlib property-testing))

;; SRFI 64 runner makes this Scheme file the semantic harness; ERT only starts
;; the selected R7RS host process.
(consent-test-run "Agent Context portable semantics"
  (test-equal "context field"
              '(request-id req-1)
              (context-field 'request-id 'req-1))
  (test-assert "present value" (context-present? 'value))
  (test-assert "absent value" (not (context-present? #f)))
  (test-equal
   "request context omits absent fields"
   '(request-context (request-id req-1) (request "inspect"))
   (make-request-context 'req-1 #f "inspect"))
  (test-equal "empty request context" #f
              (make-request-context #f #f #f))
  (test-equal
   "conversation summary"
   '(conversation-summary (session-id session-1) (summary "hello"))
   (make-conversation-summary 'session-1 "hello"))
  (test-equal "empty conversation summary" #f
              (make-conversation-summary 'session-1 #f))
  (test-equal
   "focus filters absent records"
   '(focus-context
     (request-context (request-id req-1))
     (conversation-summary (summary "hello")))
   (make-focus-context
    (list (make-request-context 'req-1 #f #f)
          #f
          (make-conversation-summary #f "hello"))))
  (test-equal
   "context bundle"
   '(context
     (request-context (request-id req-1))
     (focus-context (conversation-summary (summary "hello"))))
   (make-context-bundle
    (list
     (make-request-context 'req-1 #f #f)
     (make-focus-context
      (list (make-conversation-summary #f "hello"))))))
  (test-property
   (lambda (present? request-id)
     (let ((context
            (make-request-context
             (if present? request-id #f) #f #f)))
       (if present?
           (and (pair? context)
                (eq? (car context) 'request-context))
           (eq? context #f))))
   (list (make-random-boolean-generator) (exact-integer-generator))
   25))
