# Portable Character Model and Unicode Profile

Consent Scheme owns language-visible characters as Unicode scalar values. A
borrowed R7RS host supplies source-text and host-string storage during
bootstrap, but it does not choose character identity, valid code points,
ordering, classification, case mapping, digit values, or UTF-8 validity.

The R7RS-small character and string procedures in
[sections 6.6 and 6.7](r7rs-small-report.md#66-characters) are the language
contract. Consent pins the Unicode Character Database (UCD) at version 17.0.0
and generates portable Scheme tables from repository-owned inputs. Changing
the Unicode version changes table data, not the character representation.

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

## Generated Unicode data ownership

The exact UCD 17.0.0 inputs are vendored under `vendor/unicode/17.0.0/` with
SHA-256 hashes in its README. The repository uses only the files needed by the
R7RS character surface:

- `DerivedCoreProperties.txt` supplies `Alphabetic`, `Uppercase`, and
  `Lowercase`;
- `PropList.txt` supplies `White_Space`;
- `UnicodeData.txt` supplies `Numeric_Type=Decimal` values and simple
  uppercase/lowercase mappings;
- `SpecialCasing.txt` supplies unconditional full uppercase and lowercase
  mappings; and
- `CaseFolding.txt` supplies default non-Turkic simple and full case folding.

`tools/generate-unicode-data.el` verifies the pinned input hashes and writes
`scheme/consent/unicode-data.sld`. `make update-unicode-data` regenerates the
artifact, while `make check-unicode-data` fails when it is stale or its inputs
do not match the pin. Both the UCD inputs and their derived table artifact are
redistributed under the Unicode License v3 (`Unicode-3.0`); the license text is
in `LICENSES/Unicode-3.0.txt` and attribution is recorded in `NOTICE`.

The generated `(consent unicode-data)` library exports only Scheme-readable
version, provenance, range, and mapping data. `(scheme char)` owns the lookup
algorithms. Interpreted bootstraps load both files through the ordinary source
library registry; host-compiled distributions embed and install both through
the manifest-derived runtime source inventory. A future native compiler can
link or transform the same generated library without calling a host Unicode
API. The `(scheme char)` manifest and the generated metadata datum expose the
supported Unicode version to reflection, and `(features)` includes
`full-unicode`.

To adopt a new Unicode version, add a new pinned UCD directory, review the UCD
format and semantic changes, update the generator version and hashes,
regenerate the table library, then run the character, conformance,
compiled-host, license, and readability gates. Unicode upgrades are explicit
repository changes; builds never download floating `latest` data.

## Unicode 17.0.0 profile

All Unicode scalar values remain valid Consent characters. Assigned scalars in
Unicode 17.0.0 receive the generated properties and mappings described below.
Unassigned scalars and scalars assigned by a later Unicode release have false
classification predicates and identity case mappings until the repository pin
is upgraded.

### Classification

`char-upper-case?`, `char-lower-case?`, `char-alphabetic?`, and
`char-whitespace?` use the complete generated `Uppercase`, `Lowercase`,
`Alphabetic`, and `White_Space` property ranges for the pinned version.
`char-numeric?` and `digit-value` use every UCD `Numeric_Type=Decimal` entry,
returning its decimal value from zero through nine. This includes alphabetic
characters with neither case property and decimal blocks outside the earlier
ASCII, Arabic, Indic, Latin, and Greek bootstrap sample.

### Case conversion and folding

`char-upcase` and `char-downcase` use the simple mappings from
`UnicodeData.txt`; `char-foldcase` uses `C` and `S` entries from
`CaseFolding.txt`. `string-upcase` and `string-downcase` combine those simple
mappings with the unconditional full mappings in `SpecialCasing.txt`.
`string-foldcase` uses the `C` and `F` case-folding entries. The default
non-Turkic fold is used; locale-sensitive mappings are out of scope.

Full string mappings can change length. For example, `ß` uppercases to `SS`,
the `ﬃ` ligature uppercases to `FFI`, and both fold to lowercase sequences.
By contrast, simple `char-foldcase` returns one character and leaves `ß`
unchanged. `İ` lowercases and folds to `i` followed by combining dot above
`U+0307`.

Case-insensitive character and string comparisons use these owned fold
mappings, then compare scalar values. The runtime does not normalize Unicode
strings; canonically equivalent but differently normalized strings remain
distinct unless the mappings above make them equal.

Conditional special casing is deliberately omitted. In particular,
`string-downcase` maps Greek capital sigma to ordinary small sigma in every
position instead of selecting final sigma by word context, which R7RS explicitly
permits. Locale-sensitive Turkic and Lithuanian conditions are also omitted.

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
`scheme/consent/char.sld` source loaded by both evaluator bootstraps, backed by
the single generated `scheme/consent/unicode-data.sld` artifact. There is no
parallel host-defined `(scheme char)` primitive provider. A future accelerator
must be checked against these semantics and the shared fixtures before it can
replace an owned path.

## Verification contract

The portable character suite verifies the generated version/provenance datum,
table ordering, representative property and decimal entries across scripts,
simple versus length-changing full case mappings, supplementary-plane casing,
and unassigned-scalar fallback. The shared conformance corpus exercises every
base and case-insensitive character/string comparison in true, false, equality,
prefix, and variadic forms; the complete scalar validity boundary; BMP,
supplementary, and maximum scalar crossings through strings, vectors, ports,
and native adapters; and canonical reader/writer external forms.

UTF-8 fixtures cover every one- through four-byte branch boundary, both sides
of the surrogate gap, multibyte and empty range slices, malformed continuation
bytes, truncation, every overlong width, encoded surrogates, invalid leads, and
values above `U+10FFFF`. The same conformance fixtures run through the Emacs
bootstrap and portable R7RS evaluator. Direct portable tests additionally
check the owned record contracts and native adapter boundaries, while direct
portable and Emacs reader suites retain bootstrap-specific diagnostics and
round trips.
