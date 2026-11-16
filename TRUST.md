# What running Cabane yourself promises

_A stub — the seed of a fuller trust page. Three promises an instance is built to keep._

**Never-brick.** Cabane on your box does not depend on Cabane the company to keep working. There's no license check, no activation server, no remote kill switch, and no expiry. If we disappeared tomorrow, the copy on your machine keeps running exactly as it does today — it's your code, your database, your files, on your disk.

**No phone-home unless you turn it on.** Out of the box the app makes no outbound calls of its own: no telemetry, no analytics, no license or update pings. If you set a telemetry destination, the app sends operational data there and nowhere else. It never sends the content of your files or conversations. The full list of what is sent is below.

**Export-everything.** Your data is in open, ordinary forms you can walk away with at any time. Files are plain files on a disk volume (`cabane_storage`); everything else is rows in a standard Postgres database (`cabane_db`) you can `pg_dump`. The secrets your instance made for itself are two small files on a third volume (`cabane_secrets`). There's no proprietary blob store and no format you can't read without us. Back up the three volumes and you've backed up your whole Cabane.

## Telemetry, if you turn it on

Nothing below is sent unless `CABANE_TELEMETRY_ENDPOINT` is set. With it unset the app starts no exporter and opens no connection for telemetry. The _only_ other traffic that leaves your box is your own agent's calls to whatever model provider you pointed it at.

Set it, and the app sends to that one address, over OpenTelemetry's protocol (OTLP over HTTP, JSON). Any OpenTelemetry collector, or a backend that accepts OTLP, can receive it. `CABANE_TELEMETRY_TOKEN`, if set, is sent as `Authorization: Bearer <token>`. Unset the endpoint and restart, and the box is silent again.

You choose one of two levels with `CABANE_TELEMETRY_LEVEL`:

- **`safe`**, the default: only the fields marked _safe_ below. Meant for sending to someone else, us included.
- **`full`**: every field below. Meant for your own backend.

Every record carries this install's id, the app version and a timestamp. The install id is a random id made the first time telemetry is on and kept in the database, or `CABANE_TELEMETRY_INSTALL_ID` if you set one. It means nothing outside your install.

**Request completed**, one per HTTP request the app serves:

| Field                                                                                                                                     | Level     |
| ----------------------------------------------------------------------------------------------------------------------------------------- | --------- |
| method; route with every value replaced by `:value` (`/api/workspaces/:value/files`); status class (`2xx`); duration; time in the handler | safe      |
| how the request authenticated (cookie, token…) and the kind of credential                                                                 | safe      |
| workspace id, person id, agent id, on-behalf-of person id                                                                                 | safe      |
| credential id (the row id, never the token); client IP address                                                                            | full only |

**Runtime**, a measurement once a minute, which is also the heartbeat — an install that stops sending it has stopped:

| Field                                                                                     | Level |
| ----------------------------------------------------------------------------------------- | ----- |
| process memory in use, heap in use, event loop delay (mean and 99th percentile), uptime   | safe  |
| requests open right now; database connections in use, pool size, requests waiting for one | safe  |

**Server errors**, one per request that failed with an error the app did not handle:

| Field                                                                                   | Level     |
| --------------------------------------------------------------------------------------- | --------- |
| the error's type; its stack frames; method; route with every value replaced by `:value` | safe      |
| the error's message                                                                     | full only |

**Browser errors**, one per error the web app catches and reports:

| Field                                                                                         | Level     |
| --------------------------------------------------------------------------------------------- | --------- |
| stack frames; the component stack; which part of the app caught it; the error's id; person id | safe      |
| the error's message; the page's URL; the browser's user agent                                 | full only |

A stack is sent as its frames only: each names a function and a position in the app's own code, including the file path it runs from on your server. The message the stack repeats is cut out first, however many lines it runs to; where it can't be found whole, no frames are sent.

**Stream reconnected**, each time a browser's live connection to the app had to reconnect: which stream (a person's or a workspace's) and the person id, at the safe level.

**Log lines**, every line the app logs at info and above: its level, its name, its fixed message text and its listed fields. Ids, counts, durations, status codes and fixed reason codes are safe. A few fields are full only: an error's message, a storage object key, the storage directory you configured, the host of a service someone connected, a request id a caller chose, an origin that was refused. A line carrying a field the list doesn't know is not sent at the safe level at all.

**Turn finished**, one per agent turn, when it ends:

| Field                                                                                                                       | Level |
| --------------------------------------------------------------------------------------------------------------------------- | ----- |
| turn id, agent id, workspace id, conversation id, connector id                                                              | safe  |
| model id and runtime (`claude-code`, `codex`…)                                                                              | safe  |
| input, output, cache-read and cache-creation tokens; context size and window; duration                                      | safe  |
| outcome (`settled`, `failed`, `stopped`…), the failure's kind from a fixed list (`rate_limited`…), fresh or resumed session | safe  |

A turn's tokens are sent once. If the device had reported them by the time the turn ended — however it ended, a Stop included — they ride here. If they arrive afterwards, this record carries none, and they follow in a **Turn usage** record:

| Field                                                                        | Level |
| ---------------------------------------------------------------------------- | ----- |
| turn id, agent id, workspace id, conversation id, connector id, model id     | safe  |
| input, output, cache-read and cache-creation tokens; context size and window | safe  |

**Tool call finished**, one per operation an agent runs on the workspace:

| Field                                                                                             | Level |
| ------------------------------------------------------------------------------------------------- | ----- |
| agent id, workspace id, turn id                                                                   | safe  |
| which tool and operation (`files.read`), whether it succeeded, the error's kind from a fixed list | safe  |
| duration, size of the result in bytes, how many operations the call carried                       | safe  |

Never the operation's arguments or its result. A name the agent made up that matches no operation is not sent.

**Dispatch failed**, one per wake that never became a turn:

| Field                                                                                            | Level |
| ------------------------------------------------------------------------------------------------ | ----- |
| agent id, workspace id, and why, from a fixed list (`no_device`, `no_response`, `auth_expired`…) | safe  |

**Profiles**, who a person or a workspace is: one when an account signs up or is renamed, one when a workspace is created, renamed or given a new address, and once a day a fresh one for every account and workspace, marked with that day, followed by a **Profile sweep** record counting them:

| Field                                                                                                                | Level     |
| -------------------------------------------------------------------------------------------------------------------- | --------- |
| person id and when they signed up; workspace id, when it was created and its owner's person id; the day of the sweep | safe      |
| how many people and workspaces a sweep sent                                                                          | safe      |
| a person's account name and email; a workspace's name and its address (slug)                                         | full only |

Never a person's name inside a workspace, or the name of anything in one.

At either level nothing is sent that is not on the list. At the safe level that means no names, emails, file names, titles, message text, paths inside a workspace, URLs or error messages. At the full level three kinds of field can still carry them, which is why they are full only: an error's message, which is text built when it happened, a browser's page URL, and a profile's names and email. The list is enforced in code (`apps/api/src/telemetry/telemetry.ts`, and `telemetry-logs.ts` beside it for every log line by name); a field that is not on it cannot be logged or sent.

_Planned next: a one-command backup/restore + upgrade flow, and the public-URL / multi-user setup with rendered pages isolated on their own origin._
