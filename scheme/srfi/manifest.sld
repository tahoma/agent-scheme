;;; Portable SRFI support manifest.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library records optional stdlib-plus SRFI support as Scheme-readable
;;; data.  It is source-loaded by each bootstrap so vendored, shimmed, or owned
;;; implementations stay visible to tools without querying host state.

(define-library (srfi manifest)
  (export srfi-manifest srfi-manifest-ref)
  (import (scheme base))
  (begin
    ;; Manifest entries describe optional libraries owned or surfaced locally.
    (define srfi-manifest
      '(((library . (srfi 180))
         (status . direct-portable-implementation)
         (source-url . "https://github.com/scheme-requests-for-implementation/srfi-180")
         (upstream-revision . "671857bac55c53e3190a24ec53b457321a1d8f12")
         (upstream-license . "MIT")
         (local-license . "Apache-2.0")
         (vendored? . #f)
         (local-patches . ())
         (implementation-library . (consent json))
         (import-aliases . ((srfi 180) (srfi srfi-180)))
         (dependencies . ((consent json)))
         (test-status . (import-resolution representative-read-write
                         emacs-json-oracle portable-host-suite)))
        ((library . (srfi srfi-180))
         (status . alias)
         (target . (srfi 180))
         (import-aliases . ((srfi srfi-180)))
         (dependencies . ((srfi 180)))
         (test-status . (import-resolution)))))

    (define (srfi-manifest-ref library)
      "Return manifest metadata for LIBRARY, or #f when absent."
      #((parameters
         (library (type list)
          (description "SRFI library name to look up.")))
        (returns (type (or list boolean))
         (description "Manifest entry for LIBRARY, or #f."))
        (effects pure))
      (let loop ((rest srfi-manifest))
        (cond
         ((null? rest) #f)
         ((equal? (cdr (assq 'library (car rest))) library) (car rest))
         (else (loop (cdr rest))))))))
