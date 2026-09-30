# Running Claude Code with OpenRouter in an OpenShell sandbox (macOS + Docker Desktop)

Setup: OpenShell 0.1.2 gateway installed with Homebrew (`brew services`), Docker Desktop 29.5.3 as the compute driver, and a custom `claude-agent` image built from `Dockerfile.claude`.

---

## Issue 1: Sandbox fails with `ControlSupervisorStartFailed` / "failed to connect to OpenShell server"

**Symptom**

```
Startup configuration fetch failed after 5 attempts: failed to connect to OpenShell server
```

**What we checked**

| Check | Result |
|---|---|
| `openshell status` | Gateway connected, mTLS OK |
| Gateway listener (`lsof -iTCP:17670`) | Bound to `127.0.0.1:17670` on the Mac |
| Gateway logs (`/opt/homebrew/var/log/openshell/openshell-gateway.out.log`) | No incoming connection from the supervisor, so this was not a TLS or auth error |
| Bridge container → `host.docker.internal:17670` with mTLS | Works (HTTP 200) |
| `docker inspect` of a real supervisor container | `NetworkMode=host`, `OPENSHELL_ENDPOINT=https://127.0.0.1:17670` |
| `docker run --network host alpine nc -zv 127.0.0.1 17670` | **Failed** |

**Root cause**

The OpenShell Docker driver runs the supervisor container with host networking and points it at `127.0.0.1:17670`. On Docker Desktop for Mac, "host" is the Linux VM's network, not the Mac's, so `127.0.0.1` inside the container never reaches the gateway.

**Fix**

1. In Docker Desktop, go to **Settings → Resources → Network** and check **Enable host networking**. Then click **Apply & restart**.
2. Run `brew services restart openshell`.
3. Verify:
   ```sh
   docker run --rm --network host alpine nc -zv -w3 127.0.0.1 17670
   # expected: 127.0.0.1 (127.0.0.1:17670) open
   ```
4. Smoke test:
   ```sh
   openshell sandbox create --name probe --from alpine --no-keep --no-tty -- echo sandbox-ok
   ```

The warning `host.openshell.internal maps to a non-link-local IP; trusted-gateway SSRF exemption disabled` comes from host networking and does not block startup.

---

## Issue 2: `workspace path component '/workspace' is not writable by the sandbox identity`

**Root cause**

OpenShell runs the workload as a non-root user taken from the image, and it checks that this user can write to the image's `WORKDIR`. The original Dockerfile created `/workspace` as root and set no `USER`.

**Fix** (in `Dockerfile.claude`)

```dockerfile
RUN mkdir -p /workspace && chown node:node /workspace

USER node

WORKDIR /workspace
```

The `node` user already exists in `node:24-bookworm-slim`. Keep the `apt-get` and `npm install -g` steps above `USER node`.

**Gotcha: image tag mismatch**

`docker build -t claude-agent .` produces `claude-agent:latest`, but the sandbox was created with `--from claude-agent:local`, which was still the old root image. Build and run with the same tag:

```sh
docker build -f Dockerfile.claude -t claude-agent:local .
```

To confirm the image runs as `node`:

```sh
docker image inspect claude-agent:local --format '{{.Config.User}}'   # expected: node
```

---

## Issue 3: `Failed to connect to api.anthropic.com: ECONNREFUSED`

**Root cause**

Claude Code starts, but on first run it does an onboarding and connectivity check against `api.anthropic.com`, even when `ANTHROPIC_BASE_URL` is set. The sandbox policy only allows `openrouter.ai`, so the connection is refused.

**Gotcha: `HOME` is `/workspace` inside the sandbox.** OpenShell sets `HOME=/workspace` and blocks reads of `/home/node`. A probe sandbox confirmed this: writing the flag to `/home/node/.claude.json` has no effect.

**Fix:** mark onboarding as done at `/workspace/.claude.json`, and turn off non-essential traffic. Add this to `Dockerfile.claude` **after** `USER node` / `WORKDIR /workspace`:

```dockerfile
ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

RUN echo '{"hasCompletedOnboarding":true}' > /workspace/.claude.json

CMD ["claude"]
```

Then rebuild (`-t claude-agent:local`) and re-create the sandbox.

### Auth header

When pointed at OpenRouter, Claude Code sends `Authorization: Bearer $ANTHROPIC_AUTH_TOKEN`. It does not read `OPENROUTER_API_KEY`.

Inside the sandbox, `OPENROUTER_API_KEY` is an OpenShell **placeholder** (it starts with `opensh...`), not the real key. The proxy swaps in the real key on requests to `openrouter.ai`. Pass that placeholder to Claude Code as `ANTHROPIC_AUTH_TOKEN`. This has to be expanded *inside* the sandbox, so use `sh -c` rather than `--env`:

```sh
-- sh -c 'ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY" exec claude'
```

---

---

## Issue 4: `Connection refused — a firewall or proxy…` (retrying)

**How to diagnose**

```sh
openshell logs claude-openrouter --source sandbox | grep -E 'DENIED|Denied'
```

```
DENIED /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe(0) -> openrouter.ai:443
reason=binary '...claude.exe' not allowed in policy '_provider_openrouter'
```

**Root cause**

