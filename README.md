# tcptarpit - generic layer-4 TCP tarpit for OpenBSD

`tcptarpit` is a small single-process daemon for OpenBSD that traps
abusive TCP clients in a connection that never yields a real answer. It
follows the same pf pattern as OpenBSD's own spamd(8): pf rate rules
overload offending source addresses into a table, and a `rdr-to` rule
diverts their connections to a loopback listener. Like spamd the daemon
stutters by default: incoming data is read and discarded, and a single
filler byte is dribbled back per connection per second, so clients keep
waiting for a response that never properly arrives. Pure silence is
available via `stutter=0`.

The attacker's client sits there waiting, wasting its time and its
connection slots. The daemon is protocol agnostic: it works for SSH
brute forcers as well as HTTP scanners and dir busters.

> This repository is developed on an internal Gitea instance and
> automatically published to GitHub through a push mirror.

## Files

| File                  | Install to / purpose              | Mode   |
|-----------------------|-----------------------------------|--------|
| `tcptarpit.pl`        | `/usr/local/bin/tcptarpit.pl` - the daemon (base perl, no ports) | 0755 |
| `tcptarpit`           | `/etc/rc.d/tcptarpit` - rc.d(8) integration | 0555 |
| `tcptarpit.conf.sample` | `/etc/tcptarpit.conf` - configuration | 0644 |
| `tcptarpit.login.conf` | `/etc/login.conf.d/tcptarpit` - login class | 0644 |
| `tcptarpit.8`         | `/usr/local/man/man8/tcptarpit.8` - mdoc(7) manual page | 0444 |
| `LICENCE`             | ISC licence                       | -      |
| `CHANGES`             | change history (installed under `share/doc/tcptarpit/`) | - |
| `port/`               | OpenBSD port skeleton             | -      |
| `tests/`              | load and resource test suite      | -      |
| `dist/`               | prebuilt package (see Option C)   | -      |

## Requirements

* OpenBSD with pf enabled (the default). Verified on OpenBSD **7.9 and
  8.0** (amd64); the login class packaging requires the
  `/etc/login.conf.d/` mechanism.
* Base system perl (`/usr/bin/perl`). No packages or CPAN modules -
  the daemon uses `IO::Socket::IP` (dual-stack, IPv4 and IPv6) and
  `IO::Select`, both part of the base perl.

## Installation

`rcctl enable tcptarpit` appends the service to `pkg_scripts` in
`rc.conf.local`; at boot /etc/rc runs every `pkg_scripts` entry that is
executable in `/etc/rc.d`.

### Option A: package via the port (recommended)

Building requires an OpenBSD machine with the ports tree (not present
by default). One-time setup:

```sh
cd /tmp
ftp https://cdn.openbsd.org/pub/OpenBSD/$(uname -r)/ports.tar.gz
doas tar -xzf ports.tar.gz -C /usr
```

The port must be built from inside the ports tree: bsd.port.mk derives
PKGPATH from the directory and refuses to build elsewhere. The tree
`/usr/ports/mystuff` is the designated place for local ports:

```sh
git clone https://github.com/oaNg5oog/TCPTarpit.git
mkdir -p /usr/ports/mystuff/net
cp -R TCCTarpit/port /usr/ports/mystuff/net/tcptarpit
cd /usr/ports/mystuff/net/tcptarpit
make package TCPTARPIT_SRCDIR=/root/projects/TCPTarpit
```

`TCPTARPIT_SRCDIR` points the build at the repository files. Or build
and install in one step: `doas make install TCPTARPIT_SRCDIR=...`.

One more one-time step: pkg_create(1) refuses `@newuser`/`@newgroup`
entries whose uid/gid are not in the ports registry, so register the
daemon uid locally (for an official port the id would be claimed with
ports@ instead). This has to be repeated after every ports tree
refresh:

```sh
echo "960 _tcptarpit _tcptarpit net/tcptarpit" \
    >> /usr/ports/infrastructure/db/user.list
```

Locally built packages are unsigned; pkg_add(1) needs an explicit
acknowledgment for them (verified on 7.9 and 8.0). With a stale tgz of
an older release in the package repository `make package` is a silent
no-op on 8.0 - remove the old tgz before rebuilding after a release
upgrade:

