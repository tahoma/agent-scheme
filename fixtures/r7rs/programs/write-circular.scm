;;; write-circular.scm --- Circular writer conformance
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This program isolates datum-label syntax whose spelling is exercised by
;;; the writer while keeping the enclosing fixture suite label-free.

(import (scheme base)
        (scheme write))

(let ((out (open-output-string)))
  (write '#0=(a . #0#) out)
  (get-output-string out))
