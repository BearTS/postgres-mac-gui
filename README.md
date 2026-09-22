# Dev Services

A native macOS menu bar app for running **PostgreSQL**, **HashiCorp Vault** and **Apache Kafka**
locally — so you don't need Docker for a development stack.

Start and stop each service from the menu bar, install anything you're missing, and manage the
parts that actually matter: databases and per-user access for Postgres, secrets and dev tokens
for Vault, topics and messages for Kafka. Every service can be started, stopped, reset and wiped.

## What it does

### PostgreSQL

| | |
|---|---|
| **Installs it for you** | No server? Pick a version (14–18), see the exact `brew install` command, and run it from the app with live output. |
| **Databases and tables** | Databases with sizes and owners; tables with schemas, columns, indexes, sizes and a paged row browser. |
| **SQL editor** | Multiple statements, per-statement timing, real Postgres errors with hint and position, copy results as CSV. |
| **Users & access** | A users × databases grid. Pick *No Access*, *Read Only*, *Read / Write* or *Owner*, review the generated SQL, apply it in one transaction. |
| **Connected clients** | Live `pg_stat_activity`, idle-in-transaction highlighted, cancel or disconnect any client. |
| **Backup & restore** | `pg_dump` with progress, restore into a new or existing database, correct client version chosen automatically. |

### Vault

| | |
|---|---|
| **Dev or persistent** | Dev mode starts unsealed with a root token you choose and keeps nothing on disk. Persistent mode is file-backed, initialised and unsealed by the app, with keys in your Keychain. |
| **Secrets** | Vault's own web UI, embedded, already signed in with your token — so policies, auth methods and leases are all there, not just key/value. |
| **Reset** | Stop and erase the whole server in one action. |

### Kafka

| | |
|---|---|
| **Sets itself up** | Kafka 4 is KRaft-only, so storage must be formatted with a cluster ID before the broker will start. The app does that for you. |
| **Topics** | Create, list, describe and delete, with internal topics hidden by default. |
| **Messages** | Browse from the beginning or tail only new ones, with JSON payloads pretty-printed. Produce messages from the app too. |
| **Reset** | Stop the broker and delete every topic and message. |

Each service also has a **live log viewer**, and the app records every command it runs on your
behalf so nothing it does to your machine is hidden.

## Install

### Option 1 — download

Grab `DevServices.dmg` from the [latest release](../../releases/latest), open it, and drag
the app to Applications.

