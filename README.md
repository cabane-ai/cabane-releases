# Run Cabane on your own machine

**One `docker compose up` and you have a working Cabane** — files, chat, agents — on your own machine, with no cloud account and nothing phoning home. The only traffic that ever leaves the machine is your agent's own LLM calls.

It's the same server image that runs cabane.ai, running as a single process next to a Postgres 17 container, with a third container where your agents run. Each release publishes both images, for x86 and Arm, and a compose file that names them at that release's version. Everything is local: your files live on a disk volume (no object storage), the database lives on a disk volume, and you sign in with an account you create on first run.

> **The trade for "no cloud":** in this single-player mode the app runs over plain `http://localhost` and rendered HTML pages share the app's origin (they're not sandboxed onto a second origin the way cabane.ai isolates them). That's a fine trade on your own machine. Putting it on a public URL for other people is a different setup — see [On a domain](#on-a-domain). The full reasoning is in [TRUST.md](./TRUST.md).

---

## What you need

- **Docker** with Compose (Docker Desktop, or Docker Engine + the Compose plugin). Nothing else is installed on this machine.
- **A Claude or ChatGPT account** for your agents' model, signed in once inside the runner (step 5). The server holds no model key.

You do **not** need: an R2/S3 bucket, an email provider, a public URL, a TLS cert, or any Cabane account.

---

## Quick start

### 1. Get a release

```bash
curl -fsSL https://github.com/cabane-ai/cabane-releases/releases/latest/download/cabane.tar.gz | tar -xz
cd cabane
```

