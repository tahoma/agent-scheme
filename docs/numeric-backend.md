# Self-Hostable Numeric Backend

Consent Scheme owns the meaning and portable implementation of Scheme numbers.
The R7RS runtime uses owned exact-integer limbs, normalized rationals, and
software binary64 tuples; host numbers remain only at checked adapter and
transcendental seams. This document fixes that representation and operation
contract, inventories the remaining host dependencies, and defines the boundary
later compiler and allocation work must consume.

The R7RS-small numerical tower in [section 6.2](r7rs-small-report.md#62-numbers)
is the language contract. This document chooses one deterministic semantic
realization of that contract while allowing target-tuned physical integer
profiles; it does not add an optional numeric SRFI or make the current bootstrap
record layout public API.

## Staged ownership

Numeric ownership has three stages:

1. **Canonical bootstrap values.** The Emacs bootstrap wraps language-visible
   numbers in Consent-owned records while using Emacs integers and floats behind
   its private accelerator seams.
2. **Self-hosted semantic backend.** Exact integers, exact rationals, finite
   inexact reals, mixed-exactness comparison, conversion, and rendering use the
   owned representations and algorithms below. Host numeric procedures may be
   selected only as checked accelerators whose result is normalized through the
   same contract. The portable runtime implements this stage in
   `(consent numeric)` and stores its values behind `(consent reader)`'s
   canonical number shell.
3. **Compiled representation.** The runtime ABI work in
   [#120](https://github.com/tahoma/consent/issues/120) chooses immediate versus
   boxed encodings and call conventions. The allocation and collection contract
   in [#333](https://github.com/tahoma/consent/issues/333) chooses object headers,
   traversal, roots, and collector behavior. Neither issue may redefine the
   numerical semantics fixed here.

Stage 1 remains a valid temporary bootstrap posture for Emacs because the Emacs
path is not the representation consumed by the self-hosted compiler. It is not
stage-2 representation parity: its `consent-number` payloads still contain host
integers and floats, and it must pass the shared semantic corpus at that
explicit adapter seam. The portable R7RS reader and evaluator are at stage 2;
their `consent-number` records contain opaque owned payloads rather than host
bignums or flonums.

## Semantic representation

The representation is immutable. Caches and accelerator values are private and
rebuildable; they do not participate in `eqv?`, external rendering, hashing, or
cross-process exchange.

| Scheme value | Self-hosted semantic representation | Canonical invariants |
| --- | --- | --- |
| Exact integer | A profile-bounded immediate host fixnum, or a sign plus a little-endian sequence of backend-selected base-2^w limbs | Immediate magnitudes are at most both the host's configured fixnum limit and `B^2 - 1`. Larger values have no high zero limbs and each limb is in `[0, B - 1]`. Results promote on overflow and demote after normalization. |
| Exact rational | Owned numerator integer plus owned denominator integer | Denominator is positive, numerator and denominator are coprime, and zero is `0/1`. A denominator of one is represented as an integer. |
| Finite inexact real | Binary64 semantic tuple: class, sign, unbiased exponent, and 53-bit significand stored with owned integers | Round to nearest, ties to even. Subnormals are supported. Consent's baseline canonicalizes both zero signs to positive zero, which R7RS permits. |
| Infinity | Inexact-real class `infinity` plus sign | Exactly two infinity values. |
| NaN | Inexact-real class `nan` | One canonical quiet NaN. Input `-nan.0` normalizes to it; no payload or signaling distinction is exposed. |
| Complex | Ordered pair of canonical real components | Components are never complex. The value is exact only when both components are exact. |

The owned representation has a fixnum/bignum storage split. `Fixnum` names the
direct implementation representation, not a distinct Consent numeric type or
a limit on language-visible integers. The backend fixes a symmetric immediate
bound as the lesser of its limb accumulator bound and its target's configured
fixnum bound. It represents values inside that range directly, promotes larger
results to owned limbs, and demotes normalized results that return to the
range. This removes record and vector allocation from ordinary evaluator
integer arithmetic while keeping exact integers unbounded.

### Exact-integer limb profiles

`w` is the backend's positive `limb-bits` parameter. One running backend and
compiled ABI select one fixed value of `w`; individual integers do not carry a
limb-width tag and arithmetic never mixes widths. The derived limb base is
`B = 2^w`, and the derived limb mask is `B - 1`. A backend may specialize these
constants when its source is loaded, when it is built, or when a native target
is selected. Limb width is not a language setting and changing it does not
produce a different class of Scheme number.

The default self-hosted profile targets 64-bit machines and uses `w = 30`. For
the normalized schoolbook multiplication inner step
`a[i] * b[j] + output[i + j] + carry`, where every term is bounded by `B - 1`,
the maximum accumulator is `B^2 - 1`. The default profile therefore needs at
most `2^60 - 1`. That fits exactly in a signed 64-bit working integer and in
the immediate fixnum range of a 64-bit Emacs build with a `2^61 - 1` positive
limit, so the bootstrap's hot inner loop does not allocate host bignums. A
31-bit limb would raise the same bound to `2^62 - 1` and cross that Emacs
fixnum limit.

For this default profile, the owned backend's fixnum range is
`[-(B^2 - 1), B^2 - 1]`, or `[-(2^60 - 1), 2^60 - 1]`. The same bound governs
checked host-integer accumulators. That symmetric bound is a backend portability
choice, not the maximum fixnum of every host: for example, the measured Emacs
build has one additional positive fixnum bit.

The Emacs bootstrap and representative 64-bit builds of every R7RS
implementation wired into the development and oracle matrix use the same broad
strategy: exact integers inside a host-specific bound are immediate fixnums,
while larger exact integers take a non-fixnum bignum path. The observed bounds
below are implementation and build properties, not R7RS guarantees:

| Host path | Repository role | Observed positive fixnum limit | Largest `w` whose `B^2 - 1` multiplication accumulator remains immediate |
| --- | --- | ---: | ---: |
| Emacs 30.2 | bootstrap twin | `2^61 - 1` | 30 |
| Gambit 4.9.7 | canonical direct and compiled host | `2^60 - 1` | 30 |
| Racket CS 9.2 | default direct and compiled host | `2^60 - 1` | 30 |
| Guile 3.0.11 | direct host and portable lint gate | `2^61 - 1` | 30 |
| Gauche 0.9.15 | direct host and oracle | `2^61 - 1` | 30 |
| Chibi 0.12.0 | optional direct host and oracle | `2^62 - 1` | 31 |
| CHICKEN 5.4.0 | oracle | `2^62 - 1` | 31 |
| Sagittarius 0.9.14 | oracle | `2^61 - 1` | 30 |

These observations use each implementation's fixnum predicate or fixnum-range
library and confirm that `2^100` remains an exact non-fixnum integer. The
30-bit profile therefore keeps the stated multiplication step immediate across
the complete representative host matrix. Racket and Gambit have no spare
fixnum bit at that bound, so an implementation must not fold additional terms
into the accumulator without a stronger proof. Chibi and CHICKEN may benefit
from a measured 31-bit specialization, but the one-bit increase is not part of
the common default.

A different backend may select another width when it proves every intermediate
bound used by its multiplication, division, parsing, and rendering algorithms.
Useful profiles include `w = 14` for a constrained bootstrap with signed 30-bit
exact working arithmetic and `w = 62` for native code with signed 128-bit
accumulators. A backend with unsigned 128-bit multiply/add-with-carry operations
may instead prove a full `w = 64` profile. Wider native targets may select wider
limbs when they provide the corresponding double-width operations. The largest
valid limb is not automatically the fastest choice, so a native backend may
choose a narrower measured profile.

A backend must reject a configured profile at startup if its primitive
working arithmetic cannot represent the profile's proven bounds exactly.
Backend source must derive radix operations from `limb-bits`, `B`, and the limb
mask rather than embedding a profile's numeric literals. Algorithm thresholds
must be expressed in value bits or tuned per profile instead of assuming that a
limb count has the same cost everywhere.

The portable constructor accepts every positive `w`, so the representation and
algorithms can be exercised for future targets without changing their API.
Thirty bits is the largest profile whose multiplication accumulator is proven
to remain an immediate integer across the common 64-bit bootstrap matrix.
Wider profiles may allocate host bignums while tested on an existing R7RS host;
a native implementation must reject them unless it provides the stronger exact
accumulator operations. The portable implementation also caps direct integers
at the common `2^60 - 1` fixnum limit independently of `w`, so a `w = 62`
simulation promotes values above that limit rather than mistaking a host
bignum for a fixnum. A native 128-bit target may specialize that separate
fixnum bound after proving its tagged representation and ABI. The boundary
corpus exercises `w = 62` as the representative signed-128-bit limb profile.

Serialized values, hashing, external rendering, and language semantics do not
expose `w`. Native code compiled for different limb profiles cannot exchange raw
numeric object bytes; it must use canonical numeric structure or external form
at that boundary.

The `integer`, `rational`, `decimal`, `infnan`, and `complex` record kinds are a
canonical shell around the owned payloads. Callers outside the reader and
evaluator use numeric operations and predicates rather than branch on the
physical payload layout.

## Required owned algorithms

The following operations are semantic blockers for a self-hosted root. They
must have portable owned implementations before a runtime can claim that its
numeric semantics are independent of the bootstrap host.

### Exact arithmetic

- digit and radix parsing without constructing a host bignum;
- integer sign, comparison, addition, subtraction, multiplication, shifts, and
  small-limb division;
- multi-limb quotient and remainder with truncating and floor variants;
- greatest common divisor and rational normalization;
- exact rational arithmetic and cross-product comparison;
- nonnegative integer exponentiation and exact integer square root;
- exact integer and rational rendering in radices 2, 8, 10, and 16.

Schoolbook multiplication and normalized long division are the baseline
algorithms. Faster multiplication or division is an optional accelerator, not a
different semantic tier. Implementations must reduce intermediate rational
values early enough to avoid avoidable quadratic growth, but reduction timing
must not change the result.

### Finite inexact core

- correctly rounded decimal and rational conversion to the binary64 tuple;
- binary64 addition, subtraction, multiplication, division, classification,
  and ordering with round-to-nearest/ties-to-even behavior;
- exact conversion of a finite binary64 value to its dyadic rational value, or
  a documented R7RS-permitted rational approximation for the public `exact`
  procedure;
- mixed exact/inexact equality and ordering by comparing an exact rational with
  the finite inexact value's exact dyadic rational, rather than coercing the
  exact argument to a flonum;
- shortest decimal rendering that round-trips through `string->number` and
  preserves `eqv?`, with a decimal point for finite inexact values whenever the
  R7RS rule requires one;
- deterministic overflow to signed infinity, underflow to the supported
  subnormal or canonical positive zero, and propagation to the canonical NaN.

Comparing mixed values by first converting every operand to host inexact form is
not an allowed self-host implementation. It can violate the transitivity
requirement called out by R7RS for large exact integers.

Consent's baseline does not distinguish negative zero. Readers, arithmetic,
conversion, `eqv?`, and writers normalize it to positive zero. This is an
intentional use of the R7RS implementation choice, not an accidental property
of a particular host writer.

### Complex arithmetic

Rectangular addition, subtraction, multiplication, division, predicates,
`real-part`, and `imag-part` are pure compositions of the owned real backend.
They must not unwrap components into a host complex type. Exact inputs remain
exact whenever R7RS requires an exact result.

## Checked accelerators

The owned core has two optional fast paths that do not change its storage or
fallback semantics:

- Exact add, multiply, division, import, and canonical rendering may use host
  arithmetic only after their value and result bounds have been proved against
  the selected profile's `B^2 - 1` accumulator maximum. Results remain directly
  represented only through the separately configured fixnum limit; larger
  results promote to owned limbs. On a simulated wider profile the host may
  use bignums for these checked accumulators, while a production native target
  must provide the profile's proven fixed-width operations. Values outside the
  accumulator proof use the same schoolbook, long-division, parsing, and
  rendering algorithms exercised beyond `B^2` by the alternate-profile tests.
- A host with the checked binary64 behavior may accelerate ordinary finite
  addition, subtraction, multiplication, and division. Results are immediately
  decoded into the owned class/sign/significand/exponent tuple, and any cached
  host float is private and rebuildable. The software binary64 operations remain
  the defining fallback and are tested directly for arithmetic, rounding,
  subnormal, overflow, infinity, and NaN behavior.

The host-math seam reconstructs an uncached finite tuple directly from its
at-most-53-bit significand and power-of-two exponent. It must never format the
tuple as shortest decimal text and parse it back: parsed source literals
naturally lack a host cache, so that design turns ordinary repeated constants
into arbitrary-precision rendering work inside every arithmetic loop. Decimal
search belongs only to external rendering.

These are implementation accelerators for already-owned algorithms, not
deferred semantic work.

### Deferred math accelerators

The current bootstrap may retain host implementations of `sqrt`, `exp`, `log`,
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, polar construction, magnitude,
and angle through the compiled-runtime ABI milestone. These procedures are
temporary accelerators because portable, correctly rounded transcendental
implementations are substantially larger than the core representation and
arithmetic contract.

Every retained accelerator has these obligations:

- validate and classify Consent values before host conversion;
- canonicalize infinities and all NaNs before returning to language-visible
  code;
- construct complex results from canonical real components;
- use shared fixtures for exact identities, special values, and cross-host
  result spelling;
- remain replaceable by an owned algorithm or a different backend without
  changing public bindings or record shapes.

The representative transcendental fixture deliberately uses values whose
results are exact across ordinary libm implementations. No bit-for-bit
cross-host claim is made for general transcendental results until an owned
fallback is selected. This conformance note is the explicit deferral permitted
by [#350](https://github.com/tahoma/consent/issues/350); #120 supplies the later
call boundary but does not own or weaken the semantics.

## Host dependency inventory

The inventory names semantic roles rather than every arithmetic token. Moving a
call without changing its role does not change its classification.

| Current dependency | Current seam | Classification | Required closure |
| --- | --- | --- | --- |
| Owned limbs in reader digit accumulation, decimal scaling, gcd, rational reduction, and radix rendering | `(consent numeric)` through `(consent reader)` | Closed in portable runtime | All language-sized exact payload work uses owned algorithms. |
| Owned exact evaluator arithmetic, comparison, quotient/remainder, rounding, `gcd`, `lcm`, `expt`, `rationalize`, and exact square root | `(consent numeric)` through `(consent interpreter)` | Closed in portable runtime | No evaluator exact operation unwraps to a host bignum; bounded host-fixnum shortcuts use the profile-derived accumulator proof and retain the owned fallback. |
| Owned binary64 tuples in decimal/rational input, finite arithmetic, comparison, `exact`/`inexact`, and decimal rendering | `(consent numeric)` binary64 operations | Closed in portable runtime | Conversion rounds ties to even; mixed comparisons use exact dyadic rationals; rendering searches the shortest round-tripping significand; checked host binary64 arithmetic may accelerate the owned software fallback. |
| Explicit owned infinity and NaN values | canonical special-value ingress/egress | Closed in portable runtime | Finite arithmetic constructs and classifies special values without host divide-by-zero expressions. |
| Host `sqrt` and transcendental/math library procedures | `primitive-inexact-unary`, `primitive-sqrt`, polar, magnitude, and angle helpers | Temporary accelerator | Keep behind canonical conversion and parity fixtures until the post-ABI owned fallback. |
| Emacs integer, float, and math operations in the bootstrap twin | `consent--number-*` helpers | Temporary bootstrap accelerator | Preserve the same semantic normalization and shared parity corpus; do not make Emacs objects part of the portable representation. |
| Raw host numbers at native source-library and compiled host-run boundaries | datum conversion and native-call bridges in `(consent runtime)` and `(consent library)` | Later backend concern | #120 defines value/call marshalling; #333 defines ownership and traversal. No raw host number may cross a native Consent ABI. |
| Immediate versus boxed numbers, limb buffers, and object traversal | future compiler runtime | Later backend concern | Follow the ABI and allocation rules below without changing numerical equality or rendering. |

New host numeric dependencies must fit one of the named seams and gain a
conformance case. Adding direct host arithmetic to a reader, evaluator
primitive, writer, or library is otherwise a boundary regression.

## Bootstrap fences

The canonical constructors in `(consent reader)` are the only ingress for
language-visible numeric values. Special-value classification and external
rendering are Consent operations. A constructor may accept a host number from a
bootstrap adapter, but it immediately imports that value into owned storage.

The portable inexact accelerator fence consists of:

- `number->reader-float` for reader-side polar conversion;
- `number->host-float` for evaluator-side finite math conversion;
- `primitive-inexact-unary` plus the focused polar/magnitude/angle helpers for
  host math dispatch;
- `consent-make-canonical-decimal`,
  `consent-make-canonical-infnan`, and
  `consent-make-canonical-complex` for return normalization.

The Emacs bootstrap uses the parallel private `consent--number->float`,
`consent--primitive-inexact-unary`, and canonical constructors. These are
bootstrap seams, not portable APIs.

`consent-number-owned-value` is the opaque reader/evaluator payload seam.
`consent-number-value` remains a compatibility adapter for small host counts,
legacy tests, and finite transcendental arguments. It refuses to manufacture a
host bignum; language-sized arithmetic never calls it.

## ABI and allocation contract

The compiler/runtime boundary must preserve these rules:

- small exact integers may be immediate, but promotion to a limb object is
  invisible and never reports overflow while allocation is available;
- exact-integer limb storage and finite-inexact significand storage contain no
  traced references;
- rationals and complex numbers trace their two numeric children;
- all numeric objects are immutable and can be shared freely;
- a backend may box binary64 values or use an immediate representation, but
  canonical zero, infinity, and NaN behavior is identical;
- temporary arithmetic buffers are not language-visible objects and are rooted
  for their full allocation lifetime;
- an out-of-memory condition is a runtime allocation failure, never silent
  coercion from an exact value to an inexact value;
- content hashing and managed cross-process exchange use canonical numeric
  structure or canonical external form, never host object bytes.

This is the handoff to #120 and #333. The ABI may tune tags, headers, alignment,
the target's fixed limb profile, and allocation strategy after measuring them,
but it must preserve these semantic and traversal invariants. The selected
profile is part of a compiled target's private object ABI, not the Scheme
language ABI.

## Conformance gates

The shared R7RS fixture corpus covers the representation risks most likely to
vary across bootstrap hosts:

- `numeric-exact-integer-growth`;
- `numeric-rational-reduction-growth`;
- `numeric-exactness-conversion-boundary`;
- `numeric-mixed-exact-inexact-ordering`;
- `numeric-inexact-edge-arithmetic`;
- `numeric-binary64-rounding-boundaries`;
- `numeric-complex-division`;
- `numeric-canonical-rendering`;
- the existing rational, radix, square-root, complex, special-value, polar, and
  transcendental cases.

`tests/scheme/consent-fixture-test.scm` runs that one corpus under direct R7RS
hosts, the Emacs bootstrap, and both compiled self-host products. Its admission
to the `compiled` test-plan partition is the concrete self-host closure exposed
by [#659](https://github.com/tahoma/consent/issues/659). A future accelerator
must pass the same corpus before it can replace an owned path.

The owned backend additionally runs white-box tests parameterized by
`limb-bits`. Boundary cases cover `B - 1`, `B`, `B + 1`, `B^2 - 1`, and
`B^2`, plus each profile's separate positive and negative fixnum limit,
promotion one integer beyond it, and demotion after arithmetic returns to the
limit. They also cover sign normalization, carry propagation, quotient
correction, and checked accelerator fallback. Deterministic multi-limb cases
verify quotient reconstruction and remainder bounds under both division
conventions, square root reconstruction, GCD, large-factor rational
cancellation, rounding modes, and radix round trips. A fixed large-value
corpus must also produce identical canonical results under every profile.

The binary64 matrix covers exact-dyadic and shortest-decimal round trips,
subnormal underflow, the subnormal/normal boundary, the `2^53` integer
boundary, finite overflow, arithmetic halfway cases, special-value arithmetic,
ordering, and canonical zero. Malformed decimal text, unsupported radices, and
invalid special tuples are rejection cases rather than preconditions hidden
from the tests. Continuous integration exercises the default 30-bit profile,
the constrained-bootstrap 14-bit profile, and the signed-128-bit 62-bit
profile so parameterization cannot become a nominal, untested option.

These fixtures prove the portable stage-2 semantic contract and the remaining
accelerator fences. The Emacs bootstrap continues to satisfy the same
language-level corpus through its private host-number implementation.
