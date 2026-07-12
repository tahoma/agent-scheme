# SRFI 27 Confidence Tests

This directory vendors the upstream `reference/conftest.scm` confidence-test
file from the official SRFI 27 repository:

- Repository: `https://github.com/scheme-requests-for-implementation/srfi-27`
- Commit: `a547c5508d648c61e73bebed2bcd2283fba5abaa`
- Upstream path: `reference/conftest.scm`
- Git blob: `5ceaaf0d8af4af29e8270ac52c00a69f80525cb5`
- SHA-256: `8faeb58b06670d64d35d05bd7a100c2e5d23b35e4ab1159226c4537a819096b3`

The upstream file is preserved as fixture/provenance material. Local executable
coverage lives in `tests/scheme/stdlib-random-bits-upstream-test.scm`, which
adapts the upstream confidence checks to Consent Scheme's R7RS library import
style and default test budget.

The upstream confidence tests deliberately are not a full SRFI 27 conformance
or statistical RNG suite. The local adapted runner executes the upstream default
basic interface checks plus deterministic MRG32k3a state checks, while leaving
the large DIEHARD output writer and the 10^7-real stress check out of the
default local suite.
