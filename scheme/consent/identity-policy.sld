;;; Shared fixed policy for host identity storage.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(define-library (consent identity-policy)
  (export consent-identity-compatibility-limit
          consent-identity-map-maximum-capacity)
  (import (scheme base))
  (begin
    ;; No-hash scans stay constant-bounded independently of caller limits.
    (define consent-identity-compatibility-limit 64)

    ;; Covers the runtime's ten-million-node default evaluation envelope.
    (define consent-identity-map-maximum-capacity 16777215)))
