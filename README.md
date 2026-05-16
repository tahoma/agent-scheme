# Agent Scheme

Agent Scheme is an R7RS-small guest language and agentic REPL design whose first host is Emacs.

The project goal is to give agents and users a Lisp-native scripting environment with:

- R7RS-small compliance from the start, including macros and `define-library`
- Scheme-readable datums for memory, plans, transcripts, skills, rules, and audit records
- explicit host capabilities instead of unrestricted host access
- Emacs as the first host adapter, not the semantic center
- portable libraries and self-scripting workflows that can eventually run in other UI environments

## Current Status

This repository is being split out of `tahoma/emacs-config` while the design is still issue-driven. The implementation roadmap lives in GitHub issues, starting with the architecture and dependency-graph issues.

## Design Rules

- Think in Lisp/Scheme first for internal APIs and examples.
- Keep canonical runtime state inspectable as Scheme data.
- Use JSON, HTTP, Markdown, and other encodings at protocol or document boundaries, not as the internal model.
- Keep host adapters severable. Emacs is the first body; Agent Scheme should have a portable core.
- Prefer conservative, audited capabilities over broad host access.

## Repository Shape

This seed is intentionally small. Initial implementation modules and documentation should follow the GitHub roadmap as issues are transferred into this repository.
