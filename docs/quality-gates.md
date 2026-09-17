# Quality Gates

This reference describes what each module deploys, exactly when it is selected, and what its GitHub Actions workflow enforces.

## Selection Input

The deployment script asks Git for tracked files and untracked files that are not excluded by Git ignore rules. Selection therefore reflects source that could be committed, rather than every file physically present on disk.

The detector excludes files under these generated or dependency directories:

- `.git`
- `node_modules`
- `vendor`
- `bin`
- `obj`
- `.tools`

Previously managed template payload files are also removed from later detection input. This prevents the secret-scanning module's PowerShell helpers from causing a documentation-only repository to acquire the PowerShell module on its second run.

Filename and extension matching is case-insensitive. A match anywhere in the repository is sufficient. Module selection is additive: a mixed repository receives every applicable module.

## Workflow Defaults

All deployed workflows:

- grant `contents: read` only;
- use a commit-pinned `actions/checkout` reference;
- set `persist-credentials: false`;
- run on pushes, pull requests, and manual `workflow_dispatch` requests;
- use finite job timeouts.

Secret Scanning also runs every Monday at `07:23` UTC. The workflow uses `fetch-depth: 0` because a full-history scan requires complete history.

## Module Selection And Checks

### Secret Scanning

**Selection rule:** Always selected for every Git repository.

**Deployed controls:**

- repository-local pre-commit and pre-push hooks;
- checksum-verified Gitleaks installer for 64-bit Windows;
- pinned Gitleaks version and separate archive/executable SHA-256 checks;
- public project configuration extending portable rules;
- staged, outgoing-push, full-history, and working-tree scan modes;
- redacted scanner output;
- synthetic positive and negative policy tests;
- GitHub Actions full-history scan.

The portable policy supplements Gitleaks' built-in rules with checks for:

- credential-bearing connection strings;
- credentialed database or messaging URIs;
- Basic, Bearer, or Token authorization headers;
- OAuth/application client secrets;
- refresh tokens;
- session tokens, keys, secrets, IDs, and cookies;
- high-risk private-key and Java keystore filenames.

The synthetic policy suite verifies nine cases, including documentation placeholders and public certificate examples that must remain safe.

#### Exact Public Secret Rules

The public policy is defined in `security/gitleaks-portable.toml`. Its `[extend] useDefault = true` setting enables the complete built-in Gitleaks rule catalog first. The seven rules below add credential forms and risky filenames that the built-in catalog does not detect reliably. Matching is case-insensitive unless the expression says otherwise.

##### `portable-connection-string-password`

- **Purpose:** Detects a `password=` or `pwd=` field at the start of a line or in a semicolon-delimited connection string, while avoiding ordinary program assignments and comparisons.
- **Exact Expression:** `(?im)(?:^|;[ \t]*)(?:password|pwd)[ \t]*=[ \t]*["']?([^;"'\s\\]{8,})`
- **Captured Secret:** The assigned value, with at least 8 characters.
- **Entropy Threshold:** 2.5.
- **Keywords:** `password`, `pwd`.
- **Allowed Values:** The shared explicit placeholders described below, an address at the reserved `example.invalid` domain, or an uppercase bracketed redaction marker such as `[REDACTED_VALUE]`.

##### `portable-credentialed-uri`

- **Purpose:** Detects a password embedded in a database or messaging URI.
- **Exact Expression:** `(?i)\b(?:postgres(?:ql)?|mysql|mariadb|mongodb(?:\+srv)?|redis|rediss|amqp|amqps|mssql)://[^:/@\s]{1,64}:([^@/\s"']{8,})@`
- **Schemes:** `postgres`, `postgresql`, `mysql`, `mariadb`, `mongodb`, `mongodb+srv`, `redis`, `rediss`, `amqp`, `amqps`, and `mssql`.
- **Captured Secret:** The password between the first username separator and `@`, with at least 8 characters.
- **Entropy Threshold:** 2.5.
- **Allowed Values:** The shared explicit placeholders described below.

##### `portable-authorization-header`

- **Purpose:** Detects Basic, Bearer, or Token credentials assigned to an Authorization header.
- **Exact Expression:** `(?i)\bauthorization[ \t]*[:=][ \t]*["']?(?:basic|bearer|token)[ \t]+([A-Z0-9._~+/=-]{12,})`
- **Captured Secret:** The credential after the authorization scheme, with at least 12 characters.
- **Entropy Threshold:** 3.0.
- **Keyword:** `authorization`.
- **Allowed Values:** The shared explicit placeholders described below.

##### `portable-client-secret`

- **Purpose:** Detects generic OAuth or application client-secret assignments.
- **Exact Expression:** `(?i)\b(?:oauth[_-]?)?client[_-]?secret\b[ \t]*[:=][ \t]*["']?([A-Z0-9._~+/=-]{16,})`
- **Accepted Names:** `client_secret`, `client-secret`, `clientsecret`, and the same names with an `oauth` prefix.
- **Captured Secret:** The assigned value, with at least 16 characters.
- **Entropy Threshold:** 3.0.
- **Allowed Values:** The shared explicit placeholders described below.

