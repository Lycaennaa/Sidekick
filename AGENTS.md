Platform boundaries:

Every default production adapter must have at least one command-level success test using real platform object and default dependencies. Fake-only success coverage is prohibited.
A production adapter must not return fixed failure, unavailable result, or no-op while its feature remains enabled in UI/composition.
Test doubles may inject races and failures, but must not contain only functional implementation of production behavior.

Async state mutation:

After any await preceding externally shared-state mutation, revalidate generation, ownership, cancellation, and expected contents after final suspension. Perform mutation without another suspension.
Every optimistic mutation needs regression test that changes ownership/state during awaited operation and proves newer data remains untouched.
Repeated preflight checks do not replace one final post-await validation.

Native and non-preemptible work:

Assume framework/provider calls are non-preemptible unless API documentation proves cancellation.
Distinguish accepted-output limits and result deadlines from hard memory/runtime bounds. Names and docs must not imply stronger guarantees.
Hard resource bounds require process isolation or another genuinely preemptible boundary.
@unchecked Sendable and nonisolated(unsafe) require local invariant explaining ownership, immutability, executor use, and lifetime, plus focused concurrency coverage.

Materialization and analysis:

Materialize external payload data at most once per logical operation. Derive validation, fingerprinting, classification, and presentation from captured immutable result.
If repeated materialization is required for revalidation, document invariant it protects and test provider invocation counts.

Architecture:

Maintain one canonical production execution path. Do not add parallel classify/analyze, real/fake, or test-only functional modes.
Production files over roughly 500 lines require explicit structural justification. Otherwise split by ownership before adding behavior.
Keep pure presentation separate from stateful orchestration and platform I/O.
A remediation must not merely move complexity: recheck file sizes, duplicate branches, default production callers, and integration tests before declaring finding closed.

Human-facing build and check instructions live in [DEVELOPMENT.md](DEVELOPMENT.md). Contribution and pull-request workflow lives in [CONTRIBUTING.md](CONTRIBUTING.md).