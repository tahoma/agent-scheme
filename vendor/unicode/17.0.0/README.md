# Unicode Character Database 17.0.0 inputs

This directory vendors the exact Unicode Character Database (UCD) inputs used
to generate `scheme/consent/unicode-data.sld`. They come from the versioned
Unicode 17.0.0 directory:

<https://www.unicode.org/Public/17.0.0/ucd/>

The files are redistributed under the Unicode License v3, identified by SPDX
as `Unicode-3.0`; its text is in `LICENSES/Unicode-3.0.txt`.

Pinned SHA-256 hashes:

- `CaseFolding.txt`:
  `ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`
- `DerivedCoreProperties.txt`:
  `24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08`
- `PropList.txt`:
  `130dcddcaadaf071008bdfce1e7743e04fdfbc910886f017d9f9ac931d8c64dd`
- `SpecialCasing.txt`:
  `efc25faf19de21b92c1194c111c932e03d2a5eaf18194e33f1156e96de4c9588`
- `UnicodeData.txt`:
  `2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c`

The generator verifies every hash before writing output. Run:

```sh
make update-unicode-data
make check-unicode-data
```

To adopt a later Unicode release, add a new versioned input directory, review
the Unicode release and UCD format changes, update the version and hashes in
`tools/generate-unicode-data.el`, regenerate the Scheme library, and run the
character, conformance, compiled-host, license, and readability gates. Keep the
old directory until downstream compatibility review decides whether it is
still needed.
