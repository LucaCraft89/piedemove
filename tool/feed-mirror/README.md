# GTT feed mirror

A tiny, optional container that keeps a fresh copy of GTT's GTFS export and
hands it to PiedeMove's CI. MIT, like the rest of the repo. The app itself
never uses it.

## Why it exists

PiedeMove's CI rebuilds the timetable index and the line geometry from GTT's
GTFS zip (`https://www.gtt.to.it/open_data/gtt_gtfs.zip`). Since late
October 2026 GTT's server silently drops connections from GitHub's runners
(the TCP handshake never completes, so the job just times out; Geofabrik and
github.com answer from the same runner). The Comune di Torino's open-data
portal, which lists the same feed, drops them too. Phones in Italy are not
affected, so the app still downloads the feed directly.

The result without a fix: the daily `lines` workflow and the timetable step of
`ci` fail, and the line geometry stops following GTT's exports.

The mirror runs on a machine with an ordinary Italian address. It fetches the
zip politely (a few times a day, `If-Modified-Since`, an honest `User-Agent`),
keeps the last good copy, and serves it to CI only, behind a secret token.

What it is **not**: not a VPN, not a general proxy, not a public re-host.
There is no route into your network from CI; the worst a leaked token allows
is downloading one public file. It serves a single path and refuses
everything else.

## What runs

| container | image | job |
|---|---|---|
| `fetch` | `alpine` | every `REFRESH_HOURS` (6) downloads the zip; checks it looks like a real zip; swaps it in atomically; on any failure keeps the old copy |
| `web` | `nginx` | `GET /gtt_gtfs.zip` with `Authorization: Bearer <token>`; `/healthz` for uptime checks; everything else 404 |

Nothing is built; both are stock images and the config is in this folder.

## Set it up

You need a Docker host with an Italian IP and a reverse proxy that terminates
TLS (the author uses NPMplus).

1. On the docker host:

   ```bash
   git clone https://github.com/LucaCraft89/piedemove.git
   cd piedemove/tool/feed-mirror
   cp .env.example .env
   openssl rand -hex 32        # paste the result as FEED_TOKEN in .env
   docker compose up -d
   docker compose logs fetch   # expect "updated: <n> bytes"
   ```

   The web port binds to `127.0.0.1:8080` by default. If the reverse proxy runs
   on another machine, set `BIND` in `.env` to the docker host's LAN address.
   Do not publish this port straight to the internet.

2. In the reverse proxy (NPMplus), add a proxy host, for example
   `feed.example.org`, forwarding to `http://<docker-host>:8080`, with a
   certificate. Useful extras: rate limiting, and an access list that denies
   everything except `GET /gtt_gtfs.zip` if your proxy can; GitHub's runner
   addresses change too often to allow-list by IP, so the token is the gate.

3. Check from any machine (the token never goes in a URL):

   ```bash
   curl -sS -o /dev/null -w "%{http_code}\n" https://feed.example.org/gtt_gtfs.zip
   curl -sS -o /dev/null -w "%{http_code} %{size_download}\n" \
     -H "Authorization: Bearer $FEED_TOKEN" https://feed.example.org/gtt_gtfs.zip
   ```

   The first prints `401`, the second `200` and a size of several MB.

4. In the GitHub repo, *Settings, Secrets and variables, Actions*, add two
   repository secrets:

   | name | value |
   |---|---|
   | `GTT_MIRROR_URL` | `https://feed.example.org/gtt_gtfs.zip` |
   | `FEED_TOKEN` (or `GTT_MIRROR_TOKEN`) | the `FEED_TOKEN` from `.env` |

   Then run the `lines` workflow once by hand (*Actions, lines, Run workflow*).

Rotate the token any time: change `.env`, `docker compose up -d`, update the
GitHub secret.

## How CI uses it

`tool/build_index.dart` reads `PIEDEMOVE_GTT_ZIP_URL` and
`PIEDEMOVE_GTT_ZIP_TOKEN`. If the URL is unset it downloads from GTT as
before, so local builds are unchanged. The token is sent only to the mirror,
never to GTT or any other host, and is never printed.

If the secrets are set and the mirror fails, the run fails (that means the
mirror is broken and you want to know). If they are not set and GTT is
unreachable, the `lines` workflow ends with a warning instead of a red run.

## Licence note

GTT publishes the data under its own licence
(<https://www.gtt.to.it/gtt_gtfs_license.html>): non-commercial, with
attribution. This mirror is a private cache for the project's own build. It is
token-protected and not offered to the public. Keep it that way, and keep
`NOTICE.md` in step with whatever the licence says.