##### `portable-refresh-token`

- **Purpose:** Detects generic OAuth refresh-token assignments.
- **Exact Expression:** `(?i)\brefresh[_-]?token\b[ \t]*[:=][ \t]*["']?([A-Z0-9._~+/=-]{16,})`
- **Accepted Names:** `refresh_token`, `refresh-token`, and `refreshtoken`.
- **Captured Secret:** The assigned value, with at least 16 characters.
- **Entropy Threshold:** 3.0.
- **Allowed Values:** The shared explicit placeholders described below.

##### `portable-session-secret`

- **Purpose:** Detects generic session tokens, secrets, keys, IDs, and cookie values.
- **Exact Expression:** `(?i)\b(?:session[_-]?(?:token|secret|key|id)|sessionid|connect\.sid)\b[ \t]*[:=][ \t]*["']?([A-Z0-9._~+/=-]{16,})`
- **Accepted Names:** `session_token`, `session-secret`, `sessionkey`, `session-id`, `sessionid`, `connect.sid`, and equivalent underscore, hyphen, or unseparated forms.
- **Captured Secret:** The assigned value, with at least 16 characters.
- **Entropy Threshold:** 3.0.
- **Allowed Values:** The shared explicit placeholders described below.

##### `portable-sensitive-key-file`

- **Purpose:** Rejects high-risk private-key and Java keystore filenames even when their contents do not match a content rule.
- **Exact Path Expression:** `(?i)(?:^|/)(?:id_(?:rsa|dsa|ecdsa|ed25519)|(?:private|signing|tls|ssl|server|client)(?:[-_.](?:private|signing|auth))?\.(?:key|pem)|[^/]+\.(?:jks|keystore))$`
- **Covered Files:** OpenSSH private-key names (`id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`); private, signing, TLS, SSL, server, and client `.key` or `.pem` names; and every `.jks` or `.keystore` file.
- **Intentional Non-Match:** Public certificate files such as `.crt` are not rejected by this filename rule. Their contents remain subject to the built-in Gitleaks catalog.

##### Shared Documentation Placeholders

The credential rules allow only these explicit synthetic value shapes:

- angle-bracket placeholders containing 1 to 64 non-line-break characters, such as `<TOKEN>`;
- environment placeholders such as `${API_TOKEN}`;
- template placeholders such as `{{ API_TOKEN }}`;
- uppercase values beginning `YOUR_` or `YOUR-`;
- `REDACTED`;
- `EXAMPLE`, optionally followed by `ONLY`, `VALUE`, `TOKEN`, `SECRET`, or `PASSWORD` using `_` or `-`.

These exceptions apply only to the captured value. They do not allowlist a whole file or path. A realistic secret that merely appears in documentation is still a finding.

##### Project Exceptions

The deployed `.gitleaks.toml` extends the portable policy. Project-specific exceptions may be added only after review and must bind one known synthetic value to one exact file. It must never allowlist a real credential, a broad directory, a file type, or a private identifier category.

##### Private Publication Rules

Personal names, postal addresses, email addresses, telephone numbers, dates of birth, private domains, internal hostnames, local drive paths, UNC paths, and other private identifiers belong in the external publication-safety policy. Their real values are deliberately absent from this repository and from GitHub Actions. Local staged, push, history, and working-tree scans run that protected policy as a second pass when `publicationSafety.privateConfig` is configured in repository-local Git settings.

**Local policy layers:** Local scans always use the portable/project policy. When configured, they run a second pass using the external private publication-safety policy. GitHub Actions intentionally receives only public portable rules.

**Workflow:** `Secret Scanning` on `windows-2025`, timeout 10 minutes. It installs the verified scanner, scans complete history, and runs the synthetic detection-policy suite.

### PowerShell

**Selection rule:** At least one `.ps1`, `.psm1`, or `.psd1` file exists.

**Workflow:** `PowerShell Quality` on `windows-2025`, timeout 10 minutes.

The workflow recursively parses each applicable file with the PowerShell language parser and fails if any parse error is returned. It excludes `.git`, `node_modules`, `vendor`, `bin`, and `obj` directories.

The deployment script also parses existing PowerShell files before applying any file changes. A parse failure stops deployment before mutation.

### .NET

**Selection rule:** At least one `.sln`, `.slnx`, `.csproj`, `.fsproj`, or `.vbproj` file exists.

**Workflow:** `.NET Quality` on `windows-2025`, timeout 30 minutes.

The workflow selects all solution files first. When no solution is present, it selects project files. For each selected target it runs:

1. `dotnet restore`
2. `dotnet build --configuration Release --no-restore`
3. `dotnet test --configuration Release --no-build --no-restore`

