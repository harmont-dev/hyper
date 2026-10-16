# Security

Report vulnerabilities privately, through [GitHub's advisory
form](https://github.com/harmont-dev/hyper/security/advisories/new) or by email
to <marko@harmont.dev>. Do not open a public issue.

In scope is Hyper's own code: the setuid helper (`native/suidhelper/`), the
jail, network and device-mapper plumbing it drives, the guest agent, and the
gRPC API.

Bugs in the host kernel, KVM or Firecracker belong upstream. We track their
impact on Hyper in public issues.
