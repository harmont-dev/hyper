# Security

## Reporting a vulnerability

Report vulnerabilities privately, through [GitHub's advisory
form](https://github.com/harmont-dev/hyper/security/advisories/new) or by email
to <marko@harmont.dev>. Do not open a public issue, pull request or discussion.

Include what you can of:

- the Hyper version or commit, and the `hyper-suidhelper` version;
- the host kernel and Firecracker versions;
- the relevant parts of `/etc/hyper/config.toml` (e.g. whether gRPC is enabled,
  and how it is exposed);
- steps to reproduce, ideally a proof of concept;
- the impact, and what an attacker needs in order to exploit it.

Reports found with automated tools, LLMs included, are welcome. Name the tool,
and check the findings yourself before sending them.

## Disclosure

When disclosing a vulnerability, please keep it private. Until a fix is
announced, I would prefer if we didn't expose a vulnerability to the public.

### Credit

Reporters are credited in the advisory unless they ask not to be. Hyper has no
bug bounty.

## What counts as a vulnerability

Hyper assumes that an operator is not malicious. I assume that you have
configured your BEAM cluster, postgres, any client to be safe. Hyper does
**not** trust anything running insde a VM. I consider vulnerabilities when an
untrusted party gets access only the operator should have. Some examples are:

- **guest to host operations**: anything in a VM affecting the host or another
  VM is considered a security vulnerability.
- **local user to root**: an unprivileged user making `hyper-suidhelper`
  (`native/suidhelper/`) act on protected paths, within Hyper or outside, is
  considered a security vulnerability.
- **API client beyond the API**: API escapes, eg. you getting `root` access
  through the API is considered insecure.

An example of a **vulnerability** is:

> A VM successfully impersonated another VM, receiving its network traffic.

An example of a **non-vulnerability** is:

> gRPC access is unauthenticated.

The latter is not considered a vulnerability, since I expect *you* and your
cluster to control access to the gRPC cluster.

## What to expect

I aim to provide a response as soon as possible. I have a day-job that does not
involve Hyper and, consequently, maybe be unable to immediately respond. I'll
try to acknowledge a report within a couple days, and if you do not hear from
me, open a public CVE.

## Supported versions

Only the [latest release](https://github.com/harmont-dev/hyper/releases/latest)
and `main` receive security fixes.