`bin` and `obj` content is excluded from target discovery. Tests must remain headless; genuine desktop UI testing belongs in a separate isolated workflow or virtual machine.

### Node

**Selection rule:** A file named `package.json` exists, or at least one `.js`, `.mjs`, or `.cjs` file exists.

**Workflow:** `Node Quality` on `ubuntu-latest`, timeout 20 minutes.

The workflow always runs `node --check` against every tracked JavaScript file.

When `package.json` exists, the workflow requires `package-lock.json` or `npm-shrinkwrap.json` and runs:

1. `npm ci`
2. `npm run lint --if-present`
3. `npm test --if-present`
4. `npm run build --if-present`

When `package.json` is absent and `tests/test.js` exists, the workflow runs `node tests/test.js` as the repository's conventional dependency-free test suite. A dependency-free repository without that exact test path receives syntax validation only.

### Python

**Selection rule:** At least one `.py` file exists, or one of these project markers exists:

- `pyproject.toml`
- `setup.py`
- `setup.cfg`
- `requirements.txt`
- `requirements-dev.txt`
- `Pipfile`

**Workflow:** `Python Quality` on `ubuntu-latest`, timeout 20 minutes.

The workflow:

- installs `requirements.txt` and `requirements-dev.txt` when present;
- installs the project in editable mode when `pyproject.toml` or `setup.py` exists;
- runs `python -m compileall -q .`;
- runs tests only when a `tests` directory exists;
- uses pytest when it is importable, otherwise uses `unittest` discovery for `test_*.py`.

### PHP

**Selection rule:** A file named `composer.json` or at least one `.php` file exists.

**Workflow:** `PHP Quality` on `ubuntu-latest`, timeout 20 minutes.

The workflow:

- runs `php -l` on every tracked PHP file;
- runs `composer validate --strict` and `composer install --no-interaction --prefer-dist` when `composer.json` exists;
- runs `composer test --if-present` when `composer.json` exists.

### Shell

**Selection rule:** At least one `.sh` or `.bash` file exists.

**Workflow:** `Shell Quality` on `ubuntu-latest`, timeout 10 minutes.

The workflow runs `bash -n` against every tracked `.sh` and `.bash` file. This is a syntax gate; ShellCheck linting is not currently included.

### PlatformIO

**Selection rule:** A file named `platformio.ini` exists.

**Workflow:** `PlatformIO Quality` on `ubuntu-latest`, timeout 30 minutes.

The workflow installs `platformio==6.1.18` and runs `pio run`. It validates configured firmware environments but does not perform hardware-in-the-loop or physical-device testing.

### Documentation

**Selection rule:** At least one `.md` or `.markdown` file exists.

**Workflow:** `Documentation Quality` on `ubuntu-latest`, timeout 10 minutes.

The workflow fails when Markdown files contain trailing spaces or tabs. It excludes `.git`, `node_modules`, and `vendor`. It does not currently run a full Markdown style linter, link checker, spelling checker, or rendered-document comparison.

## Selection Examples

| Repository Contents | Selected Modules |
|---|---|
| `README.md` only | Secret Scanning, Documentation |
| `tool.ps1` and `README.md` | Secret Scanning, PowerShell, Documentation |
| `Product.slnx`, C# projects, and Markdown | Secret Scanning, .NET, Documentation |
| `package.json` and JavaScript source | Secret Scanning, Node |
| Dependency-free `.js` source and `tests/test.js` | Secret Scanning, Node |
| `pyproject.toml`, Python source, and Markdown | Secret Scanning, Python, Documentation |
| `composer.json`, PHP source, shell helpers, and Markdown | Secret Scanning, PHP, Shell, Documentation |
| `platformio.ini`, Python helper scripts, and Markdown | Secret Scanning, PlatformIO, Python, Documentation |

## Existing Workflow Detection

The catalog defines text markers for each module, such as `dotnet test`, `npm ci`, `pytest`, or `pio run`. The deployment script inspects existing workflow files outside the planned managed paths. A matching marker is reported as a potential overlap.

An overlap is evidence for review, not proof that two workflows are equivalent. Apply stops until one of these decisions is made:

- preserve the existing reviewed implementation with `-PreserveExistingModule <module>`;
- keep both checks with `-AcknowledgeOverlap` after confirming duplication is intentional;
- manually reconcile or remove the existing workflow, then preview again.

Preservation is accepted only when the module is applicable and matching workflow evidence exists. Preserved modules are recorded in `.repository-quality-gates.json` but their template payload files are not deployed.

## Current Boundaries

The template chooses modules using repository contents. It does not infer framework-specific lint commands, test projects, databases, browsers, hardware targets, or deployment environments beyond the explicit rules above. Product-specific checks remain the responsibility of the target repository and should coexist with these baseline gates after overlap review.

Build and release automation is assessed separately in [Automation Costs And Release Strategy](automation-costs-and-releases.md). No release publishing workflow is deployed by the current template.
