;;; Portable Consent Scheme test-plan resolver.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (testing runner))

(testing-runner-plan-main (command-line))
