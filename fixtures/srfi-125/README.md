# SRFI 125 upstream tests

`reference/tables-test.sps` is the unmodified upstream test program from
<https://github.com/scheme-requests-for-implementation/srfi-125> at revision
`d80d0e954480983b3e60c40041f3d0bec366e0ba`. Its SHA-256 digest is
`ac26a6e1bd6fbbb064a6f506806a2e2b2a9ad8df3719c81d31dc34b6d0f8c4b3`.

The upstream program is MIT-licensed and carries its complete license notice.
The executable port in `tests/scheme/stdlib-hash-table-upstream-test.scm`
retains every upstream test form. Its compatibility prelude replaces only the
unavailable `(scheme sort)` and `(srfi 126)` imports, and its epilogue reports
the upstream aggregate through Consent's portable test runner.
