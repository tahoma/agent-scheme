# Portable Character Model and Unicode Profile

Consent Scheme owns language-visible characters as Unicode scalar values. A
borrowed R7RS host supplies source-text and host-string storage during
bootstrap, but it does not choose character identity, valid code points,
ordering, classification, case mapping, digit values, or UTF-8 validity.

The R7RS-small character and string procedures in
[sections 6.6 and 6.7](r7rs-small-report.md#66-characters) are the language
contract. This document fixes the smaller deterministic Unicode profile used by
the early self-hosting runtime. Issue
[#727](https://github.com/tahoma/consent/issues/727) can expand the same boundary
with generated and versioned Unicode tables without changing the character
representation.

## Representation and scalar range

A language-visible character is an immutable `(consent character)` record
containing one exact integer. The integer must be a Unicode scalar value:

- `0` through `#x10ffff` are in range;
- surrogate code points `#xd800` through `#xdfff` are excluded;
- negative integers, values above `#x10ffff`, non-integers, and inexact numbers
  are invalid.

`integer->char`, hexadecimal character literals, string element operations,
reader results, ports, and native-library results all enter this representation.
`char->integer` returns the stored scalar. Two owned characters are `eqv?` when
their scalar values are equal. Character ordering and the base string ordering
procedures use scalar-value order and scalar-lexicographic order respectively.

The record layout is private runtime representation, not a public extension to
R7RS. A compiler may use an immediate character encoding, provided it preserves
the scalar range and observable semantics.

Invalid scalar construction and invalid hexadecimal character literals signal
errors. The runtime never exposes a surrogate or an out-of-range host character
as a Consent Scheme character.

## External forms

The reader accepts the R7RS named character table:

| Name | Scalar |
| --- | ---: |
| `alarm` | `#x07` |
| `backspace` | `#x08` |
| `delete` | `#x7f` |
| `escape` | `#x1b` |
| `newline` | `#x0a` |
| `null` | `#x00` |
| `return` | `#x0d` |
| `space` | `#x20` |
| `tab` | `#x09` |

It also accepts `#\x<hex scalar>` and the R7RS single-character form. Named
forms are case-sensitive unless `#!fold-case` is active. The writer emits the
canonical name above when one exists, `#\x<lowercase hex>` for other control
characters, and `#\` followed by the character for other printable scalars.
Reader and writer round trips preserve scalar identity.

## Bootstrap Unicode profile

The bootstrap profile deliberately implements a documented subset rather than
delegating to whichever Unicode release a host happens to provide. Scalars
outside a classification or case table remain valid characters. Their
classification predicates return `#f`, and case conversion returns the input.

### Classification

`char-upper-case?`, `char-lower-case?`, and `char-alphabetic?` cover:

- ASCII letters;
- Latin-1 uppercase ranges `U+00C0..U+00D6` and `U+00D8..U+00DE`;
- Latin-1 lowercase ranges `U+00E0..U+00F6` and `U+00F8..U+00FF`;
- `U+00AA`, `U+00B5`, `U+00BA`, `U+0130`, `U+0131`, `U+0178`, and
  `U+1E9E`;
- Greek uppercase ranges `U+0391..U+03A1` and `U+03A3..U+03AB`;
- Greek lowercase ranges `U+03B1..U+03C1` and `U+03C2..U+03CB`.

`char-whitespace?` owns the Unicode `White_Space` scalar set:
`U+0009..U+000D`, `U+0020`, `U+0085`, `U+00A0`, `U+1680`,
`U+2000..U+200A`, `U+2028`, `U+2029`, `U+202F`, `U+205F`, and `U+3000`.

`digit-value` and `char-numeric?` recognize decimal digits in these blocks:

- ASCII `U+0030..U+0039`;
- Arabic-Indic `U+0660..U+0669`;
- Extended Arabic-Indic `U+06F0..U+06F9`;
- Devanagari `U+0966..U+096F`;
- Bengali `U+09E6..U+09EF`;
- Gurmukhi `U+0A66..U+0A6F`;
- Gujarati `U+0AE6..U+0AEF`.

These are exact bootstrap tables, not claims of complete Unicode
`Alphabetic`, `Uppercase`, `Lowercase`, or `Decimal_Number` coverage.

### Case conversion and folding

Simple character mappings cover ASCII, the listed Latin and Greek ranges, and
the explicit exceptional mappings in those ranges. Greek final sigma
`U+03C2` upcases to `U+03A3` and folds to `U+03C3`. Micro sign `U+00B5`
upcases to Greek capital mu `U+039C`. Latin sharp s `U+00DF` upcases to
`U+1E9E`, and dotless i `U+0131` upcases to ASCII `I`.

String case procedures apply full mappings where one character expands:

- `ß` uppercases to `SS`;
- `ß` and `ẞ` fold to `ss`;
- `İ` lowercases and folds to `i` followed by combining dot above `U+0307`.

Case-insensitive character and string comparisons use these owned fold
mappings, then compare scalar values. The runtime does not normalize Unicode
strings; canonically equivalent but differently normalized strings remain
distinct unless the mappings above make them equal.

## UTF-8

`string->utf8` emits the unique one- through four-byte UTF-8 encoding for each
scalar. `utf8->string` rejects malformed continuation bytes, truncated input,
overlong encodings, encoded surrogates, and values above `U+10FFFF`. It never
accepts a host decoder's replacement-character behavior as successful input.
Optional start and end arguments retain their R7RS bytevector and string range
meaning.

## Host boundary

During bootstrap, source text and string storage are host strings. Adapters
convert a host character to an owned character immediately when a source,
string, port, or native-library operation returns one, and convert back only
when a host string or textual port requires storage. Classification, ordering,
case conversion, folding, digit values, and UTF-8 validation never call host
Unicode procedures.

The public `(scheme char)` implementation is the single portable
`scheme/consent/char.sld` source loaded by both evaluator bootstraps. There is
no parallel host-defined `(scheme char)` primitive provider. A future
accelerator must be checked against these semantics and the shared fixtures
before it can replace an owned path.

## Verification contract

The shared conformance corpus exhausts every finite classification, decimal
digit, whitespace, and simple/full case table in the bootstrap profile, with
excluded-neighbor checks. It exercises every base and case-insensitive
character/string comparison in true, false, equality, prefix, and variadic
forms; the complete scalar validity boundary; BMP, supplementary, and maximum
scalar crossings through strings, vectors, ports, and native adapters; and
canonical reader/writer external forms.

UTF-8 fixtures cover every one- through four-byte branch boundary, both sides
of the surrogate gap, multibyte and empty range slices, malformed continuation
bytes, truncation, every overlong width, encoded surrogates, invalid leads, and
values above `U+10FFFF`. The same conformance fixtures run through the Emacs
bootstrap and portable R7RS evaluator. Direct portable tests additionally
check the owned record contracts and native adapter boundaries, while direct
portable and Emacs reader suites retain bootstrap-specific diagnostics and
round trips.
