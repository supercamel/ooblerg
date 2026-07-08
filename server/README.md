# Ooblerg Repository Server

The repository server builds and serves the public Ooblerg package repository
and website. Static public content is served only from `out/repo`.

## Metrics

The server records request/download metrics in a private append-only JSONL file.
By default, when the server root is `/opt/ooblerg`, metrics are stored here:

```text
/opt/ooblerg/var/metrics/events.jsonl
```

The metrics directory is intentionally outside `out/repo`, because `out/repo`
is public web content. Do not put metrics under `out/repo`.

Each line in `events.jsonl` is one JSON object with:

- UTC timestamp and month.
- HTTP method, path, response status, response byte count, and classified kind.
- Salted SHA-256 hashes for approximate unique user and user-agent counting.

The server does not store raw IP addresses. It uses `X-Forwarded-For` from
nginx when available, combines the client IP with the user-agent, and hashes
that with a local secret stored at:

```text
/opt/ooblerg/var/metrics/secret
```

Keep that secret private. Deleting it rotates the hash salt, which means future
unique-user counts will not line up with old events.

`/healthz` is not recorded. Successful requests are summarized by kind:

- `page`
- `installer`
- `installer_checksum`
- `repo_index`
- `package_manifest`
- `package_artifact`
- `asset`

The report separates total requests from downloads. Downloads are successful
`GET` requests for `installer` and `package_artifact` events.

## Reading Metrics

From the live server root:

```sh
cd /opt/ooblerg
sqgi server/main.nut --metrics-report
```

For a specific month:

```sh
cd /opt/ooblerg
sqgi server/main.nut --metrics-report --metrics-month=2026-06
```

If the metrics directory is customized:

```sh
sqgi server/main.nut --metrics-report --metrics-dir=/path/to/private/metrics
```

Example output:

```text
Ooblerg Metrics
events: /opt/ooblerg/var/metrics/events.jsonl

2026-06: 120 requests, 42 downloads, 35 unique users, 18 download users, 3.1 GiB
  installer: 20 requests, 20 downloads, 18 unique users, 18 download users, 1.4 GiB
  package_artifact: 22 requests, 22 downloads, 8 unique users, 8 download users, 1.7 GiB
  repo_index: 48 requests, 0 downloads, 25 unique users, 0 download users, 3.4 MiB
```

For backup or offline analysis, copy `events.jsonl` and `secret` together.
