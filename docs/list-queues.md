# List Queues (SRFI 117)

Consent Scheme provides SRFI 117 mutable list queues as the optional
`(stdlib list-queue)` library. The R7RS-large Red Edition name
`(scheme list-queue)` and SRFI names `(srfi 117)` and `(srfi srfi-117)` resolve
to the same single-sourced portable implementation.

List queues are ordered, mutable collections backed by ordinary Scheme pairs.
They add and remove at the front in constant time and add at the back in
constant time. Removing from the back is linear because the representation has
no backward links.

## Basic use

Import the R7RS-large name when writing code for that standard surface:

```scheme
(import (scheme base)
        (scheme list-queue))

(define pending (list-queue 'read 'expand))
(list-queue-add-back! pending 'evaluate)
(list-queue-remove-front! pending) ; => read
(list-queue-list pending)          ; => (expand evaluate)
```

The project-owned `(stdlib list-queue)` name identifies the implementation in
source and manifest metadata. The three public aliases expose exactly the same
bindings.

## Representation and aliasing

Unlike Consent's private runtime worklist, a list queue intentionally exposes
its backing list. `make-list-queue`, `list-queue-list`,
`list-queue-first-last`, and `list-queue-set-list!` preserve pair identity:

```scheme
(define items (list 'a 'b))
(define queue (make-list-queue items (cdr items)))

(eq? items (list-queue-list queue)) ; => #t
(list-queue-add-back! queue 'c)
items                               ; => (a b c)
```

The optional final-pair argument makes construction or replacement constant
time. The first value must be a list whose final pair is the supplied second
value; the empty list must be paired with the empty list. Supplying unrelated
or inconsistent endpoints is an error.

This shared representation is powerful but requires care. Mutating exposed
pairs can invalidate a queue's stored final-pair pointer. Prefer the queue
mutators when the queue remains live, and avoid sharing one backing list among
independently mutated queues unless the aliasing is deliberate.

`list-queue-copy`, `list-queue-append`, and `list-queue-concatenate` allocate
fresh pair spines. The elements themselves are shallowly shared. In contrast,
`list-queue-append!` joins existing pair spines; callers must not rely on the
argument queues' contents afterward.

## Operations and complexity

| Operation group | Representative procedures | Complexity |
| --- | --- | --- |
| Construct from known endpoints | `make-list-queue` with final pair | O(1) |
| Construct, copy, or map | `list-queue`, `list-queue-copy`, `list-queue-map` | O(n) |
| Empty and endpoint access | `list-queue-empty?`, `list-queue-front`, `list-queue-back` | O(1) |
| Shared-list access | `list-queue-list`, `list-queue-first-last` | O(1) |
| Front insertion or removal | `list-queue-add-front!`, `list-queue-remove-front!` | O(1) |
| Back insertion | `list-queue-add-back!` | O(1) |
| Back removal | `list-queue-remove-back!` | O(n) |
| Remove all | `list-queue-remove-all!` | O(1) |
| Destructive append | `list-queue-append!` | O(number of queues) |
| Nondestructive append | `list-queue-append`, `list-queue-concatenate` | O(total elements) |

Unfold and traversal procedures follow the SRFI ordering rules.
`list-queue-map!` and `list-queue-for-each` call their procedures from front to
back. `list-queue-unfold` places mapped values before an optional existing
queue in seed order; `list-queue-unfold-right` appends them in reverse seed
order.

## Runtime worklist boundary

The public list queue and `(consent worklist)` solve different problems. The
private worklist is bootstrap-safe ring-buffer storage for collectors, graph
algorithms, evaluator passes, bounded capacity, release behavior, and explicit
work accounting. It must not depend on an optional standard library or expose
its storage identity.

SRFI 117 requires ordinary list identity and mutation to be observable. Its
implementation therefore remains list-backed and does not wrap the private
ring buffer. The two facilities share FIFO ordering tests where useful, while
their representation and lifetime contracts stay separate.

## References and verification

The `(stdlib manifest)` entry records the upstream revision, source and test
hashes, BSD-3-Clause licensing, the local SRFI specification, the R7RS-large
Red Edition report, aliases, dependencies, and local conformance repairs.

Portable tests cover the adapted upstream suite plus endpoint identity,
destructive-append tail updates, empty boundaries, callback order, and a linear
FIFO stress case. The Emacs and portable evaluator bootstraps also import the
same source through the manifest aliases.
