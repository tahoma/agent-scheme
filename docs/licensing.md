# Licensing Policy

<!-- This document discusses SPDX tags as prose and examples; the REUSE tool
     must not parse them as this file's own license. The file's license is
     supplied by the root REUSE.toml. -->
<!-- REUSE-IgnoreStart -->

Consent Scheme is licensed under the **Apache License, Version 2.0**
(`SPDX-License-Identifier: Apache-2.0`). The canonical license text lives in
`LICENSE` (so GitHub's repository license detection reports `Apache-2.0`) and in
`LICENSES/Apache-2.0.txt` (so the project is [REUSE](https://reuse.software)
compliant). Attribution is recorded in the root `NOTICE` file. The copyright
holder is **Tahoma Toelkes**. Project authorship, maintenance, and tool-assisted
development attribution are recorded in [Project Credits](credits.md).

This policy is permanent. It was settled by the project owner before broad
outside contributions, vendored libraries, or generated artifacts grew, because
relicensing is only trivial while copyright is held by a single author.

## Why Apache-2.0

- It is the modern mainstream license and matches this project's own
  compilation backends: **Chez** (Apache-2.0), **Gambit** (Apache-2.0/LGPL
  dual), and modern **Racket** (Apache-2.0/MIT dual; relicensed from LGPL in
  2019).
- The reasoning that moved Racket off LGPL applies directly: a guest language
  whose libraries are inlined and macro-expanded into host programs, plus a
  content-addressed library exchange that copies code between agents.
- Over bare MIT/BSD it adds an explicit **patent grant** with retaliation,
  contribution terms, and a `NOTICE`/attribution mechanism. The patent grant is
  itself a fitting act of consent for a capability-security project.
- It is one-way compatible with **GPLv3** (so it composes with the GPL-3.0+
  Emacs host) while keeping the portable core maximally reusable by future
  non-GPL hosts. It is **not** compatible with GPLv2-only.

## What the policy covers

Source code, documentation, conformance fixtures, examples, generated
artifacts, and skill manifests are **all** Apache-2.0 under the same SPDX
scheme — there is no separate treatment per artifact kind.

- **Source files** (`.el`, `.sld`, `.scm`, `.sh`) carry a two-line inline SPDX
  header:

  ```
  SPDX-License-Identifier: Apache-2.0
  SPDX-FileCopyrightText: 2026 Tahoma Toelkes
  ```

  For Emacs Lisp the header sits immediately after the `-*- lexical-binding -*-`
  cookie on line 1; for Scheme files it sits at the top of the file; for shell
  scripts it sits after the shebang.

- **Documentation, skill manifests, build, and configuration files** that do not
  carry an inline header are covered by the root `REUSE.toml` annotation, which
  applies the same Apache-2.0 + copyright.

New files must carry SPDX information — either an inline header (preferred for
source) or an entry in `REUSE.toml`.

## Third-party and vendored material

Any third-party material vendored in the future **keeps its upstream license**.
It must record that license via an inline SPDX header or a dedicated
`REUSE.toml` annotation, and the corresponding `LICENSES/<id>.txt` text must be
added. Such material is tracked under the `review:license-vendor` label. Do not
relabel third-party material as Apache-2.0.

## Contribution and relicensing implications

Because relicensing is only trivial while copyright is single-holder, the
Apache-2.0 decision is intentionally settled **before** broad outside
contributions begin. Outside contributions are accepted under Apache-2.0 §5
(inbound = outbound): a contribution submitted for inclusion is licensed under
Apache-2.0 unless explicitly stated otherwise. A future change of license would
require the agreement of every copyright holder, so contributors should expect
Apache-2.0 to be permanent.

## Verification

- `reuse lint` must pass (run in CI; install with `pip install reuse`).
- GitHub's REST `/license` endpoint and the repository license badge must report
  `Apache-2.0`.

<!-- REUSE-IgnoreEnd -->
