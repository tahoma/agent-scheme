;;; SRFI 261 portable SRFI reference support for stdlib.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Provides a zero-export shim target for SRFI 261's library-reference naming
;;; contract.  The public `(srfi 261)` and `(srfi srfi-261)` imports resolve
;;; through manifest aliases without vendoring implementation code or inventing
;;; bindings outside the SRFI.

(define-library (stdlib srfi-reference)
  (export)
  (import (scheme base))
  (begin))
