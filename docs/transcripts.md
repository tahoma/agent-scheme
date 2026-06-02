# Replayable Transcripts

Consent Scheme transcripts record session and runtime activity as
Scheme-readable data. They are not terminal logs: raw transcript datums remain
the canonical state, and human-readable summaries are views over those datums.

## Event Shape

Transcript entries use `transcript-event` records:

```scheme
(transcript-event
  (id e-42)
  (session project-main)
  (kind eval-end)
  (form "(project-search \"define-agent-skill\" '())")
  (result "...")
  (yields ((audit-entry ...)))
  (policy ((category pure-r7rs) (decision allowed)))
  (time "2026-05-26T00:00:00-0700")
  (replay
    (mode deterministic-pure)
    (effect pure-evaluation)
    (reason "pure Scheme evaluation can be replayed")))
```

The public `(agent transcript)` library provides constructors, field lookup,
replay classification, fixture generation, summary views, rotation, and export
helpers. Emacs sessions append `eval-start`, `eval-end`, and `eval-error`
events to session transcripts; `(agent io)` events appear inside the `yields`
field of the completed evaluation event.

## Replay Modes

- `audit-only`: retain the event for inspection without replay.
- `deterministic-pure`: pure Scheme evaluation with source and result can be
  re-run when budgets and imports permit it.
- `fixture-generation`: error-producing pure evaluations can seed regression
  fixtures.
- `recorded-observation`: host effects, approvals, capability calls, skill
  access, memory writes, and model routing are replayed only as recorded
  observations.

Host effects must not be silently executed during replay. A transcript can show
that a capability returned a recorded value, but the replay consumer must treat
that value as an observation unless policy grants a fresh effect.

## Retention and Export

The default retention datum is:

```scheme
(transcript-retention
  (retain-events 200)
  (rotate-events 200)
  (summarize-after 100)
  (export-formats (scheme-datum text-summary fixture-cases)))
```

Hosts may rotate in-memory transcripts to the newest events, summarize older
events into memory, or export raw datums, text summaries, or generated fixture
cases. Redaction runs before persistence and export, so source strings,
results, yields, audit records, and host observations do not retain literal
secret values.

## Debugging Helpers

When an agent-authored helper behaves unexpectedly, inspect its session
transcript first:

1. Use the raw `transcript-event` datums to confirm the exact source, imports,
   yields, policy decision, and result.
2. Generate fixture cases from deterministic events with
   `transcript-event->fixture-case`.
3. Store useful conclusions in `(agent memory)` or attach them to `(agent
   plan)` records as ordinary Scheme data.
4. Exercise the helper through `(agent test)` using the generated fixture
   source and expected value.

The audit buffer remains the authority trail for policy and capability events;
the transcript connects that trail back to the session source and result that
caused it.