The first launch of a downloaded copy will be blocked, because this app is **ad-hoc signed
rather than notarised** — it is built in public CI with no Apple Developer account and no
signing secrets in this repository. To allow it, right-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/DevServices.app"
```

### Option 2 — build it yourself

This avoids the Gatekeeper prompt entirely, since apps you build locally are never quarantined.

```sh
git clone https://github.com/BearTS/postgres-mac-gui.git
cd postgres-mac-gui
./install.sh
```

That builds the app and copies it to `/Applications`. Requirements: macOS 14.4 or newer and the
Swift toolchain — **Xcode is not required**, the Command Line Tools are enough:

```sh
xcode-select --install
```

## Usage

Open the app and look for the stacked-squares icon in your menu bar. Each service has its own
section in the sidebar with its own Overview, and its own start/stop in the menu bar.

- **No Postgres yet?** The window opens on a setup screen. Choose a version, and either copy the
  `brew install` command into your own terminal or press **Run for me**.
- **After installing**, press **Create cluster and start**. This runs `initdb` with you as the
  superuser and trusted local socket authentication, so the app — and a plain `psql` — connect
  with no password.
- From there the sidebar covers databases, tables, SQL, users, connections, backups and logs.

### Giving an app its own user

1. **Users & Access → New User**, with a password.
2. In the grid, set that user to **Read / Write** on the database it needs.
3. Review the SQL it will run, and apply.
4. Copy a connection string from **Databases → Copy**, and put your password in it.

What that actually does under the hood: the app creates `NOLOGIN` group roles per database
(`pgm_<db>_ro`, `pgm_<db>_rw`, `pgm_<db>_owner`), grants privileges to *those*, and then makes
your user a member of one. Levels become one `GRANT`/`REVOKE` pair instead of privileges
scattered across every table, and `ALTER DEFAULT PRIVILEGES` keeps them applying to tables you
create later.

> **One thing worth knowing.** By default, every Postgres role can connect to every database,
> because `PUBLIC` holds `CONNECT`. Until you use **Lock database**, setting someone to *No
> Access* does not actually stop them connecting. The app says so rather than pretending
> otherwise, and shows you who would lose access before you lock it.

## Building

```sh
make app     # build build/DevServices.app
make run     # build and launch
make dmg     # build a drag-to-Applications disk image
make test    # run the test suite
make icon    # regenerate the app icon
make install # build and install to /Applications
```

The app icon is generated from code (`Scripts/make-icon.swift`) rather than committed as an
opaque binary, so you can see exactly what ships in the bundle.

### Notes on building without Xcode

This project is deliberately buildable with only the Command Line Tools. Three things that
requires, in case you hit them elsewhere:

- **`@State` is unavailable.** It is macro-backed in recent SDKs and its macro plugin ships only
  with Xcode. View-local state here uses small `ObservableObject` classes with `@StateObject`;
  `@Environment`, `@Bindable` and `@Observable` all work fine.
- **XCTest is unavailable.** There is no `XCTest.framework` in the Command Line Tools, so all
  tests use swift-testing.
- **swift-testing needs help to run.** Its macro plugin and `Testing.framework` are not on the
  default search paths. `Scripts/test.sh` adds them when it detects a Command-Line-Tools-only
  setup, and skips that when Xcode is present — which is why CI and local builds share one script.

## How it works

- **Swift 6 + SwiftUI**, built with SwiftPM; the `.app` bundle is assembled by a shell script.
- **`ServiceKit`** holds all the logic with no UI dependency, so it is testable on its own.
- **Postgres** is controlled with `pg_ctl`, but the app detects when `brew services` owns a
  cluster and routes start/stop through `brew` instead — otherwise launchd would immediately
  undo a stop. Status comes from reading `postmaster.pid` rather than spawning a process.
- **Vault and Kafka do not daemonise**, so the app supervises them itself: it spawns the process,
  records its PID, redirects output to a log, and finds it again on the next launch. A running
  server deliberately outlives the app that started it.
- **Postgres queries** go through [PostgresNIO](https://github.com/vapor/postgres-nio) over the
  Unix domain socket. **Vault** uses its HTTP API through `URLSession` — no dependency needed.
  **Kafka** splits the difference: topic administration shells out to Kafka's own CLI (rare, so
  JVM startup does not matter), while reading and producing messages uses
  [swift-kafka-client](https://github.com/swift-server/swift-kafka-client), which vendors
  librdkafka — so browsing a topic is instant instead of spinning up a JVM per refresh.
- **Passwords and tokens** are stored in the macOS Keychain, bound as query parameters rather
  than spliced into SQL, and passed to CLI tools via a `0600` `PGPASSFILE` — never on a command
  line, where `ps` would show them.

### A note on the Kafka dependency

`swift-kafka-client` is pre-1.0 and pinned to an exact alpha, because an alpha is free to break
its API between releases. It is the only native Swift Kafka client, and it vendors librdkafka, so
it adds no Homebrew package. Topic administration deliberately does *not* use it: its admin API
is only exposed under a `ForTesting` module.

## Privacy and security

- Everything runs locally. The app makes no network requests except `brew` when you ask it to
  install Postgres.
- This repository contains no certificates, keys, or credentials. Builds are ad-hoc signed,
  which requires none.

## Licence

MIT — see [LICENSE](LICENSE).
