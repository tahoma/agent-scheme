;;; Portable test-plan fixture.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(testing-plan
 (version 1)
 (programs
  ((program (path "fast.scm") (tags (full fast)))
   (program (path "compiled.scm") (tags (compiled slow)))))
 (shards
  ((shard (name full) (selector (tag full)))
   (shard (name compiled) (selector (tag compiled))))))
