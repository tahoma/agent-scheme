;;; SRFI 97 library-reference support for stdlib.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Provides a zero-export shim target for SRFI 97's SRFI Libraries naming
;;; convention.  Supported legacy references such as `(srfi :1)' and
;;; `(srfi :1 lists)' resolve through manifest aliases without vendoring
;;; implementation code or adding bindings outside the referenced SRFI.

(define-library (stdlib srfi-libraries)
  (export)
  (import (scheme base))
  (begin))
