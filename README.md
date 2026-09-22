# Postgres Manager

A native macOS menu bar app and GUI for running PostgreSQL locally — so you don't need Docker
for a development database.

Start and stop the server from the menu bar, install Postgres if you don't have it, browse
databases and tables, run SQL, see who's connected, back up and restore a single database, and
give each user read or write access per database without writing a single `GRANT` by hand.

## What it does

| | |
|---|---|
| **Menu bar control** | Start / stop / restart, live status, port, and connected-client count. No Dock icon until you open a window. |
| **Installs Postgres for you** | No server installed? Pick a version (14–18), see the exact `brew install` command, and run it from the app with live output. |
| **Databases and tables** | Databases with sizes and owners; tables with schemas, columns, indexes, sizes and a paged row browser. |
| **SQL editor** | Multiple statements, per-statement timing, real Postgres error messages with hint and position, copy results as CSV. |
| **Users & access** | A users × databases grid. Pick *No Access*, *Read Only*, *Read / Write* or *Owner*, review the generated SQL, apply it in one transaction. |
| **Connected clients** | Live `pg_stat_activity`, with idle-in-transaction highlighted, and cancel/disconnect per client. |
| **Backup & restore** | `pg_dump` with progress, restore into a new or existing database, and the right client version chosen automatically. |
| **Logs** | Live tail of the server log, plus a record of every command the app has run on your behalf. |

## Install

### Option 1 — download

Grab `PostgresManager.dmg` from the [latest release](../../releases/latest), open it, and drag
the app to Applications.

The first launch of a downloaded copy will be blocked, because this app is **ad-hoc signed
rather than notarised** — it is built in public CI with no Apple Developer account and no
signing secrets in this repository. To allow it, right-click the app and choose **Open**, or run:

```sh
xattr -dr com.apple.quarantine "/Applications/PostgresManager.app"
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

Open the app and look for the database icon in your menu bar.

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
make app     # build build/PostgresManager.app
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
- **`PGKit`** holds all the logic and has no UI dependency, so it is testable on its own.
- **Server control** uses `pg_ctl` directly, but detects when `brew services` owns a cluster and
  routes start/stop through `brew` instead — otherwise launchd would immediately undo a stop.
- **Status polling** reads `postmaster.pid` rather than spawning a process, which is what makes a
  3-second refresh cheap. That file is also the authoritative source for the port and socket
  directory a running server actually bound.
- **Queries** go through [PostgresNIO](https://github.com/vapor/postgres-nio) over the Unix
  domain socket. Command-line tools (`initdb`, `pg_ctl`, `pg_dump`, `pg_restore`, `brew`) are used
  only where they genuinely are the interface.
- **Passwords** are stored in the macOS Keychain, bound as query parameters rather than spliced
  into SQL, and passed to CLI tools via a `0600` `PGPASSFILE` — never on a command line, where
  `ps` would show them.

## Privacy and security

- Everything runs locally. The app makes no network requests except `brew` when you ask it to
  install Postgres.
- This repository contains no certificates, keys, or credentials. Builds are ad-hoc signed,
  which requires none.

## Licence

MIT — see [LICENSE](LICENSE).
