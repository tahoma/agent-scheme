;;; capability.sld --- Agent capability grant library
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; This host-neutral library exposes Scheme-visible grant helpers while the
;;; host adapter owns real capability enforcement.

(define-library (consent capability)
  (export grant-capability!
          current-grants
          grant-ref
          grant-attenuate
          grant-revoke!
          handle-ref
          handle-live?
          handle-kind
          handle-revalidate
          handle-release!
          call-with-capability-grant
          with-capability-grant)
  (import (scheme base)
          (consent capability primitive))
  (begin
    ;; Run BODY while GRANT is established for hosts that track dynamic grant
    ;; use; the primitive owns validation and host-side cleanup.
    (define-syntax with-capability-grant
      (syntax-rules ()
        ((_ grant body ...)
         (call-with-capability-grant grant (lambda () body ...)))))))