```sh
rm /usr/ports/packages/<arch>/all/tcptarpit-*.tgz
PKG_PATH=/usr/ports/packages/<arch>/all pkg_add -D unsigned tcptarpit-1.4.5
```

The package does everything automatically, like other OpenBSD daemon
packages:

* creates the group and user `_tcptarpit` (`@newgroup`/`@newuser`,
  uid/gid 960, login class `tcptarpit` assigned through the loginclass
  field; upgrades get `usermod -L` via `@exec`),
* installs the login class `/etc/login.conf.d/tcptarpit`
  (openfiles 1024/4096) and registers it with cap_mkdb(1),
* installs the rc.d(8) script into `/etc/rc.d/tcptarpit` (`@rcscript`),
* installs `/etc/tcptarpit.conf` from the sample on first install and
  never touches an existing configuration (`@sample`),
* creates `/var/log/tcptarpit.log` (owned by `_tcptarpit`, 0640) and
  `/var/run/tcptarpit/` for the pid file, and appends an idempotent
  newsyslog(8) rotation entry to `/etc/newsyslog.conf`,
* prints the post-installation guide after installation; it stays at
  `/usr/local/share/doc/pkg-readmes/tcptarpit`,
* the rc script runs the daemon as `_tcptarpit` (`daemon_user`) - no
  root privileges at runtime.

Quick check after installation:

```sh
id _tcptarpit
ls -l /etc/rc.d/tcptarpit /etc/tcptarpit.conf /etc/login.conf.d/tcptarpit
rcctl enable tcptarpit && rcctl start tcptarpit
rcctl check tcptarpit
tail -f /var/log/tcptarpit.log   # expect: "generic layer-4 TCP tarpit running ..."
```

### Option B: manual installation

Create the daemon user with its login class first - the rc script
expects the user, and without the class the daemon stops accepting at
the default 128 fd soft limit:

```sh
groupadd -g 960 _tcptarpit
useradd -g _tcptarpit -L tcptarpit -c "tcptarpit daemon" \
    -d /nonexistent -s /sbin/nologin _tcptarpit
install -m 0644 tcptarpit.login.conf /etc/login.conf.d/tcptarpit
cap_mkdb /etc/login.conf.d/tcptarpit
install -d -o _tcptarpit -g _tcptarpit /var/run/tcptarpit
install -o _tcptarpit -g _tcptarpit -m 0640 /dev/null /var/log/tcptarpit.log
echo '/var/log/tcptarpit.log _tcptarpit:_tcptarpit 640 7 250 * Z /var/run/tcptarpit/tcptarpit.pid' >> /etc/newsyslog.conf

install -m 0755 tcptarpit.pl          /usr/local/bin/tcptarpit.pl
install -m 0555 tcptarpit             /etc/rc.d/tcptarpit
install -m 0644 tcptarpit.conf.sample /etc/tcptarpit.conf
install -m 0444 tcptarpit.8           /usr/local/man/man8/tcptarpit.8

rcctl enable tcptarpit
rcctl start  tcptarpit
rcctl check  tcptarpit
```

### Option C: prebuilt package

`dist/tcptarpit-1.4.5.tgz` is the package built and verified on
OpenBSD 8.0/amd64. pkg_add(1) can install it straight from the
repository URL:

```sh
pkg_add -D unsigned \
    https://github.com/oaNg5oog/TCPTarpit/raw/v1.4.5/dist/tcptarpit-1.4.5.tgz
```

Packages are specific to release and architecture - on anything but
OpenBSD 8.0/amd64 build your own via the port (Option A).

## Configuration

The daemon reads `/etc/tcptarpit.conf`. If the file is missing it logs
a warning and continues with built-in defaults. A malformed file
(unknown key, syntax error, invalid value) aborts startup with a
`file:line` message, following the fail-fast convention of OpenBSD
daemons.

