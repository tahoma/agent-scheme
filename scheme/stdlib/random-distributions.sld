;;; Random distribution helpers built on SRFI 27 random sources.
;; SPDX-License-Identifier: MIT
;; SPDX-FileCopyrightText: 2002 Sebastian Egner
;; SPDX-FileCopyrightText: 2026 Tahoma Toelkes
;;;
;;; Implements `(stdlib random-distributions)' as a portable adaptation of the
;;; recommended usage examples in SRFI 27. These procedures are intentionally
;;; not exported by the `(srfi 27)' aliases because the SRFI describes them as
;;; examples rather than as part of the specified random-bits interface.

(define-library (stdlib random-distributions)
  (export random-source-make-permutations
          random-permutation
          random-source-make-exponentials
          random-exponential
          random-source-make-normals
          random-normal)
  (import (scheme base)
          (scheme inexact)
          (stdlib random-bits))
  (begin
    (define (%random-distributions-exact-non-negative-integer? value)
      "Return #t when VALUE is an exact non-negative integer."
      (and (integer? value) (exact? value) (not (negative? value))))

    (define (%random-distributions-check-degree n)
      "Validate N as a permutation degree."
      (if (%random-distributions-exact-non-negative-integer? n)
          n
          (error "permutation degree must be exact non-negative integer" n)))

    (define (%random-distributions-check-real name value)
      "Validate VALUE as a real distribution parameter named NAME."
      (if (real? value)
          value
          (error "distribution parameter must be real" name value)))

    (define (%random-distributions-check-positive-real name value)
      "Validate VALUE as a positive real distribution parameter named NAME."
      (if (and (real? value) (< 0 value))
          value
          (error "distribution parameter must be positive real" name value)))

    (define (%random-distributions-check-non-negative-real name value)
      "Validate VALUE as a non-negative real distribution parameter named NAME."
      (if (and (real? value) (not (negative? value)))
          value
          (error "distribution parameter must be non-negative real" name value)))

    (define (random-source-make-permutations source)
      "Return a generator of random permutations backed by SOURCE."
      #((parameters
         (source (type random-source)
          (description "Random source backing the generated procedure.")))
        (returns (type procedure)
         (description "Procedure accepting a degree and returning a permutation vector."))
        (effects allocation state-write))
      (let ((rand (random-source-make-integers source)))
        (lambda (n)
          (let* ((degree (%random-distributions-check-degree n))
                 (result (make-vector degree 0)))
            (do ((i 0 (+ i 1)))
                ((= i degree))
              (vector-set! result i i))
            (do ((k degree (- k 1)))
                ((<= k 1) result)
              (let* ((i (- k 1))
                     (j (rand k))
                     (xi (vector-ref result i))
                     (xj (vector-ref result j)))
                (vector-set! result i xj)
                (vector-set! result j xi)))))))

    ;; Cached permutation generator over the shared default source.
    (define %default-random-permutation
      (random-source-make-permutations default-random-source))

    (define (random-permutation n)
      "Return a random permutation from the default SRFI 27 random source."
      #((parameters
         (n (type exact-non-negative-integer)
          (description "Permutation degree.")))
        (returns (type vector)
         (description "Vector containing each integer in `[0, n)' exactly once."))
        (effects state-write))
      (%default-random-permutation n))

    (define (random-source-make-exponentials source . unit)
      "Return a generator of exponential deviates backed by SOURCE."
      #((parameters
         (source (type random-source)
          (description "Random source backing the generated procedure."))
         (unit (type real)
          (description "Optional precision unit forwarded to `random-source-make-reals'.")))
        (returns (type procedure)
         (description "Procedure accepting a positive mean and returning an exponential deviate."))
        (effects allocation state-write))
      (let ((rand (apply random-source-make-reals source unit)))
        (lambda (mu)
          (let ((mean (%random-distributions-check-positive-real 'mu mu)))
            (- (* mean (log (rand))))))))

    ;; Cached exponential generator over the shared default source.
    (define %default-random-exponential
      (random-source-make-exponentials default-random-source))

    (define (random-exponential mu)
      "Return an exponential deviate from the default SRFI 27 random source."
      #((parameters
         (mu (type positive-real)
          (description "Distribution mean.")))
        (returns (type real)
         (description "Exponential deviate with mean MU."))
        (effects state-write))
      (%default-random-exponential mu))

    (define (random-source-make-normals source . unit)
      "Return a generator of normal deviates backed by SOURCE."
      #((parameters
         (source (type random-source)
          (description "Random source backing the generated procedure."))
         (unit (type real)
          (description "Optional precision unit forwarded to `random-source-make-reals'.")))
        (returns (type procedure)
         (description "Procedure accepting a mean and standard deviation and returning a normal deviate."))
        (effects allocation state-write))
      (let ((rand (apply random-source-make-reals source unit))
            (next #f))
        (lambda (mu sigma)
          (let ((mean (%random-distributions-check-real 'mu mu))
                (deviation
                 (%random-distributions-check-non-negative-real 'sigma sigma)))
            (if next
                (let ((result next))
                  (set! next #f)
                  (+ mean (* deviation result)))
                (let loop ()
                  (let* ((v1 (- (* 2 (rand)) 1))
                         (v2 (- (* 2 (rand)) 1))
                         (radius-squared (+ (* v1 v1) (* v2 v2))))
                    (if (or (<= radius-squared 0)
                            (>= radius-squared 1))
                        (loop)
                        (let ((scale
                               (sqrt (/ (* -2 (log radius-squared))
                                        radius-squared))))
                          (set! next (* scale v2))
                          (+ mean (* deviation scale v1)))))))))))

    ;; Cached normal generator over the shared default source.
    (define %default-random-normal
      (random-source-make-normals default-random-source))

    (define (random-normal mu sigma)
      "Return a normal deviate from the default SRFI 27 random source."
      #((parameters
         (mu (type real)
          (description "Distribution mean."))
         (sigma (type non-negative-real)
          (description "Distribution standard deviation.")))
        (returns (type real)
         (description "Normal deviate with mean MU and standard deviation SIGMA."))
        (effects state-write))
      (%default-random-normal mu sigma))))
