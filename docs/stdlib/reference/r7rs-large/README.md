# R7RS-Large Docket References

Consent Scheme implements some `(scheme ...)` library aliases whose names come
from R7RS-large docket decisions, while the concrete APIs remain defined by
their underlying SRFIs.

The snapshots in this directory come from the official
`https://codeberg.org/scheme/r7rs` repository. Its `LICENCE.txt` grants
permission to copy Scheme reports in whole or in part without fee and
encourages implementors to use the reports as a starting point for manuals and
documentation. The older `johnwcowan/r7rs-work` GitHub repository was not used
as a source because it does not publish repository license metadata.

Current stdlib aliases backed by these docket reports include:

- `(scheme list)`: Red Edition accepted SRFI 1 as `(scheme list)`.
- `(scheme comparator)`: Red Edition accepted SRFI 128 as
  `(scheme comparator)`.
- `(scheme generator)`: Tangerine Edition accepted SRFI 158 as
  `(scheme generator)`, superseding the Red Edition generator selection.
- `(scheme mapping)`: Tangerine Edition accepted SRFI 146 as
  `(scheme mapping)`.
- `(stdlib receive)`: Yellow Edition accepted SRFI 8 `receive`.