| Key                | Default     | Meaning                                          |
|--------------------|-------------|--------------------------------------------------|
| `listen_ip`        | `127.0.0.1` | IPv4 listen address; empty string disables the IPv4 listener |
| `listen_ip6`       | `::1`       | IPv6 listen address; empty string disables the IPv6 listener |
| `listen_port`      | `8024`      | listen port; must match the `rdr-to` rules in pf.conf |
| `cleanup_interval` | `1800`      | seconds between cleanup passes over stale connections |
| `max_age`          | `1800`      | seconds before a held connection is closed with FIN |
| `stutter`          | `1`         | seconds per dribbled filler byte (spamd-style); `0` = pure silence |
| `log_file`         | `/var/log/tcptarpit.log` | empty = stdout (syslog via daemon(8)) |
| `pid_file`         | `/var/run/tcptarpit/tcptarpit.pid` | empty = no pid file |
| `user`             | *(empty)*   | drop privileges to this user after startup (see below) |
| `group`            | *(empty)*   | drop group; empty = primary group of `user` |

At least one listen address must remain set (fail-fast otherwise). A
different configuration file can be passed as the only command line
argument; when overriding the rc flags, keep the script path (see the
comment in `/etc/rc.d/tcptarpit`):

```sh
rcctl set tcptarpit flags "/usr/local/bin/tcptarpit.pl /etc/tcptarpit-test.conf"
```

## Logging

The default is a dedicated log file, `/var/log/tcptarpit.log` - the
syslog route (`/var/log/daemon`) stays clean that way. The package
creates the file with suitable ownership, the run directory for the
pid file and the newsyslog(8) rotation entry (verified: a complete
load test left `/var/log/daemon` byte-for-byte unchanged).

On SIGHUP - sent by newsyslog(8) after rotation - the daemon reopens
its log file. If the file does not exist at that moment it cannot be
recreated under unveil, so the daemon degrades to stdout with one
warning (nothing is silently dropped) and returns to the file on the
next SIGHUP as soon as it exists again.

Setting `log_file` empty switches back to stdout, which daemon(8)
pipes to syslog at `daemon.info`.

## Running unprivileged

Port 8024 needs no root, and the daemon never needs root after
startup. The shipped rc script contains `daemon_user="_tcptarpit"`, so
the daemon starts unprivileged from the beginning. Without the login
class (openfiles 1024/4096) the daemon stops accepting at ~125
connections - found by the load test, fixed by the packaged class.

The in-daemon alternative is the privilege drop via configuration:
`user=_tcptarpit` (optionally `group=`). The daemon opens the listen
sockets, log file and pid file first, then switches uid/gid before
entering the event loop. If it is already running as that user the
drop is a no-op; switching to another user without root aborts
startup.

## Security: pledge(2) and unveil(2)

Like any OpenBSD-conformant daemon, tcptarpit restricts itself after
startup with the OpenBSD kernel security mechanisms, in this order:

1. **unveil(2)** reduces the filesystem view to what the daemon still
   touches: the log file (`wc`) and the pid file plus its directory
   (`cr`/`wc` - perl's unlink() lstat()s the file first, so removal
   needs `r` for the stat and `c` for the delete on the file itself;
   the directory unveil alone is not sufficient). With neither
   `log_file` nor `pid_file` configured, unveils are locked empty: the
   daemon has no filesystem access at all.
2. **pledge(2)** limits the syscalls to `stdio` (implied) and `inet`;
   `wpath cpath` when a log file is configured (reopen after
   rotation), and additionally `rpath` when a pid file is configured
   (perl's unlink lstat, found via ktrace after every shutdown ended
   in a pledge abort). unveil keeps the readable paths limited to the
   log file and the pid directory.

Both steps are logged on every start:

```
[*] filesystem restricted via unveil(2)
[*] pledged to: stdio inet wpath cpath rpath
```

On non-OpenBSD platforms the daemon logs `pledge/unveil unavailable`
and runs without these restrictions.

## pf configuration

Merge this into `/etc/pf.conf` (adjust `ext_if` and the port lists) and
reload with `pfctl -f /etc/pf.conf`:

