;;; Print the runtime-owned source file inventory for build manifests.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme write)
        (consent library))

(for-each
 (lambda (source-file)
   (display source-file)
   (newline))
 (consent-runtime-source-files))
