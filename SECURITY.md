# Security model

claude-cask exists to put a sandbox around Claude Code so the AI can work on **a single project** — the directory you launched it from — without having reach over the rest of your machine. This document spells out what the sandbox does and doesn't do, and which "scary"-sounding properties are inherited from running Claude Code at all (regardless of claude-cask) versus introduced by the launcher itself.

## What the sandbox actually bounds

Inside the container, Claude can read and write:

- `$PWD` (your project), mounted at `/workspace`
- `~/.claude` and `~/.claude.json` (Claude Code's own state — same as on the host)
- A single forwarded GPG signing key (public half only) and the `gpg-agent` socket
- The container's own ephemeral filesystem

It cannot reach:

- Anything else on your host filesystem (no `~`, no `/`, no other repos)
- The macOS keychain (the OAuth token is forwarded as a file mirror, not direct keychain access)
- Other private GPG keys in your keyring (only the configured signing key's public half is imported)
- Other users on the host
- Any host process

The container is `--rm`, so the runtime state is ephemeral — cleared when you exit.

## What the sandbox does **not** bound

claude-cask is a sandbox, not a moat. There are properties of running Claude Code with `--permission-mode auto` that the sandbox can't change. The findings below were originally listed as HIGH-severity in an internal review; on closer look, they are mostly inherited from running Claude with auto-mode at all and are not new risks introduced by the container. They are documented here so you can make informed decisions about when to enable auto mode and when to use `--anthropic-only`.

### 1. OAuth token reachable inside the container in auto mode

When Claude is running with `--permission-mode auto` (opt-in via `--auto`), any tool call can read `~/.claude/.credentials.json` — the OAuth token that authenticates the session. The same is true natively: a Claude session running on your host can read the same file (it lives there too) without prompting. The container scope is in fact *narrower* than the host (smaller process population, ephemeral lifetime), not wider.

**Inherited from running Claude with auto-mode**, not introduced by claude-cask.

**Mitigations available:**
- Don't pass `--auto` (the default). Per-tool prompts apply, and a malicious-or-confused tool call asking for `Read("~/.claude/.credentials.json")` is something you'd see and could deny.
- Pass `--anthropic-only`. Even if the AI reads the token, it can't exfiltrate it: outbound network is restricted to `api.anthropic.com` at the kernel level (iptables + a tinyproxy allowlist).

### 2. Auto-mode skips per-tool-call confirmations

`--permission-mode auto` is, by design, "the AI runs tool calls without asking." If you opt in, you're trusting the AI to act inside the container's bounds without per-action confirmation. The blast radius is bounded by what the container can reach (see above), but inside that, the AI has free rein.

This is the *whole point* of auto-mode and applies identically to native Claude Code. The launcher's contribution is to make it **opt-in via `--auto`** rather than the default, so you make a conscious choice each session.

**Mitigations:**
- Default safe mode (no `--auto`) preserves Claude Code's per-tool prompts. This is the right setting when working on code/data you don't want the AI to modify without seeing each action first.
- The pre-flight summary printed before each launch shows the workspace path, signing key, network, and mode. Catches "wrong directory" mistakes before the container takes hold of anything.

### 3. The forwarded gpg-agent will sign during the session

If you've configured a host GPG signing key, claude-cask wires up a transparent socket bridge so `git commit -S` works inside the container. While the bridge is up, anything in the container that can reach the socket can request signatures from the host agent — which means in auto mode, Claude can produce signed commits during the session.

This is the same as running Claude natively with auto-mode: the host `gpg-agent` is already reachable by any process the user owns, and Claude can already invoke `git commit -S`. The bridge is a transparent forwarder; it doesn't expand what the agent's `extra-socket` already grants.

**Inherited from running Claude with auto-mode + Bash tool**, not introduced by claude-cask.

**Mitigations:**
- Don't pass `--auto`; per-tool prompts apply to the `Bash` tool that would invoke `git commit -S`.
- On the host, set `default-cache-ttl 0` and `max-cache-ttl 0` in `~/.gnupg/gpg-agent.conf` to force pinentry for every signature. With cache disabled, the AI can't sign without you interactively approving.
- Don't configure a `user.signingkey` on the host if you don't want signing available at all — claude-cask omits the GPG mounts when no signing key is set.

## What claude-cask **does** add

These are claude-cask-specific protections that don't exist when you run Claude Code natively:

- **Filesystem scope.** Native Claude with auto-mode can write anywhere your user can write (your whole `~`, your other repos, anything). claude-cask bounds it to `$PWD` + `~/.claude` + `~/.claude.json`.
- **Ephemerality.** The container is `--rm`. Whatever the AI installed, downloaded, or left around in `/tmp`, `/usr`, etc. is gone when you exit. Native Claude has no such guarantee.
- **Non-root user.** The container runs as `claude-cask` (UID 1000), not root. Defense-in-depth against accidental privilege escalation paths inside the container. There is no long-running root process inside the container after the entrypoint completes its setup.
- **Persistence vectors locked down.** `~/.claude/settings.json` and `~/.claude/plugins/` are mounted **read-only** inside the container. The AI cannot plant code that the host's own Claude would execute on subsequent sessions (no editing `enabledPlugins`/`hooks`/`permissions`, no dropping plugin files). The kernel enforces this — writes return `EROFS`.
- **Single-key GPG.** Only the configured signing key's *public* half is imported into the container's keyring. Private key material never leaves the host. The AI can request signatures (#3 above) but can't see other keys or directly access your keyring.
- **`--anthropic-only` egress restriction.** Optional kernel-enforced restriction that blocks all outbound network except `api.anthropic.com`. Mitigates exfiltration of anything reachable inside the container — including the OAuth token from #1.

## Operational guidance

- Read the pre-flight summary before pressing Enter. If the workspace path is wrong, abort.
- Default to safe mode. Pass `--auto` only when you've decided you trust this session to act without confirmation.
- Pair `--auto` with `--anthropic-only` whenever the workspace contains data you'd want to keep out of arbitrary third-party hands.
- If you use signed commits, configure `gpg-agent` cache TTL deliberately. A long cache plus auto-mode is a "Claude can sign anything for the next ten minutes" setup.

## Open issues and future work

The following items are tracked but not yet addressed:

- **Auto-resume of the gpg-agent cache.** No automation to require pinentry per signature; that's a host-side `gpg-agent.conf` decision. We may add a docs note pointing at the setting; we will not modify host config from the launcher.
- ~~**`~/.claude` is read/write inside the container.**~~ ~~The AI can write plugins, hooks, or settings that affect host Claude on subsequent runs.~~ **Resolved:** `~/.claude/settings.json` and `~/.claude/plugins/` are now stacked read-only inside the container. The rest of `~/.claude` remains RW so Claude Code can still record session state. If new persistence vectors are added in future Claude Code (e.g., a top-level `~/.claude/hooks/`), this list will need updating.
- **No image signing or pinning.** The image is built locally from the Dockerfile in this repo; the base image (`node:24-slim`) is pulled by tag, not by digest. Acceptable for a personal dev tool; would need addressing for distribution.
- **Limited audit trail.** Tool calls inside the container aren't logged outside Claude Code's own session storage. If you want a record of what the AI did, that's currently in `~/.claude/projects/-workspace/<session-id>.jsonl`.

We will revisit these as use cases warrant. Notes will be added inline in this file when each is addressed or when a deliberate decision is made to leave it as-is.
