# dsh-sandbox-fix — Landlock backend for seek-harness

## Why
The container sets DSH_PERMISSION_MODE=workspace-write, but DSH's Linux sandbox
chain is ['bwrap', 'landlock'] and both were unusable:

- bwrap 0.12.0 IS installed, but the container's hardening (cap_drop: ALL,
  no-new-privileges, seccomp filter) blocks user-namespace creation ->
  "No permissions to create a new namespace" -> unusable.
- The Landlock launcher binary (landlock-run) was never shipped in the image:
  packages/linux-x64/bin/ does not exist (only prebuilds.json). Probe fails
  closed -> SANDBOX_UNAVAILABLE for every confined command.

## Fix
Landlock needs NO capabilities, NO namespaces, NO privileges — only
PR_SET_NO_NEW_PRIVS (already set by the container). The kernel syscalls
(444/445/446) are allowed by the container's seccomp profile (verified
empirically inside this container: create_ruleset/add_rule/restrict_self all
succeed, "fully enforced" ABI).

The launcher was compiled from the DSH checkout's own audited C source:
  /opt/dsh-src/native/landlock-run/packages/entry/src/main.c
  gcc -O2 -std=c11 -static -o bin/landlock-run main.c

Fully static (no libc dependency) — survives image base distro changes.

Rebuild with build.sh (same source location, reproducible):
  ./build.sh
  # override: SRC=/path/to/main.c ./build.sh

compose.yaml bind-mounts this bin/ dir over the missing image path:
  ./workspace/.dsh-sandbox-fix/bin:/opt/dsh-src/native/landlock-run/packages/linux-x64/bin:ro

Verified 2026-09-01 inside the running container:
  ./landlock-run --probe            -> "landlock: fully enforced", exit 0
  Full workspace-write profile (--ro / --rw /dev/null /tmp /workspace):
    granted writes to /tmp, /workspace, /dev/null: OK (exit 0)
    write to /etc: denied (correctly blocked)
  static build: 759 KB, md5 reproducible on every compilation.

Applied without restart: takes effect on next stack recreate/redeploy.