That's a `cabane` folder holding the release's compose file, which names both images at its version, and the scripts for [backup and restore](#backup-and-restore). Nothing is built on this machine: `docker compose` pulls both images.

There's nothing to configure. Every setting has a working default, and the app makes its own secrets on its first start. To change a default, `cp .env.example .env` and edit it: if you want the app on a port other than `8788`, change **both** `PORT` and `PUBLIC_BASE_URL` to match.

### 2. Bring it up

```bash
docker compose up
```

The first run downloads the images, then starts three containers: the app, Postgres and the runner where agents work. Each time the app starts it **applies its own database migrations** before it serves, so a fresh machine becomes a working schema with no extra step. On its first start it also makes the secret that signs file links and the key that seals the keys people paste into Connections, and keeps both on the `cabane_secrets` volume. When you see `cabane-api listening`, it's ready.

Leave it running and open **http://localhost:8788** in your browser.

### 3. Create your account and workspace

- Do this as soon as it's up: a new server opens on **Create the first account**, and whoever reaches it first gets that account. Pick an email and a password; you're asked your name next.
- After that, sign-up is by invite. Anyone with an account can make invite links in **Settings → Invites**. To let anyone sign up, see [Opening sign-up](#opening-sign-up).
- There's no email provider, so nothing is emailed. A password-reset or email-change link is printed to the app's log (`docker compose logs app`). To send them by email, see [Adding email](#adding-email).
- Once you're in, **create a workspace**. That's your file tree + chat. You'll land in it with a "Welcome to Cabane" folder already there.

### 4. Have a conversation

Start a chat in your workspace, address an agent, and ask it to do something with your files — "summarize the welcome note," "make me a checklist page." The turn runs on the built-in runner once it's paired and signed in (step 5); until then an addressed agent has nowhere to run.

### 5. Give your agents somewhere to run

The `companion` container is the built-in runner: a Cabane companion, the same program people run on their own machines, with Claude Code and Codex inside. It pairs with your instance the ordinary way, once.

1. **Pair it.** In the app, open your workspace's **Settings → Devices → Set up a new device**. Then read the code the runner printed:

   ```bash
   docker compose logs companion
   ```

   Type the code into **Code from the terminal** and choose **Confirm**, or open the link printed beside it. The device shows up as **cabane-runner**. A code lasts 15 minutes; the runner prints a fresh one when it runs out, and starts over if three run out.

2. **Sign in to a model**, inside the runner. Open the printed link in your browser and paste back any code it asks for:

   ```bash
   docker compose exec companion claude auth login             # Claude Code
   docker compose exec companion codex login --device-auth     # Codex
   ```

   Or put the harness's key in the runner's `~/.cabane/secrets.json`, the same recipe as [a container per turn](#each-turn-in-a-container-of-its-own): `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY` for Claude Code, `CODEX_API_KEY` for Codex. Every turn on the runner is then given that key.

   ```bash
   echo '{"CLAUDE_CODE_OAUTH_TOKEN": "…"}' |
     docker compose exec -T companion sh -c 'umask 077; cat > ~/.cabane/secrets.json'
   ```

   A key added to the file or taken out of it while the runner is up shows in `cabane status` within five minutes, with no restart.

3. **Check it:** `docker compose exec companion cabane status` shows the harness you signed in to as **connected**.

4. **Place an agent on it:** in that agent's settings, under where it runs, choose **cabane-runner** and the harness.

The pairing, the sign-in and the agents' working folders are kept on the `cabane_companion_home` volume, so restarting or recreating the container keeps them. Every agent placed on the runner shares the container and the one sign-in. The agent reads and writes the workspace and answers in the conversation — that's the whole loop.

> **If an agent won't answer,** check `docker compose exec companion cabane status`, and that the agent is placed on **cabane-runner**.

#### What the built-in runner doesn't promise

All turns run in the one container, so two things a companion on its own machine can do, it can't do here:

- **Background processes outlive a turn.** When a turn ends or is stopped, a process it started in the background (a dev server, a watcher) can keep running. Restarting the runner clears them: `docker compose restart companion`.
- **A turn killed for memory isn't reported as out of memory.** With `COMPANION_MEMORY_LIMIT` set, the limit is the whole runner's, every turn in it together. When it's reached, the system stops the biggest process in the runner, usually the command that went over: the agent sees that command killed, not an out-of-memory report, and the companion and other turns carry on. If the biggest process is the companion itself, every turn running then stops with it, and the container starts again on its own.

#### Leaving the built-in runner out

The instance doesn't need it. Set `BUILT_IN_RUNNER=0` in `.env` and `docker compose up -d`: the runner container is removed and the volume kept. Run your agents on a companion paired from another machine instead: [the companion's own guide](https://www.npmjs.com/package/@cabane/companion), or the same runner image there (next).

#### A companion in Docker on another machine

The runner image works anywhere with Docker, pointed at an instance on https. Its agents work inside the container, not on that machine. Run the companion image of the instance's own release, the one its compose file names (`grep image: compose.yaml` there):

```bash
docker run -d --name cabane-companion --restart unless-stopped \
  --hostname my-runner \
  -e CABANE_BASE_URL=https://cabane.example.com \
  -v cabane-companion-home:/home/node \
  ghcr.io/cabane-ai/cabane-companion:0.6.252               # the instance's version
docker logs cabane-companion                               # the pairing code
docker exec -it cabane-companion claude auth login         # or: codex login --device-auth
docker exec cabane-companion cabane status
```

Pair it and place agents on it as in step 5; it shows up under the `--hostname` you gave it. It refuses a plain-http address other than this machine's own, so give it the instance's https address. To update it, when the instance moves to a new release, replace the container with that release's image; the volume keeps the pairing and the sign-in. Don't run `cabane update` inside it: a new companion is a new image.

---

## Everyday use

```bash
docker compose up -d          # start in the background
docker compose logs -f app    # watch the app logs
docker compose down           # stop (your data stays on the volumes)
```

Your files, database and secrets live on the named Docker volumes (`cabane_storage`, `cabane_db`, `cabane_secrets`), and the runner's pairing and sign-in on `cabane_companion_home`, so `down` and `up` don't lose anything. Removing the volumes (`docker compose down -v`) **erases everything** — that's the deliberate "start over" button. Losing `cabane_secrets` alone breaks file links already issued and makes stored connection keys unreadable, so back them up together: [Backup and restore](#backup-and-restore).

---

## Sign-up and email

Both are settings in `.env`, beside the compose file. An upgrade replaces the compose file and leaves `.env` alone, so a setting made there stays. Unset, the instance takes invitations only and emails nothing.

### Opening sign-up

To let anyone who reaches the app create an account, without an invite:

```bash
echo 'SIGNUP_MODE=open' >> .env
docker compose up -d
```

To close it again, remove the line (or set `SIGNUP_MODE=invite`) and `docker compose up -d`. Accounts already made stay. To link the sign-up screens to a privacy notice of yours, set `PRIVACY_NOTICE_URL` to its address the same way.

### Adding email

Cabane sends email through [Resend](https://resend.com). With an account there and a domain you've verified in it, put its API key and the address mail comes from in `.env`, and restart:

```bash
RESEND_API_KEY=re_…
EMAIL_FROM="Cabane <cabane@example.com>"    # on the domain you verified
EMAIL_REPLY_TO=help@example.com             # optional: where replies go
```

```bash
docker compose up -d
```

Password-reset and email-change links are then emailed, and no longer printed to the log. `docker compose logs app` says `RESEND_API_KEY not set` on every start without it. The app refuses to start with the key and no `EMAIL_FROM`.

---

## Upgrading

Put the new release's files over these and restart:

```bash
sh backup.sh                  # first, in case you want this release back (next section)
curl -fsSL https://github.com/cabane-ai/cabane-releases/releases/latest/download/cabane.tar.gz | tar -xz --strip-components=1
docker compose pull
docker compose up -d
```

The download replaces the compose file and the scripts and leaves your `.env` alone. Your data, the runner's pairing and everyone's sign-ins stay on the volumes. Each time the app starts it migrates the database forward from wherever it is, so you can skip releases: any earlier release upgrades straight to the newest. Watch `docker compose logs app` for `cabane-api listening`.

The version is on the compose file's two `image:` lines. Changing them by hand to a newer release's number does the same as taking its files, as long as that release's compose file has no other change. Take the files: that's the one that's always right. Going back to an older release isn't supported once the newer one has migrated the database: restore the backup you took before upgrading instead.

**A companion older than its instance.** The built-in runner moves with the compose file, so it's always the instance's own release. A companion elsewhere doesn't: a runner image on another machine, or one installed with npm. While it's within the range the instance accepts, it keeps working, and its log says the two versions differ. Once it's older than the oldest companion the instance accepts, its agents stop answering, and the conversation says the companion on that device is out of date. Update it to the instance's release: the runner image at that version, or `cabane update` for one installed with npm or the install script, which installs the instance's own version.

---

## Backup and restore

A backup is one file holding everything the instance keeps: the database, your files, the secrets it made on its first start (without them, file links and the keys stored in Connections stop working), and the built-in runner's home, with its pairing, its model sign-ins and the agents' working folders. It holds your `.env` too, if you have one. From the `cabane` folder:

```bash
sh backup.sh                       # writes cabane-backup-<date>-<time>.tar.gz here
```

The instance stops while the copy is taken, for as long as it takes to copy the volumes, then starts again. The file holds your secrets: keep it as safe as the machine.

To restore, onto another machine or this one after it's lost, get the same release or a newer one ([step 1](#1-get-a-release)), copy the backup file into its folder, and:

```bash
sh restore.sh cabane-backup-<date>-<time>.tar.gz
docker compose up -d
```

People sign in as before and find their files, and the built-in runner answers without being paired again. Check it with `docker compose exec companion cabane status`: if a harness shows as not signed in on the new machine, sign in again as in step 5. Restoring refuses to write over an instance that's already there. To replace one on the same machine, back it up first, remove it with `docker compose down -v`, which erases it, and then restore.

---

## Going further

This setup is deliberately single-player and single-machine. A few things are out of scope on purpose:

- **An external Claude Code or Cursor over MCP.** You can connect an outside assistant straight to your workspace: in workspace settings → connect an external client, mint a personal access token, and add your instance as an MCP server (`http://localhost:8788/api/mcp`, bearer = that token). It reads and writes your files _as you_ — genuinely useful, and it works here exactly as on cabane.ai. It is **not** a companion, so it doesn't give your workspace's own agents anywhere to run; that's what the runner in step 5 is for.
- **A public URL / other people / your phone.** See [On a domain](#on-a-domain) below.
- **Email, invites, multiplayer.** Single-player needs none of it; password reset works via a link printed in the app logs. For more people, see [Sign-up and email](#sign-up-and-email) and [On a domain](#on-a-domain).

See [TRUST.md](./TRUST.md) for what running Cabane yourself promises: it keeps working without us, it sends no telemetry unless you turn it on, and you can export everything.

---

## Each turn in a container of its own

By default the built-in runner is one container that every agent shares. With `compose.turns.yaml` laid over `compose.yaml`, it starts a container for each turn instead and removes it when the turn ends, is stopped or fails:

- two agents can't read each other's files or reach each other;
- a turn can't reach this machine, Postgres, the runner or a private network. Its only route out is the `egress` service, a Squid proxy run from the runner's own image ([egress.conf](egress.conf)), which allows web ports and the instance, and refuses private, loopback, link-local and reserved addresses and this machine's own;
- a turn never holds the model credentials or the GitHub token in the runner's `secrets.json`, only stand-ins for them (below);
- nothing a turn started outlives it, and a turn killed for memory is reported as out of memory.

Each conversation and agent keeps a home volume, `cabane-home-<conversation>-<agent>`, with the agent's working folder and the harness's sessions, so the next turn picks up where the last left off. These volumes are kept until you remove them.

**Turn it on.** The runner needs Docker's socket, which is control of this machine. The turns' containers never get it.

```bash
export DOCKER_GID=$(stat -c %g /var/run/docker.sock)
docker compose -f compose.yaml -f compose.turns.yaml up -d
```

Put both files on every `docker compose` command from then on, or set `COMPOSE_FILE=compose.yaml:compose.turns.yaml` in `.env`. Without the second file nothing changes.

**Sign in.** A sign-in made with `claude auth login` inside the runner stays in the runner and doesn't reach a turn's container. Put the harness's key in the runner's `~/.cabane/secrets.json` instead, and every turn can use its own harness's key: `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY` for Claude Code, `CODEX_API_KEY` for Codex. `GH_TOKEN` there is for git and `gh`.

```bash
echo '{"CLAUDE_CODE_OAUTH_TOKEN": "…"}' |
  docker compose exec -T companion sh -c 'umask 077; cat > ~/.cabane/secrets.json'
```

**What a turn holds.** Those four credentials never enter a turn's container. The turn gets a stand-in for each, the same one every time for that conversation and agent, so a repository it cloned keeps working. The egress proxy replaces the stand-in with the real credential only on a request from that turn's container to that credential's own service (`api.anthropic.com`, `api.openai.com`, `github.com`, `api.github.com`), sent over TLS. A stand-in is worth nothing anywhere else, from any other container, or once its turn is over.

- **The egress proxy intercepts TLS for those four hosts.** To replace a stand-in it has to read the request, so it terminates TLS for those four hosts and no others, and still checks each host's real certificate. It signs those connections with a certificate authority (CA) it generates each time it starts and keeps in memory, and the turn's container trusts that CA. Connections to every other host are tunnelled untouched, with the host's own certificate.
- **Refused on those hosts:** plain HTTP, and the requests that create or reveal a credential, such as adding an SSH key to GitHub.
- **Passed to the turn unchanged:** anything else in `secrets.json`, and the workspace's room secrets and connections.
- **Not covered:** a Codex pointed at another address in its `config.toml` (an injected credential won't work there), Codex on a ChatGPT sign-in, GitHub Enterprise, and a response that echoes a credential back.
- **If the egress proxy stops or restarts** while a turn runs, the turn fails within 30 seconds, saying so, and isn't run again. Restarting it during work does this to every turn running.
- **A credential with any character but letters, digits and `. _ + / = -`** refuses every turn, naming it but not showing its value.

**Settings**, in `.env`:

| Variable               | Default  |                                                                                                                                                                                                          |
| ---------------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TURN_MEMORY_MB`       | `4096`   | Each turn's memory, with no swap beyond it. A command that outgrows it fails with its own error, such as Node's "heap out of memory", and isn't reported as out of memory: this is the setting to raise. |
| `TURN_CPUS`            | `2`      | Each turn's processors.                                                                                                                                                                                  |
| `TURN_PIDS`            | `512`    | Each turn's processes.                                                                                                                                                                                   |
| `MAX_CONCURRENT_TURNS` | `4`      | Turns running at the same time; the rest wait. A turn still waiting after 30 minutes fails, and the person is told.                                                                                      |
| `TURN_CGROUP_PARENT`   | unset    | A control group (or systemd slice) of yours that every turn's container is started under, so your own limit on it caps them all. The runner doesn't create it or set its limit.                          |
| `TURN_NETWORK`         | `closed` | `open` gives each turn an ordinary bridge with a direct route out as well as the egress proxy.                                                                                                           |

Turns together can take `TURN_MEMORY_MB` times `MAX_CONCURRENT_TURNS`, 16 GB with the defaults. Nothing caps that total but `TURN_CGROUP_PARENT`.

**Not yet:**

- OpenCode. A turn for OpenCode ends saying it isn't available in a container.
- The harnesses' own sandboxes. Neither Claude Code's nor Codex's starts under Docker's default settings, so the turn's container is the only isolation.
- Docker Desktop on a Mac hasn't been tried.

**On another machine.** `compose.companion.yaml` brings up a companion and its egress proxy alone, with each turn in a container, paired to an instance elsewhere:

```bash
export DOCKER_GID=$(stat -c %g /var/run/docker.sock)
CABANE_BASE_URL=https://cabane.example.com docker compose -f compose.companion.yaml up -d
docker compose -f compose.companion.yaml logs companion       # the pairing code
```

Pair it, sign it in as above and place agents on it as in step 5. It shows up as `cabane-companion`, or `COMPANION_NAME`. The settings above apply to it too.

## On a domain

For other people to use it, put the instance on two hostnames you own: one for the app, one for the pages your workspaces render. Pages get a hostname of their own so a page can't read the session of whoever opens it.

1. **Two DNS records.** Point both hostnames at this machine (an `A` record each, and `AAAA` if it has IPv6), for example `cabane.example.com` and `pages.cabane.example.com`.
2. **Ports 80 and 443** reach this machine from the internet.
3. **Two values in `.env`:**

   ```bash
   CABANE_DOMAIN=cabane.example.com
   CABANE_PAGES_DOMAIN=pages.cabane.example.com
   ```

4. `docker compose up -d`.

A third container, `edge` (a stock Caddy), comes up beside the app and gets a certificate for each hostname on its own. The app is then reachable only through it: its port is no longer published on this machine, and `PUBLIC_BASE_URL` and `PORT` no longer set the address.

**What working looks like:** `https://cabane.example.com` opens on **Create the first account** with a valid certificate, and a page you open from a workspace loads from `https://pages.cabane.example.com`. `docker compose logs edge` shows `certificate obtained successfully` once for each hostname. The built-in runner keeps reaching the app inside Docker, unchanged; a companion on another machine pairs with `https://cabane.example.com`.

- **Setting only one of the two** is refused before anything starts: compose stops with `service "app-on-domain" not found in publish.yaml` (only `CABANE_DOMAIN` set) or `service "app-and-pages-domain" not found` (only `CABANE_PAGES_DOMAIN` set). Set both, or neither.
- **Certificates fail** — usually DNS not pointing here yet, or port 80 or 443 blocked. Fix it and `docker compose restart edge`. Certificates are kept on the `cabane_edge_data` volume.
- **80 and 443 are already taken** by a proxy on this machine: set `EDGE_HTTP_PORT` and `EDGE_HTTPS_PORT` to free ports, then have that proxy do two things for both hostnames. On port 80, forward `/.well-known/acme-challenge/*` to the edge's HTTP port, so the edge still gets its own certificates. On 443, terminate TLS with a certificate of its own for the two hostnames and proxy to the edge over https, checking the edge's certificate against the hostname. Passing TLS through untouched also works, but a stock Caddy or nginx `http` block can't do it. With Caddy in front, the site looks like this (ports as set above):

  ```caddyfile
  http://cabane.example.com, http://pages.cabane.example.com {
  	handle /.well-known/acme-challenge/* {
  		reverse_proxy 127.0.0.1:8180
  	}
  	handle {
  		redir https://{host}{uri} permanent
  	}
  }
  cabane.example.com, pages.cabane.example.com {
  	reverse_proxy https://127.0.0.1:8543 {
  		header_up Host {host}
  		transport http {
  			tls_server_name {host}
  		}
  	}
  }
  ```

- **Don't put an instance under a parent domain whose other services set domain-wide cookies** (for example `cabane.dev.example.com` when something else sets cookies on `.dev.example.com`). Browsers send those cookies to both of the instance's hostnames. Pages still can't read them, but the server receives them. Give the instance a domain of its own, or a subdomain where nothing sets domain-wide cookies.
- **Memory limits** for a machine shared with other work: `APP_MEMORY_LIMIT`, `DB_MEMORY_LIMIT`, `EDGE_MEMORY_LIMIT`, `COMPANION_MEMORY_LIMIT` (for example `2g`).
- To go back to localhost, clear both values and `docker compose up -d` again.

---

## Telemetry (off unless you turn it on)

The app can send its own logs and measurements to an OpenTelemetry collector you run, or to any backend that accepts OTLP over HTTP. It is off by default and sends nothing. To turn it on, set the endpoint (and a token, if your collector wants one) in `.env` and restart:

```bash
CABANE_TELEMETRY_ENDPOINT=http://your-collector:4318
CABANE_TELEMETRY_TOKEN=…          # optional, sent as a bearer token
CABANE_TELEMETRY_LEVEL=safe       # or `full` for your own backend
docker compose up -d
```

The install shows up at the collector within a minute: a `cabane.runtime.*` measurement every minute, a `request_completed` log record per request, a record for each of the app's own log lines and errors, and one per agent turn, per tool call and per wake that couldn't be delivered. Clear the endpoint and restart to go silent again. What each level sends, field by field, is in [TRUST.md](./TRUST.md#telemetry-if-you-turn-it-on).

---

## Troubleshooting

- **The app exits on start** — read `docker compose logs app`. A migration that fails stops the app before it serves, and the next start tries again. A `secrets` file that is empty stops it too: restore it from a backup, or delete it to have a new one made (file links already issued stop working).
- **An agent you address never answers** — the runner isn't paired or signed in, or the agent isn't placed on it (step 5). `docker compose logs companion` shows what it's doing. (Check you actually called it: an agent answers a message that names it as `@theagent` in ordinary text. The same handle inside code, a quote or a link calls nobody.)
- **Login doesn't stick / bounces back to sign-in** — your `PUBLIC_BASE_URL` must match exactly what's in the address bar, scheme included. Over `http://localhost` the session cookie is (correctly) not marked `Secure`; if you changed the port, make sure `PORT` and `PUBLIC_BASE_URL` agree.
- **A rendered page won't load** — rendered pages are authorized by a short-lived token; reopen the page from the app rather than reusing an old link.
- **Port already in use** — change `PORT` and `PUBLIC_BASE_URL` in `.env` to a free port and `docker compose up` again.
