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
  ghcr.io/cabane-ai/cabane-companion:0.6.265               # the instance's version
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

To close it again, remove the line (or set `SIGNUP_MODE=invite`) and `docker compose up -d`. Accounts already made stay. To link the sign-up screens to a privacy notice or terms of use of yours, set `PRIVACY_NOTICE_URL` or `TERMS_URL` to its address the same way.

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

With `RUNNER_IMAGE` set in `.env`, build your image again on the new release's before `docker compose up -d`, and leave out `docker compose pull`: [Adding tools for agents](#adding-tools-for-agents).

The download replaces the compose file and the scripts and leaves your `.env` alone. Your data, the runner's pairing and everyone's sign-ins stay on the volumes. Each time the app starts it migrates the database forward from wherever it is, so you can skip releases: any earlier release upgrades straight to the newest. Watch `docker compose logs app` for `cabane-api listening`.

The version is on the compose file's two `image:` lines. Changing them by hand to a newer release's number does the same as taking its files, as long as that release's compose file has no other change. Take the files: that's the one that's always right. Going back to an older release isn't supported once the newer one has migrated the database: restore the backup you took before upgrading instead.

**A companion older than its instance.** The built-in runner moves with the compose file, so it's the instance's own release, unless `RUNNER_IMAGE` names an image of your own: then the built-in runner, its turns and the egress proxy are whatever release that image was built from ([Adding tools for agents](#adding-tools-for-agents)). A companion elsewhere doesn't: a runner image on another machine, or one installed with npm. While it's within the range the instance accepts, it keeps working, and its log says the two versions differ. Once it's older than the oldest companion the instance accepts, its agents stop answering, and the conversation says the companion on that device is out of date. Update it to the instance's release: the runner image at that version, or `cabane update` for one installed with npm or the install script, which installs the instance's own version.

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

### One workspace, to another instance

A backup copies the whole instance. To move **one workspace** to another instance, or keep a copy of just that workspace, export it as a file and import that file on the other side. From the `cabane` folder:

```bash
docker compose exec -T app node dist/workspace.js export <slug or id> > workspace.cabane
docker compose exec -T app node dist/workspace.js import - < workspace.cabane
```

Export writes the file to standard output (or to `--out <file>` inside the container) and says what it did on the terminal. The file holds every private room and direct message in the workspace: keep it as safe as a backup.

**What the file holds:** the workspace's rooms, conversations and messages, tasks, agents and their settings, files with their history and their bytes, each turn's attempts and prompt, and the people its rows name, with their names, emails and pictures. The workspace keeps its id, and so does everything in it, so every link inside a message or a file still opens the right thing.

**What it leaves out:** passwords, sessions and tokens; connections and secrets; hooks and webhooks; invites that were still pending; browser profiles; and every device and pairing. Agents arrive with no device. Schedules arrive switched off. Import ends with a list of all of these, by name, to set up again.

**People.** Someone whose account is already on the target, under the same id, keeps that account exactly as it is there, name and picture included. Someone new arrives with an account that has no password: import prints a link to set one (it works for an hour; after that, use **Forgot password**), or emails it when the instance can send email. Nobody is matched by email: if a new person's email already belongs to a different account here, import refuses and names it. Importing into a new instance creates accounts, so its first-run screen doesn't show; people get in through their links.

**Export refuses while an agent is mid-turn** in the workspace, and names the agent and the conversation. Run it again when the turn has ended, or pass `--wait <seconds>` to keep trying for that long. A quiet moment, or stopping the agents first, is the way to export a busy workspace.

**Reminders and waiting work.** A reminder an agent set for itself travels and lands at its time. If its agent isn't on a device by then, the conversation shows the usual notice that the agent has no device, and nothing runs; name the agent in the conversation again once it is placed to pick the work up. Import prints when the first reminder is due. A delivery that was on its way to an agent when the export was taken is ended on the target after half an hour, with the usual notice that the agent didn't respond. News an agent hadn't read yet waits, and starts nothing on its own: the agent reads it the next time it is woken in that conversation. If the old instance keeps running, its copies of the reminders fire there too, until it is retired.

**Import refuses**, writing nothing, when:

- the workspace is already on this instance (delete it first to restore over it);
- the owner already has a workspace with the same slug here;
- a new person's email belongs to another account here;
- the two instances aren't on the same database migration. The message names the migration the file was taken at: install the release that carries it.

Import loads the whole workspace in one step: if anything fails, no part of it is left behind, and the same file imports cleanly once the cause is fixed. Stored files it wrote before the failure stay, unused, and are written over by the next try.

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
- a turn can't reach this machine, Postgres, the runner or a private network. Its only route out is the `egress` service, a Squid proxy run from the runner's own image ([egress.conf](egress.conf)), which allows web ports, the instance and its pages at `cabane-pages`, and refuses private, loopback, link-local and reserved addresses and this machine's own;
- a turn never holds a value with addresses, only a stand-in for it (below): a room secret whose owner gave it addresses, a connection's own key, and the model credentials and GitHub token in the runner's `secrets.json`;
- nothing a turn started outlives it, unless it is serving on the turn's ports when those are on ([below](#ports-a-person-can-open)), and a turn killed for memory is reported as out of memory.

Each conversation and agent keeps a home volume, `cabane-home-<conversation>-<agent>`, with the agent's working folder and the harness's sessions, so the next turn picks up where the last left off. An agent that clones a repository and installs its packages can leave a few GB in each. These volumes are kept until you remove them, or until the disk needs the room when `MIN_FREE_DISK_GB` is set (below).

**When the disk runs low.** With `MIN_FREE_DISK_GB` set, a turn about to start first checks free space on the disk Docker keeps volumes on. Under the floor, the runner deletes the home volumes idle longest, oldest first, until free space is back above it, and then starts the turn. A home is deleted only if:

- the runner has run a turn in it since this setting was set, and recorded when that turn ended (in its own `~/.cabane/turn-homes.json`, never in a home). A turn the runner was stopped or restarted during counts as ending when the runner next starts a turn. If the runner can't save that a turn is starting, the turn is refused;
- no turn has used it for `HOME_IDLE_HOURS`, and nothing in it has changed for that long, as the disk itself says (read with `find` in a short-lived container that mounts it read-only, to the second). A home a turn wrote to within that time is kept, even if the record missed that turn;
- no turn is running in it or waiting to start in it.

If that doesn't free enough, the turn is refused before anything is made for it. The conversation says the agent's device couldn't set up a place to run the turn, and the runner's log (`docker compose logs companion`) says the disk is full, with the free space and the floor. Nothing is deleted for its age alone: with a large disk every home is kept. Without `MIN_FREE_DISK_GB`, nothing is deleted or refused, and the runner keeps no record, removing the one from before if it can. The record is trusted only if no run could have used a home without it since it was written: one with no floor, or an older runner, starts the record again the next time a floor is set, so nothing is deleted until homes are used again. The runner checks this with a container it creates and never starts, labelled `cabane.role=homes-seal`; any runner start removes it, and removing it by hand has the same effect.

**One companion per agent on a Docker.** A home is named for its conversation and agent, not for the companion, so two companions on the same Docker running the same agent share its homes. Neither records the other's turns. A turn of the other's that wrote nothing and was cut short isn't protected, and its home can go as soon as this runner's record calls it idle. With `MIN_FREE_DISK_GB` set, give each agent one companion per Docker.

Deleting a home loses what the agent left in it: the working folder, with anything not pushed or saved to the workspace, and the harness's memory of that conversation, so the next turn there starts a fresh session. The conversation, its messages and its files are the instance's, and stay. Volumes the runner has no record of, such as homes from before this setting or another companion's, are never deleted; list homes with `docker volume ls --filter label=cabane.role=home` and remove one you don't need with `docker volume rm`.

**Turn it on.** The runner needs Docker's socket, which is control of this machine. The turns' containers never get it.

```bash
export DOCKER_GID=$(stat -c %g /var/run/docker.sock)   # Docker's own socket; a Docker without root: below
docker compose -f compose.yaml -f compose.turns.yaml up -d
```

Put both files on every `docker compose` command from then on, or set `COMPOSE_FILE=compose.yaml:compose.turns.yaml` in `.env`. Without the second file nothing changes.

**Sign in.** A sign-in made with `claude auth login` inside the runner stays in the runner and doesn't reach a turn's container. Put the harness's key in the runner's `~/.cabane/secrets.json` instead, and every turn can use its own harness's key: `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY` for Claude Code, `CODEX_API_KEY` for Codex. `GH_TOKEN` there is for git and `gh`.

Codex signed in with a ChatGPT account works here too, signed in as in step 2: `docker compose exec companion codex login --device-auth`. The sign-in stays in the runner, each Codex turn gets a stand-in for it, and the runner refreshes it a day before it expires, since no Codex runs there to do it. Sign in inside the runner itself, never by copying `auth.json` from a machine that goes on using it: a refresh replaces the sign-in's refresh token, and the other machine's copy can't be relied on after that. While the sign-in is expired, Codex shows as not signed in and its turns are refused; the runner keeps trying, also as a Codex turn arrives, and turns resume once a refresh gets through. If the sign-in service refuses a refresh for good, sign in again. A `CODEX_API_KEY` in `secrets.json` is used instead whenever it is there.

```bash
echo '{"CLAUDE_CODE_OAUTH_TOKEN": "…"}' |
  docker compose exec -T companion sh -c 'umask 077; cat > ~/.cabane/secrets.json'
```

**What a turn holds.** A value with addresses never enters a turn's container: a room secret whose owner gave it addresses, a connection's own key at an `https://` address on port 443, four credentials in `secrets.json`, sent to their own services (`api.anthropic.com`, `api.openai.com`, `github.com`, `api.github.com`), and Codex's ChatGPT sign-in, sent to `chatgpt.com`. The runner tells the instance that its turns keep values out, and the turn gets a stand-in for each value, the same one every time for that conversation and agent, so a repository it cloned keeps working. The egress proxy puts the real value in place of the stand-in, in any request header, only on a request from that turn's container to one of the value's own hosts, sent over TLS to port 443. A stand-in is worth nothing anywhere else, from any other container, or once its turn is over. A secret's or connection's page shows, for each device its agents run on, whether that device keeps it from agents.

- **The egress proxy intercepts TLS only for the hosts a turn holds a stand-in for.** To replace a stand-in it has to read the request, so it terminates TLS for those hosts and no others, and still checks each host's real certificate. It signs those connections with a certificate authority (CA) it generates each time it starts and keeps in memory, and the turn's container trusts that CA. Connections to every other host are tunnelled untouched, with the host's own certificate. Which hosts those are comes from a table the runner replaces as turns start and end, so a turn starting never reloads the proxy.
- **Refused on those hosts:** plain HTTP, and the requests that create or reveal a credential, such as adding an SSH key to GitHub. A WebSocket upgrade is let through with the real value; nothing sent after it is read. While the runner holds a ChatGPT sign-in, the egress proxy also intercepts `auth.openai.com` for one thing only: refusing a turn's attempt to refresh the sign-in there.
- **Passed to the turn unchanged:** anything else in `secrets.json`, and room secrets with no addresses.
- **Left out of the turn, and the agent told why:** a connection with a key of its own at any other address (another port, plain HTTP, an IP address or a name with no dot), or whose key holds a line break or a character a request can't carry as it is.
- **Not covered:** a Codex pointed at another address in its `config.toml` (a stand-in won't work there), and a response that echoes a value back.
- **If the egress proxy stops or restarts** while a turn runs, the turn fails within 30 seconds, saying so, and isn't run again. Restarting it during work does this to every turn running. The proxy stops when Squid or the swap service beside it stops.
- **A credential in `secrets.json` a request can't carry as it is** (a line break, a character outside visible ASCII, or a space at either end) refuses every turn, naming it but not showing its value.

**Settings**, in `.env`:

| Variable                  | Default     |                                                                                                                                                                                                          |
| ------------------------- | ----------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TURN_MEMORY_MB`          | `4096`      | Each turn's memory, with no swap beyond it. A command that outgrows it fails with its own error, such as Node's "heap out of memory", and isn't reported as out of memory: this is the setting to raise. |
| `TURN_CPUS`               | `2`         | Each turn's processors.                                                                                                                                                                                  |
| `TURN_PIDS`               | `512`       | Each turn's processes.                                                                                                                                                                                   |
| `MAX_CONCURRENT_TURNS`    | `4`         | Turns running at the same time; the rest wait. A turn still waiting after 30 minutes fails, and the person is told.                                                                                      |
| `MIN_FREE_DISK_GB`        | unset       | Free space, in GB, on the disk Docker keeps volumes on, under which a turn first deletes the home volumes idle longest, and is refused if that isn't enough. Unset: no home is ever deleted.             |
| `HOME_IDLE_HOURS`         | `24`        | How long a home must have gone unused before it can be deleted to make room.                                                                                                                             |
| `TURN_CGROUP_PARENT`      | unset       | A control group (or systemd slice) of yours that every turn's container is started under, so your own limit on it caps them all. The runner doesn't create it or set its limit.                          |
| `TURN_NETWORK`            | `closed`    | `open` gives each turn an ordinary bridge with a direct route out as well as the egress proxy.                                                                                                           |
| `TURN_PORTS`              | unset       | A range of ports on this machine, such as `20000-20029`, that a person can open an agent's app on, with `compose.ports.yaml` ([below](#ports-a-person-can-open)). Unset: nothing outside reaches a turn. |
| `TURN_PORTS_HOST`         | `localhost` | The name or address people reach this machine by, which an agent gives them with its ports.                                                                                                              |
| `TURN_PORTS_IDLE_MINUTES` | `30`        | How long an app kept after its turn stays up with nothing connected to it.                                                                                                                               |
| `DOCKER_SOCKET`           | unset       | Docker's socket on this machine, which the runner is given. Unset: `/var/run/docker.sock`. Set it for a Docker without root (below), with `DOCKER_GID` read as it says there.                            |

Turns together can take `TURN_MEMORY_MB` times `MAX_CONCURRENT_TURNS`, 16 GB with the defaults. Nothing caps that total but `TURN_CGROUP_PARENT`.

### Ports a person can open

An agent that builds an app can show it running. With `TURN_PORTS` set to a range of ports and `compose.ports.yaml` laid over the others, each conversation and agent holds three ports from the range while one of its turns is up, and a turn is told them, with the address to give a person, in `CABANE_PORTS` (such as `20000,20001,20002`) and `CABANE_PORTS_HOST`. An app the agent serves on one of them, listening on all of the container's addresses (`0.0.0.0`, not `localhost`), opens at `http://<TURN_PORTS_HOST>:<port>`, WebSockets included.

```bash
echo 'TURN_PORTS=20000-20029' >> .env
echo 'TURN_PORTS_HOST=cabane-box.example.com' >> .env
docker compose -f compose.yaml -f compose.turns.yaml -f compose.ports.yaml up -d
```

- **Anyone who can reach this machine on those ports can open the app.** Cabane doesn't check who. For https, names or a sign-in, put a proxy of your own in front, or publish the range on a private address only by editing `compose.ports.yaml`.
- **The way in is the egress proxy's.** It publishes the range, and a relay beside Squid passes each connection to the one turn container that owns the port, on the same port. It connects nowhere else, and a connection from a turn's own network is refused, so one turn can't reach another's app through it. Nothing a turn could reach before is reachable now.
- **An app still serving when its turn ends is kept**, with its container, until nothing has connected to its ports for `TURN_PORTS_IDLE_MINUTES`, the next turn in that conversation starts, someone stops the turn, the egress proxy restarts, or the runner restarts. It keeps its files and its route out, but none of the turn's credentials: no stand-in in it works any more. It doesn't count against `MAX_CONCURRENT_TURNS`, and does count against memory. A container with nothing listening on its ports is removed when its turn ends, as before.
- **A range serves a third as many conversations and agents up at once as it has ports**, rounded down, however many there are over time: `20000-20029` serves ten at a time. A conversation and agent hold their three while they have a container: a turn running or waiting to start, an app kept after its turn, or a container Docker failed to remove, which the runner tries again each minute and which nothing leads to meanwhile. Their next turn gets the same three when no other conversation has taken them since. When none are free, the ones given are those of the conversation that has been without a container longest.
- **So a link handed out can, in time, open another conversation's app.** Until its ports are given again, it gets no answer.
- **When every three are held, a turn still runs, without ports.** It has `CABANE_PORTS_FULL=1` and `CABANE_PORTS_HOST` in place of `CABANE_PORTS`, and the runner's log says so. Widen the range to cover the turns you have up at once.
- **The range can't include 3128 or 1344**, which the egress proxy listens on itself: the runner refuses the setting, and the egress proxy refuses to start with it.

Without `TURN_PORTS`, turns' containers and networks are exactly as above. With it set but without `compose.ports.yaml`, turns fail, and the runner's log says the egress proxy doesn't publish the ports.

**Not yet:**

- OpenCode. A turn for OpenCode ends saying it isn't available in a container.
- The harnesses' own sandboxes. Neither Claude Code's nor Codex's starts under Docker's default settings, so the turn's container is the only isolation.
- Docker Desktop on a Mac hasn't been tried.

**On another machine.** `compose.companion.yaml` brings up a companion and its egress proxy alone, with each turn in a container, paired to an instance elsewhere:

```bash
export DOCKER_GID=$(stat -c %g /var/run/docker.sock)   # Docker's own socket; a Docker without root: below
CABANE_BASE_URL=https://cabane.example.com docker compose -f compose.companion.yaml up -d
docker compose -f compose.companion.yaml logs companion       # the pairing code
```

Pair it, sign it in as above and place agents on it as in step 5. It shows up as `cabane-companion`, or `COMPANION_NAME`. The settings above apply to it too, ports with `-f compose.companion.yaml -f compose.ports.yaml`.

**On a Docker without root.** A Docker run without root ([Docker's guide](https://docs.docker.com/engine/security/rootless/)) works with either file, given two settings. Its socket isn't at `/var/run/docker.sock`: put its place in `DOCKER_SOCKET`, usually `$XDG_RUNTIME_DIR/docker.sock`. Read `DOCKER_GID` from inside a container given that socket, which is the group the runner meets there; a `stat` of the socket on this machine gives an id the runner is refused with. With `docker` talking to that Docker:

```bash
export DOCKER_SOCKET=$XDG_RUNTIME_DIR/docker.sock
export DOCKER_GID=$(docker run --rm -v "$DOCKER_SOCKET:/var/run/docker.sock" --entrypoint stat \
  ghcr.io/cabane-ai/cabane-companion:0.6.265 -c %g /var/run/docker.sock)
```

Then bring it up with those two set, without the `stat` line above, which would replace the group with a wrong one, or with nothing where `/var/run/docker.sock` doesn't exist. The instance on this machine with a container per turn:

```bash
docker compose -f compose.yaml -f compose.turns.yaml up -d
```

Or a companion alone, paired to an instance elsewhere:

```bash
CABANE_BASE_URL=https://cabane.example.com docker compose -f compose.companion.yaml up -d
docker compose -f compose.companion.yaml logs companion       # the pairing code
```

## Adding tools for agents

Agents work inside the runner image, as the user `node`, not root. Besides Claude Code and Codex it carries git, curl, jq, ripgrep, Node with npm, pnpm and yarn, Python 3 with pip and venv, the GitHub CLI (`gh`), a C compiler and make, zip and unzip, and a headless Chromium for Playwright. What an agent installs outside its home doesn't last: the runner's container is replaced at every upgrade, and a container per turn starts from the image every time.

- **Python packages** go in a virtual environment in the agent's home, `python3 -m venv .venv` then `.venv/bin/pip install …`. Debian's Python refuses `pip install` outside one.
- **The browser** is Chromium's headless shell, the build the image's own Playwright starts headless (`playwright` on the path), at the version the instance's Playwright MCP runs. Playwright MCP starts it with no setting. A launch that asks for the full Chromium (a `channel`, or a window), or a project's Playwright of another version, wants its own build: `npx playwright install chromium` fetches it.
- **What the browser loads.** A page an agent built in a workspace, with its sibling files and its calls to `/api`: an agent in the runner that asks for a page's address is given one at `cabane-pages`, the app's name for pages on the runner's own network, and its browser opens it there. That address works only inside the runner. A page an agent serves itself, in its own container, loads too. With [a container per turn](#each-turn-in-a-container-of-its-own), a host the turn holds a stand-in for (`api.github.com` when `GH_TOKEN` is in `secrets.json`, or a secret's own hosts) fails in the browser with a certificate error, since the browser doesn't trust the egress proxy's certificate authority; `gh`, git, curl and Node do.

**For anything more, build an image of your own** on this release's runner image and name it in `.env`. Keep the user `node` and its home, `/home/node`: the runner and every turn's container run as that user. For example, `runner/Dockerfile` beside the compose files:

```dockerfile
ARG CABANE_RUNNER
FROM ${CABANE_RUNNER}
USER root
RUN apt-get update \
  && apt-get install -y --no-install-recommends postgresql-client \
  && rm -rf /var/lib/apt/lists/*
USER node
```

Build it on this release's runner image, name it in `.env`, and bring the instance up:

```bash
docker build --pull -t cabane-runner-own runner \
  --build-arg CABANE_RUNNER="$(RUNNER_IMAGE= docker compose config --images | grep -m1 companion)"
echo 'RUNNER_IMAGE=cabane-runner-own' >> .env
docker compose up -d
```

The built-in runner, every turn's container and the egress proxy then run your image. The egress proxy always runs the runner's image, since the runner writes what it reads. Take the line out of `.env` and `docker compose up -d` to go back to the release's image.

**Build it again at every upgrade**, on the new release's image, before you bring the instance up: an image built on an older release isn't supported under a newer release's files. Take the files, build, then `docker compose up -d`, which pulls the new release's server image itself. Leave out `docker compose pull`: it can't pull an image that was only ever built on this machine.

```bash
curl -fsSL https://github.com/cabane-ai/cabane-releases/releases/latest/download/cabane.tar.gz | tar -xz --strip-components=1
docker build --pull -t cabane-runner-own runner \
  --build-arg CABANE_RUNNER="$(RUNNER_IMAGE= docker compose config --images | grep -m1 companion)"
docker compose up -d
```

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
