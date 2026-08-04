;;; Print dependency-ordered compiler-plan source files.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (consent compiler-plan))

(for-each
 (lambda (unit)
   (display (consent-compiler-unit-source unit))
   (newline))
 (consent-compiler-plan-units (consent-compiler-plan)))
