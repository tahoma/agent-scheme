# Secrets, Local-Only Context, and Redaction

Consent Scheme treats secrets and private context as policy-bearing data. Runtime
boundaries should redact secret-prone values before they enter audit records,
session transcripts, memory records, skill/resource disclosures, exported
artifacts, or remote provider payloads.

## Defaults

Secret-prone sources include environment variables, auth-source entries, local
configuration files, provider credentials, private buffers, shell or process
output, VCS remotes and usernames where relevant, transcripts, memory, audit
logs, and skill resources. The runtime also recognizes common credential field
names such as API keys, tokens, passwords, secrets, authorization headers, and
private keys.

Redaction decisions are inspectable Scheme-readable records. A redacted
environment credential is represented without storing the original value:

```scheme
(redaction
  (kind secret)
  (source env)
  (field "OPENAI_API_KEY")
  (replacement "[redacted]")
  (policy local-only))
```

The redaction log stores these records, not the raw secret. It is available from
Scheme through `(redaction-log)` after importing `(agent redaction)`.

## Marking Local-Only Context

Use `(context-local-only! datum reason)` from `(agent redaction)` when a datum
is useful for local reasoning but must not be disclosed to remote providers or
exported artifacts:

```scheme
(import (agent redaction))

(define private-notes
  (context-local-only!
   '((buffer "notes.scm") (summary "local planning notes"))
   "private buffer"))
```

Host adapters should mark private buffers, private files, and other local-only
observations the same way, or with an equivalent Scheme-readable
`(local-only #t)` field before crossing a persistence or provider boundary.

## Provider Routing

`(safe-for-provider? datum provider)` returns false for raw secrets and
local-only context. Provider routing must redact secret-bearing payloads before
transport and must deny local-only context unless an explicit policy override
approves that disclosure.

The `(agent models)` library uses this boundary for model completion routing.
Local providers may complete through the Emacs host's OpenAI-compatible local
HTTP adapter. Remote providers are currently registrable and inspectable only;
before any future remote transport runs, the request datum is checked by
`remote-provider-routing`, redacted for audit, and rejected when it contains
local-only context without explicit approval.

Direct Scheme evaluation still returns the value being evaluated. Redaction is
applied at disclosure and persistence boundaries so the language semantics stay
unchanged while logs, transcripts, memory, skills, and provider payloads remain
safe by default.