```pf
ext_if = "em0"

table <bruteforcers> persist
# Optional: seed the table from a file so entries survive a reboot:
#table <bruteforcers> persist file "/etc/bruteforcers"

# Outbound traffic stays stateful - the replies must be able to
# return.  Building a complete ruleset from this fragment without
# this rule silently breaks DNS and every outgoing connection.
pass out on $ext_if proto { tcp, udp, icmp } all keep state

# Never tarpit your own admins - this rule must come first.
table <admins> const { 198.51.100.10 }
pass in quick on $ext_if from <admins>

# Everyone already on the list goes straight into the tarpit.
# Must be listed before the ordinary ssh/http rules below.
pass in quick on $ext_if proto tcp from <bruteforcers> to any port { ssh, http, https } \
    rdr-to 127.0.0.1 port 8024

# SSH watch: more than 3 connections within 30 seconds goes on the list.
pass in on $ext_if proto tcp to any port ssh flags S/SA keep state \
    (max-src-conn-rate 3/30, overload <bruteforcers> flush global)

# Webserver watch: protection against fast HTTP scanners / dir busters.
pass in on $ext_if proto tcp to any port { http, https } flags S/SA keep state \
    (max-src-conn-rate 30/10, overload <bruteforcers> flush global)

# IPv6 (the daemon listens on ::1 as well by default; separate rules):
pass in quick on $ext_if inet6 proto tcp from <bruteforcers> \
    to ($ext_if) port { http, https } rdr-to ::1 port 8024
pass in on $ext_if inet6 proto tcp to ($ext_if) port { http, https } \
    flags S/SA keep state \
    (max-src-conn-rate 30/10, overload <bruteforcers> flush)
```

Rule order matters: the tarpit `pass in quick ... rdr-to` rule must
appear before the plain ssh/http pass rules. `set skip on lo` is not a
problem - translation and state creation happen on `$ext_if`. Because
the daemon listens on loopback only, it is unreachable from the
outside unless pf redirects traffic to it.

## Log messages

The daemon writes these lines to its log file (or syslog in
stdout mode):

| Message                                             | Meaning                                   |
|-----------------------------------------------------|-------------------------------------------|
| `[+] bot trapped: IP:PORT`                          | new connection accepted and held          |
| `[-] bot gave up after N s/min/h/d: IP`             | client closed cleanly (FIN)               |
| `[-] bot aborted after N s/min/h/d: IP (ERROR)`     | client RST or socket/write error          |
| `[-] bot vanished before capture`                   | reset before accept() could read the address; dropped |
| `[*] starting periodic cleanup of stale connections`| cleanup pass started                      |
| `[*] kicking bot after N s/min/h/d hold time: IP:PORT` | daemon timeout after exceeding `max_age` |
| `[*] log file reopened after rotation`              | SIGHUP: logging continues in the new file |

## Operating the blocklist

```sh
pfctl -t bruteforcers -T show              # list trapped addresses
pfctl -t bruteforcers -T delete 203.0.113.7   # unblock a single address
pfctl -t bruteforcers -T flush             # empty the table
```

Table entries live in the running kernel only; with the `file` variant
the table is seeded at load time. To persist runtime additions:

```sh
pfctl -t bruteforcers -T show | tail -n +2 > /etc/bruteforcers
```

## Behaviour and limits

* Held connections receive one filler byte per `stutter` seconds
  (default 1, spamd-style) - never a real response. `stutter=0`
  switches to complete silence. Client sockets are non-blocking: a
  peer that never reads suspends its dribble (EAGAIN) instead of
  blocking the daemon, and the total dribble per connection is capped
  at 32 KiB as a second guard. accept() failures at the fd limit are
  logged once and paced - no CPU spins under connection floods.
* Idle connections are closed after `max_age` seconds at the next
  cleanup pass (effectively between `max_age` and
  `max_age + cleanup_interval`, defaults 30-60 minutes), with a normal
  FIN.
* IPv4 and IPv6 are both enabled by default (127.0.0.1 and ::1); each
  family is switched off individually by leaving `listen_ip` or
  `listen_ip6` empty. IPv6 traffic needs separate `inet6` pf rules
  with `rdr-to ::1`.
* One process, one single-threaded event loop (`IO::Select`). Per
  connection cost: one file descriptor plus a small hash entry.
* Incoming data is drained in 64 KiB chunks and discarded - a flooding
  client costs the daemon almost nothing.

## Packaging notes

