;;; Print native compiler libraries and their source files.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (consent compiler-plan))

(define plan (consent-compiler-plan))
(define units (consent-compiler-plan-units plan))

(define (unit-ref name)
  (let loop ((remaining units))
    (cond
     ((null? remaining)
      (error "native library has no source unit" name))
     ((equal? name (consent-compiler-unit-name (car remaining)))
      (car remaining))
     (else
      (loop (cdr remaining))))))

(for-each
 (lambda (library-name)
   (write library-name)
   (write-char #\tab)
   (display (consent-compiler-unit-source (unit-ref library-name)))
   (newline))
 (consent-compiler-plan-native-libraries plan))
