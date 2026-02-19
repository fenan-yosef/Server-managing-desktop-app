<!--
Sync Impact Report

- Version change: [template] -> 1.0.0
- Modified principles:
	- [PRINCIPLE_1_NAME] -> "CLI & JSON-Line Control (NON-NEGOTIABLE)"
	- [PRINCIPLE_2_NAME] -> "Separation: Headless Backend & UI"
	- [PRINCIPLE_3_NAME] -> "Safe Concurrency & Resource Limits"
	- [PRINCIPLE_4_NAME] -> "Security & Credentials Handling"
	- [PRINCIPLE_5_NAME] -> "Observability, Testability & Reproducibility"
- Added sections: "Operational Constraints" and "Development Workflow"
- Removed sections: none
- Templates requiring updates:
	- .specify/templates/plan-template.md -> ✅ scanned (no automated edits; manual review recommended)
	- .specify/templates/spec-template.md -> ✅ scanned (no automated edits; manual review recommended)
	- .specify/templates/tasks-template.md -> ✅ scanned (no automated edits; manual review recommended)
	- .specify/templates/constitution-template.md -> ✅ scanned
	- .specify/templates/commands/*.md -> ⚠ pending (directory not present)
- Follow-up TODOs:
	- TODO(RATIFICATION_DATE): confirm original adoption/rationalization date
	- Manual review: update template "Constitution Check" text to match new principle names and gates
-->

# Server Managing Desktop App Constitution

## Core Principles

### CLI & JSON-Line Control (NON-NEGOTIABLE)
All headless backend components MUST expose a clear text protocol for automation and debugging.
Specifically, implementations MUST support both a text stdin/stdout mode for simple CLI usage
and a structured JSON-over-socket mode for programmatic frontends. Commands MUST be idempotent
where feasible, accept structured parameters, and return machine-friendly results or errors.

Rationale: `backend/backend_cli.py` exposes both stdin/stdout and a JSON socket interface; this
duality is essential for debugging, scripting, and the Flutter frontend integration.

### Separation: Headless Backend & UI
The backend MUST remain headless and provide a programmatic API boundary that the frontend
consumes. No UI assumptions or UI-only side-effects are allowed in backend modules; all
user-interaction responsibilities belong to the frontend layer.

Rationale: The repository separates `backend/` and `flutter_frontend/`; keeping a strict
API boundary preserves testability and enables alternative frontends.

### Safe Concurrency & Resource Limits
Concurrency controls are REQUIRED. Implementations MUST include global and per-target
concurrency limits, timeouts, and well-defined backoff/retry behavior. Long-running
operations MUST surface progress and be cancellable where practical.

Rationale: `backend/backend_cli.py` implements semaphores and per-host limits; these are
essential for preventing resource exhaustion and accidental denial-of-service against targets.

### Security & Credentials Handling
Credentials and secrets MUST be handled with least-privilege principles: avoid persistent
plaintext storage, do not log secrets, and treat authentication failures as security events.
Persistent connections or managers that have authentication failures MUST be discarded.

Rationale: The backend stores persistent SSH managers and already discards managers on
auth failure; this behavior is elevated to a constitution principle to ensure consistent
handling across the codebase.

### Observability, Testability & Reproducibility
All long-running operations and inter-process messages MUST emit structured, machine-parseable
events (JSON) and human-friendly logs. Unit tests and integration tests MUST exist for
contracts between frontend and backend; integration tests that require network interaction
SHOULD use mocks or recorded fixtures to keep CI deterministic.

Rationale: The project uses a `JobStore` abstraction and emits job states; these must be
standardized for monitoring and reliable CI verification.

## Operational Constraints

- Cross-platform: implementations SHOULD work on Windows and Linux where feasible (the
	workspace contains Windows-specific Flutter builds and Python backend code).
- Path handling MUST be explicit about encodings and path separators.
- IPC and exported artifacts MUST be JSON-serializable where they are part of contracts.
- External dependencies MUST be minimized and justified in PRs.

## Development Workflow

- Tests: Every production change MUST include unit tests for the changed module and
	integration or contract tests for API boundaries where appropriate.
- Code review: All changes MUST be delivered via PR and receive at least one approving
	review from a maintainer familiar with the affected area.
- Release/versioning: Project releases and migration of data formats MUST be documented
	and include a migration plan where backward-incompatible storage changes are made.

## Governance

The Constitution is the project's canonical guidance. Amendments follow this process:

1. Propose change as a draft PR referencing this file and the rationale.
2. Include an impact assessment (templates updated, tests added, migration plan if needed).
3. Obtain two approvals from active maintainers and at least one integration test proving
	 the change is compatible with the stated contracts (or a documented migration plan).
4. On merge, update the `Last Amended` date and the `Version` according to semantic rules
	 below.

Versioning policy for the Constitution:

- MAJOR: Backward-incompatible governance or principle removals/renames.
- MINOR: New principle or material expansion of guidance.
- PATCH: Clarifications, wording, typos, or non-semantic refinements.

All PRs that touch runtime behavior MUST reference the relevant principle(s) and explain
how the change preserves or intentionally evolves the stated constraints.

Templates and automation hooks that reference constitution checks (for example the
`Constitution Check` gate in `.specify/templates/plan-template.md`) MUST be updated to
match principle names when this document changes.

**Version**: 1.0.0 | **Ratified**: TODO(RATIFICATION_DATE) | **Last Amended**: 2026-02-19
