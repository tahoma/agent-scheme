;;; Library declaration include fixture for Agent Scheme include tests.
;;;
;;; This file is spliced into a define-library form when include-library-
;;; declarations policy allows access to fixture paths.

(export answer)
(import (scheme base))
(begin
  ;; Define the exported value supplied by the included declaration body.
  (define answer 42))