OpenShell enforces binary identity (`require_binary_identity: true`), so only the binaries listed under `binaries:` in the provider profile may reach its endpoints. The profile listed `/usr/local/bin/node`, but Claude Code v2.x ships as a **native binary** (`claude.exe`), not a Node script.

**Fix:** in `provider-openrouter.yaml`:

```yaml
binaries:
  - /usr/local/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe
```

(An earlier version also listed `/usr/local/bin/node`. That let *any* node script use the key, so it was removed; see `case-study/RESULTS.md`.)

Push the updated profile to the gateway, then re-create the sandbox:

```sh
openshell profile update --file provider-openrouter.yaml openrouter
```

**Other harmless denials:** `downloads.claude.ai` (auto-updater) and `github.com` (git). To silence the updater, add `ENV DISABLE_AUTOUPDATER=1` to the Dockerfile.

---

## Final steps, end to end

```sh
# 1. One-time: in Docker Desktop, enable host networking, then:
brew services restart openshell

# 2. Build the image. The Dockerfile bakes in the base URL, model, onboarding flag,
#    and the .bashrc line that sets ANTHROPIC_AUTH_TOKEN. Change the model with --build-arg MODEL=...
docker build -f Dockerfile.claude -t claude-agent:local .

# 3. Create the sandbox with bash as the main process, then run `claude` inside it
openshell sandbox create --name claude-openrouter --from claude-agent:local --provider openrouter -- bash
```

- "Not logged in · Please run /login" means `ANTHROPIC_AUTH_TOKEN` is missing. Check with `echo $ANTHROPIC_AUTH_TOKEN` in the sandbox (it should print `openshell:...`).
- Without `ANTHROPIC_MODEL`, Claude Code defaults to Opus, which is billed through OpenRouter and is not free. The image sets it.
- Verified: the sandbox logs show `ALLOWED claude.exe -> openrouter.ai:443` and `POST /api/v1/messages`, and a `claude -p` run completed.

## Daily use: keep the sandbox alive and set the token automatically

**Problem:** with `-- sh -c '... exec claude'`, quitting Claude ends the sandbox's main process, and the sandbox goes to `Completed`. If you start `bash` instead and forget the `export`, Claude shows **"Not logged in · Please run /login"**.

Don't use `/login`. It tries to sign in to Anthropic, which the sandbox blocks ("Login interrupted").

**Fix 1: set the token in `.bashrc`.** OpenShell sets `HOME=/workspace`, so interactive bash reads `/workspace/.bashrc`. Add this to `Dockerfile.claude` after `USER node`:

```dockerfile
RUN echo 'export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"' >> /workspace/.bashrc
```

The single quotes matter: `$OPENROUTER_API_KEY` must be expanded *inside the sandbox* at shell start, not at build time, when it doesn't exist.

Rebuild: `docker build -f Dockerfile.claude -t claude-agent:local .`

**Fix 2: start `bash` as the main process**, not `claude`:

```sh
openshell sandbox create \
  --name claude-openrouter \
  --from claude-agent:local \
  --provider openrouter \
  --env ANTHROPIC_BASE_URL=https://openrouter.ai/api \
  --env ANTHROPIC_API_KEY="" \
  --env ANTHROPIC_MODEL=cohere/north-mini-code:free \
  --env ANTHROPIC_DEFAULT_OPUS_MODEL=cohere/north-mini-code:free \
  --env ANTHROPIC_DEFAULT_SONNET_MODEL=cohere/north-mini-code:free \
  --env ANTHROPIC_DEFAULT_HAIKU_MODEL=cohere/north-mini-code:free \
  -- bash
```

Then, inside the sandbox, just run `claude`. Quitting Claude drops you back to bash, and the sandbox keeps running.

**Without the `.bashrc` line**, run this in the sandbox before `claude`:

```sh
echo $OPENROUTER_API_KEY                           # should print openshell:...
export ANTHROPIC_AUTH_TOKEN="$OPENROUTER_API_KEY"
claude
```

**Reopening:**

| Action | Command |
|---|---|
| Detach without stopping | `Ctrl-P` then `Ctrl-Q` |
| Reconnect | `openshell sandbox connect claude-openrouter` |
| Pause (keeps `/workspace`) | `openshell sandbox stop claude-openrouter` |
| Resume | `openshell sandbox start claude-openrouter` |
| Sandbox shows `Completed` | Main process exited: `openshell sandbox delete claude-openrouter` and create it again |

## Updating the provider profile

`openshell profile update` needs the current `resource_version`, so always export first:

```sh
openshell profile export openrouter > openrouter-export.yaml   # edit this file
openshell profile update --file openrouter-export.yaml openrouter
```

If it fails with "modified concurrently (current resource_version: N)", re-export, or set `resource_version: N` in the file, then run the update again.

## Useful debugging commands

```sh
openshell status                                     # gateway reachable?
openshell sandbox list                               # sandbox phases
openshell sandbox get <name>                         # conditions + supervisor log tail
tail -f /opt/homebrew/var/log/openshell/openshell-gateway.out.log
docker ps -a --filter label=openshell.ai/managed-by=openshell
docker inspect <supervisor-container> --format '{{.HostConfig.NetworkMode}} {{range .Config.Env}}{{println .}}{{end}}'
```
