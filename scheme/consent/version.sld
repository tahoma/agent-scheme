;;; Portable Consent Scheme version data.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This library is the single source of truth for the Consent Scheme runtime
;;; version number. Host adapters and portable runtime modules derive their
;;; public version APIs from this Scheme-readable datum instead of repeating
;;; numeric components in implementation source.

(define-library (consent version)
  (export consent-version-datum)
  (import (scheme base))
  (begin
    ;; Define the canonical Consent Scheme version datum.
    (define consent-version-datum
      '(consent-version 0 18 8))))
