<!-- repository-standard: schema=1; standard=Repository Standards; version=1.1.0; scope=local-required; source=local -->
# Repository Review Instructions

This file supplies public-safe instructions for automated & human code review. It applies to the entire repository unless a deeper `AGENTS.md` adds stricter rules for a specific subtree.

## Code Review Rules

- Prioritize correctness, security, privacy, data integrity, reliability, & backward compatibility before style or preference.
- Verify changed behavior against documented requirements, public interfaces, configuration contracts, & supported platforms.
- Require meaningful tests for changed deterministic behavior & regression tests for corrected defects. Flag missing coverage when it could allow a material regression.
- Treat authentication, authorization, untrusted input, command execution, filesystem access, network access, deserialization, secrets, & update paths as high-risk review areas.
- Check failure paths, timeouts, retries, cancellation, cleanup, rollback, & partial-state behavior. Errors must be actionable without exposing sensitive data.
- Identify breaking API, configuration, storage, schema, workflow, packaging, or deployment changes & require migration or compatibility handling where applicable.
- Review dependency, lockfile, workflow, permission, & build-tool changes for necessity, pinning, provenance, scope, & supply-chain risk.
- Check concurrency, resource ownership, performance, & unbounded work when the changed path can affect responsiveness, stability, cost, or capacity.
- Reject committed secrets, credentials, personal data, private infrastructure details, private project records, internal paths, or confidential operational context.
- Require user-visible behavior, installation, configuration, compatibility, security, or release-impact changes to update the appropriate public documentation & changelog.
- Report only actionable findings introduced or exposed by the change. Cite the affected file & line, explain the concrete impact & triggering scenario, & suggest the smallest safe correction.
- Do not report style-only preferences unless they violate an adopted repository rule, obscure correctness, or create a measurable maintenance risk. State clearly when no actionable findings are found.

## Repository-Specific Review Rules

- Treat module manifests, payloads, deployment state, updater behavior, & validation fixtures as one compatibility contract; require synchronized changes & drift tests.
- Require validators to fail closed on unresolved or unsafe state while retaining deterministic, actionable diagnostics & idempotent reruns.
- Review workflow permissions, event trust boundaries, self-hosted runner routing, generated files, & update pull requests for supply-chain & privilege-escalation risk.
- Ensure documentation-only changes cannot trigger a stable product release & that release automation preserves exact-version, tag, artifact, & changelog consistency.
- Require PowerShell changes to cover Windows PowerShell & supported PowerShell editions where the maintained contract applies.

## Review Scope

- Apply these rules to source, tests, documentation, workflows, build & packaging definitions, generated artifacts, & configuration changed by the pull request.
- Treat generated, vendored, minified, or third-party files as review evidence rather than hand-edited source unless the repository explicitly maintains them.
- A deeper `AGENTS.md` may add stricter directory-specific rules but must not weaken this baseline.
