# SRFI 180 JSON Fixture Corpus

This directory vendors the upstream `srfi/files` corpus from the official
SRFI 180 repository:

- Repository: `https://github.com/scheme-requests-for-implementation/srfi-180`
- Commit: `671857bac55c53e3190a24ec53b457321a1d8f12`
- Upstream path: `srfi/files`

Only fixture data is vendored here. The upstream SRFI 180 implementation and
Scheme check libraries are intentionally not copied into the repository; local
tests exercise Consent Scheme's owned `(stdlib json)` implementation through
its `(srfi 180)` aliases.

The upstream corpus includes:

- `y_*.json`: valid JSONTestSuite-style JSON texts.
- `n_*.json`: invalid JSONTestSuite-style JSON texts.
- `i_*.json`: implementation-defined edge JSON texts.
- `*.jsonl`: JSON Lines samples from `python-jsonlines`.
- `*.log`: JSON Text Sequences samples from `json-text-sequence`.

Licensing is recorded in `REUSE.toml`. The JSON fixture corpus is MIT-licensed
with the upstream `srfi/files/LICENSE` notice. The JSON Lines samples carry
BSD-3-Clause provenance from `python-jsonlines`; the JSON Text Sequences logs
carry MIT provenance from `json-text-sequence`.
