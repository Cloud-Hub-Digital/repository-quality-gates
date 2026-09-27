<!-- repository-standard: schema=1; standard=Repository Standards; version=1.0.0; owner=Cloud-Hub-Digital; source=local; scope=local-override; override=local-file; overrides=https://github.com/Cloud-Hub-Digital/.github/blob/main/SECURITY.md -->
# Security Policy

## Supported Versions

| Release | Security Maintenance |
| --- | --- |
| Latest Published Release | Eligible for security fixes where a safe and maintainable correction is available. |
| Earlier Releases | Not routinely supported; upgrade to the latest published release before requesting a fix. |
| Unreleased Code | Accepted for early reporting but is not a supported release. |

## Reporting A Vulnerability

Use the repository's **Security** tab to submit a private vulnerability report when that option is available. If it is unavailable, contact a repository maintainer through an existing authorized private channel and ask for a private reporting route.

Do not open a public issue, discussion, or pull request containing vulnerability details, credentials, personal data, internal infrastructure, sensitive reproduction data, or exploit material.

Include:

- the affected product and version or commit;
- the affected component and environment;
- a concise impact assessment;
- reproducible steps or a minimal proof of concept;
- relevant logs or screenshots with secrets and personal data removed; and
- any known workaround or suggested remediation.

## Response Process

Maintainers will acknowledge and triage reports as soon as reasonably practicable. They may request more evidence, attempt to reproduce the issue, assess affected versions, prepare and validate a correction, and coordinate publication of an advisory or fixed release. No response or remediation deadline is promised unless a project-specific agreement states one.

## Coordinated Disclosure

Keep the report and supporting material private until maintainers confirm that disclosure is safe. Allow reasonable time for triage, correction, validation, and affected-user communication. Maintainers will credit reporters when requested and appropriate, subject to confidentiality and safety constraints.

## Security Updates

Security corrections are published through the repository's normal release or advisory channels. Release notes will describe user action where disclosure is safe. Users should run the latest supported release and apply security updates promptly.

## Scope

Reports are in scope when they demonstrate a security impact in source, packaged artifacts, supported integrations, authentication or authorization, data handling, update or installation behavior, or documented deployment defaults maintained by this repository.

Reports are normally out of scope when they concern unsupported versions, social engineering, denial-of-service testing against systems without authorization, automated findings without a reproducible impact, third-party services outside this project's control, or configuration that contradicts the documented security requirements.

## Safe Harbour

Good-faith research should avoid privacy violations, data loss, service disruption, persistence, lateral movement, and access beyond what is necessary to demonstrate the issue. Follow applicable law and test only systems you own or are explicitly authorized to assess.

## Confidentiality

Never include credentials, tokens, private keys, personal data, internal addresses, private paths, or confidential infrastructure details in a public report or artifact. Share only the minimum necessary evidence through the approved private route.

## Project-Specific Security Guidance

### System And Scope

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

### Threat Model And Trust Boundaries

Repository contents, branch names, pull-request state, downstream adjustment
files, API responses, filesystem paths, archive contents, and tool output may be
attacker-controlled. GitHub App private keys, installation tokens, local private
publication policies, and repository write access are trusted only within their
documented scopes.

The main trust boundaries are between the central repository and each GitHub App
installation, between one installation and another, between the template and a
downstream repository, and between a repository path and the surrounding local
filesystem.

### Security Invariants

- Each GitHub App installation uses a separate short-lived token. A token must never be reused across installations.
- GitHub App private keys, installation tokens, and private publication-policy values must never enter repositories, artifacts, caches, or logs.
- Discovered owner and full repository names must be masked before downstream processing can write them to public workflow logs.
- A repository can opt out of automatic enrolment through its repository-owned local rules file.
- Any open pull request defers automatic Repository Quality Gates deployment.
- Modified managed files, unsafe path traversal, conflicting files, invalid rules, incomplete API results, or failed validation must stop automation.
- Managed paths must remain inside the target repository and must not traverse symbolic links, junctions, or other reparse points.
- Downstream changes use a short-lived versioned branch and pull request. They merge only after required checks pass, and automation removes its branch after merge, setup failure, or expiry.
- Required security and quality checks remain merge gates and must not be silently weakened by reconciliation.

### Reportable Findings And Severity Context

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

### Repository-Controlled Code Boundary

Repository Quality Gates deliberately executes checked-in project build and test
commands after checkout. A report must show that Repository Quality Gates adds a
new privilege boundary violation, injection path, secret exposure, or unintended
cross-repository effect. A downstream repository intentionally running its own
code with its documented workflow permissions is not by itself a vulnerability
in this project.

### Known External Configuration Boundaries

Repository administrators control GitHub App installation scope, repository
rules, required checks, automatic-merge availability, Actions permissions, and
the protection of App credentials. Local operators control the location and
permissions of private publication-policy files. Reports about these settings
are in scope when Repository Quality Gates documents, validates, or handles them
unsafely.

### Out Of Scope

- Feature requests, general hardening suggestions, and quality-gate failures without a security impact.
- Vulnerabilities solely in GitHub, Git, Gitleaks, a runner image, or another third-party dependency, unless Repository Quality Gates uses it in an unsafe way that creates additional impact.
- Denial of service that requires an administrator to deliberately configure an unbounded or unsupported repository.
- Social engineering, account compromise, or exposed credentials that did not originate from this repository.
- Testing against repositories or organizations without the owner's permission.

### Safe Testing And Disclosure

Use repositories and accounts you own or have explicit permission to test.
Prefer synthetic data, avoid accessing other users' information, and stop after
demonstrating the minimum impact needed for validation. Do not disrupt fleet
updates, merge unreviewed changes, publish secrets, or retain data obtained
during testing.

After a fix is available, we will coordinate a reasonable disclosure date and
publish appropriate release or advisory information without exposing secrets or
unnecessary exploitation detail.