The port skeleton in `port/` installs from this repository:
`@newuser`/`@newgroup` create the daemon user with the login class,
`@rcscript` installs the rc.d script, `@sample` handles the
configuration, login class and newsyslog entries, and `pkg/README` is
installed as `/usr/local/share/doc/pkg-readmes/tcptarpit` and shown
after installation. See `Architecture.md` for details and
`tests/README.md` for the load test.

## Verification status

Runtime-verified on a development machine (Linux, perl 5.36) and on
**OpenBSD 7.9 and 8.0** (amd64) test systems:

* **Port build and package lifecycle** (7.9 and 8.0): build via
  `/usr/ports/mystuff`, install, in-place upgrades
  (`1.0 -> 1.1 -> 1.2.x -> 1.3.0 -> 1.4.x`), uninstall matrix
  (plain delete keeps a modified configuration and the user;
  `pkg_delete -c` removes both; the `pkg_scripts` entry survives -
  disable explicitly). Same-version pkg_add is a silent no-op - use
  pkg_delete first or `-r`.
* **Daemon runtime** (7.9 and 8.0): rcctl lifecycle all ok, automatic
  `_tcptarpit` user/group/login class, pledge(2) and unveil(2) active
  (`ps -o pledge` shows the promised set, uid/gid 960), clean
  shutdowns (after the rpath fix), IPv4 and IPv6 listeners by default,
  spamd-style stutter with readable hold durations in every log line.
* **Load and resource suite** (tests/tarpit-loadtest.pl, 8.0): 300
  idle connections (no measurable RSS growth per connection), 100 MiB
  data flood for +1 s CPU, 1500-cycle FIN/RST churn for +1 s CPU,
  100 slowloris connections at +0 s, 450 concurrent connections (459
  fds), full recovery to baseline. Without the login class the daemon
  caps at ~125 connections but survives and recovers.
* **Logging** (8.0): complete load test left `/var/log/daemon`
  byte-for-byte unchanged; everything lands in
  `/var/log/tcptarpit.log`; SIGHUP reopen after rotation works, and a
  missing log file at SIGHUP degrades to stdout with a warning
  instead of losing messages.
* **pf integration** (7.9 and 8.0, httpd on 80, no listener on 443):
  40 established connections within 0.02 s trigger
  `max-src-conn-rate 30/10`, the source lands in `<bruteforcers>`,
  connections to both 80 and 443 are redirected into the tarpit, the
  daemon logs the preserved original source IP, and deleting the
  table entry restores normal service immediately. Operational note:
  the rate limits count connections with a completed TCP handshake -
  SYN-only bursts against a closed port do not trigger the overload.

**Final pre-deployment audit (1.4.2):** the complete daemon code was
re-read end to end before the production release; three edge-case
defects were found and fixed (stale stutter deadline busy-looping the
select with capped connections and large `max_age`; blocking stutter
writes freezing the event loop on full send buffers; unlogged
accept() CPU spin at the fd limit). Full suite passes against the
hardened daemon locally and on OpenBSD 8.0.

**Still open:** IPv6 traffic through pf with a global IPv6 address
(the test VM has none - the inet6 rules are documented but untested
with real traffic), newsyslog(8) rotation over long production
timeframes, and the in-daemon `setuid` branch (the package path runs
unprivileged from the start).

## Uninstall

Installed as a package:

```sh
rcctl stop tcptarpit
rcctl disable tcptarpit
doas pkg_delete tcptarpit          # add -c to also remove _tcptarpit
# optionally remove the marked newsyslog block and the log:
# editor /etc/newsyslog.conf; rm /var/log/tcptarpit.log*
```

Manual installation:

```sh
rcctl stop    tcptarpit
rcctl disable tcptarpit
rm /usr/local/bin/tcptarpit.pl /etc/rc.d/tcptarpit \
   /etc/tcptarpit.conf /etc/login.conf.d/tcptarpit \
   /var/run/tcptarpit/tcptarpit.pid /usr/local/man/man8/tcptarpit.8
userdel _tcptarpit; groupdel _tcptarpit
# remove the tarpit/overload rules from /etc/pf.conf, then:
pfctl -f /etc/pf.conf
```
