;;; Print compiler-plan root library names.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (consent compiler-plan))

(for-each
 (lambda (library-name)
   (write library-name)
   (newline))
 (consent-compiler-plan-roots (consent-compiler-plan)))
