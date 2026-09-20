# Security Policy

## Supported Versions

Security fixes are applied to the latest stable release and the current `main`
branch. Older releases may be used as investigation references, but they do not
receive routine security fixes.

## Reporting A Vulnerability

Report suspected vulnerabilities through
[GitHub Private Vulnerability Reporting](https://github.com/Cloud-Hub-Digital/repository-quality-gates/security/advisories/new).
Do not open a public issue for an unpatched vulnerability or include secrets,
private identifiers, internal infrastructure details, or unnecessary exploit
material in a report.

We aim to acknowledge a report within three working days and provide an initial
assessment within seven working days. These are response targets rather than a
guarantee. We will coordinate validation, remediation, credit, and disclosure
with the reporter where appropriate.

## System And Scope

Repository Quality Gates is a PowerShell deployment and update system that
copies managed validation files into Git repositories and can prepare temporary
GitHub pull requests through a scoped GitHub App. Security review covers:

- the deployment, update, reconciliation, enrolment, and fleet scripts;
- generated Git hooks and GitHub Actions workflows;
- secret-scanning policies and scanner installation integrity;
- managed-file state, conflict detection, and pruning;
- GitHub App authentication, installation isolation, permissions, and token handling;
- repository discovery, temporary branches, pull requests, automatic merge, and cleanup; and
- documentation or defaults that could cause an unsafe deployment.

## Threat Model And Trust Boundaries

Repository contents, branch names, pull-request state, downstream adjustment
files, API responses, filesystem paths, archive contents, and tool output may be
attacker-controlled. GitHub App private keys, installation tokens, local private
publication policies, and repository write access are trusted only within their
documented scopes.

The main trust boundaries are between the central repository and each GitHub App
installation, between one installation and another, between the template and a
downstream repository, and between a repository path and the surrounding local
filesystem.

## Security Invariants

- Each GitHub App installation uses a separate short-lived token. A token must never be reused across installations.
- GitHub App private keys, installation tokens, and private publication-policy values must never enter repositories, artifacts, caches, or logs.
- Discovered owner and full repository names must be masked before downstream processing can write them to public workflow logs.
- A repository can opt out of automatic enrolment through its repository-owned local rules file.
- Any open pull request defers automatic Repository Quality Gates deployment.
- Modified managed files, unsafe path traversal, conflicting files, invalid rules, incomplete API results, or failed validation must stop automation.
- Managed paths must remain inside the target repository and must not traverse symbolic links, junctions, or other reparse points.
- Downstream changes use a short-lived versioned branch and pull request. They merge only after required checks pass, and automation removes its branch after merge, setup failure, or expiry.
- Required security and quality checks remain merge gates and must not be silently weakened by reconciliation.

## Reportable Findings And Severity Context

Report issues that can realistically cause:

- credential, token, private-key, private-policy, or protected-identifier exposure;
- access to repositories outside the intended GitHub App installation;
- unauthorized repository enrolment, mutation, push, merge, or branch cleanup;
- command, path, workflow, configuration, archive, or log injection;
- filesystem escape through traversal, links, junctions, or reparse points;
- bypass of secret scanning, integrity checks, managed-file conflicts, required checks, or fail-closed behavior;
- deletion or replacement of repository-controlled content without the required provenance and recovery checks; or
- disclosure of owner or repository identities in public automation logs.

Severity depends on reachability, the permissions available to the affected
workflow or token, the number of installations or repositories exposed, and
whether the failure permits disclosure, arbitrary code execution, or an
unauthorized persistent change.

## Repository-Controlled Code Boundary

Repository Quality Gates deliberately executes checked-in project build and test
commands after checkout. A report must show that Repository Quality Gates adds a
new privilege boundary violation, injection path, secret exposure, or unintended
cross-repository effect. A downstream repository intentionally running its own
code with its documented workflow permissions is not by itself a vulnerability
in this project.

## Known External Configuration Boundaries

Repository administrators control GitHub App installation scope, repository
rules, required checks, automatic-merge availability, Actions permissions, and
the protection of App credentials. Local operators control the location and
permissions of private publication-policy files. Reports about these settings
are in scope when Repository Quality Gates documents, validates, or handles them
unsafely.

## Out Of Scope

- Feature requests, general hardening suggestions, and quality-gate failures without a security impact.
- Vulnerabilities solely in GitHub, Git, Gitleaks, a runner image, or another third-party dependency, unless Repository Quality Gates uses it in an unsafe way that creates additional impact.
- Denial of service that requires an administrator to deliberately configure an unbounded or unsupported repository.
- Social engineering, account compromise, or exposed credentials that did not originate from this repository.
- Testing against repositories or organizations without the owner's permission.

## Safe Testing And Disclosure

Use repositories and accounts you own or have explicit permission to test.
Prefer synthetic data, avoid accessing other users' information, and stop after
demonstrating the minimum impact needed for validation. Do not disrupt fleet
updates, merge unreviewed changes, publish secrets, or retain data obtained
during testing.

After a fix is available, we will coordinate a reasonable disclosure date and
publish appropriate release or advisory information without exposing secrets or
unnecessary exploitation detail.
