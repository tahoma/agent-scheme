;;; Compiled-host smoke tests for public persistent AVL trees.
;; SPDX-License-Identifier: Apache-2.0
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes

(import (scheme base)
        (scheme process-context)
        (data avl-tree)
        (testing registry)
        (testing runner)
        (stdlib testing))

;; Small persistent tree shared by the compiled-host smoke assertions.
(define tree
  (alist->avl-tree < '((3 . three) (1 . one) (4 . four) (2 . two))))

(testing-registry-case
 'avl-smoke-lookup '(portable data)
(test-equal 'avl-smoke-lookup
            '(two missing 4)
            (list (avl-tree-ref tree 2)
                  (avl-tree-ref/default tree 8 'missing)
                  (avl-tree-size tree))))

(testing-registry-case
 'avl-smoke-persistent-delete '(portable data)
(test-equal 'avl-smoke-persistent-delete
            '(((1 . one) (2 . two) (3 . three) (4 . four))
              ((1 . one) (3 . three) (4 . four)))
            (list (avl-tree->alist tree)
                  (avl-tree->alist (avl-tree-delete tree 2)))))

(testing-registry-case
 'avl-smoke-neighbors '(portable data)
(test-equal 'avl-smoke-neighbors
            '((2 two) (4 four))
            (list
             (call-with-values
              (lambda () (avl-tree-key-predecessor tree 3))
              list)
             (call-with-values
              (lambda () (avl-tree-key-successor tree 3))
              list))))

(testing-runner-main "Data AVL tree smoke" (command-line))
