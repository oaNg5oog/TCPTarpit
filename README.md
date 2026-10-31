# tcptarpit - generic layer-4 TCP tarpit for OpenBSD

`tcptarpit` is a small single-process daemon for OpenBSD that traps abusive
TCP clients in a connection that never answers. It follows the same pf
pattern as OpenBSD's own spamd(8): pf rate rules overload offending source
addresses into a table, and a `rdr-to` rule diverts their connections to a
loopback listener which accepts them - and then never sends a single byte
back.

The attacker's client sits there waiting for a response that never comes,
wasting its time and its connection slots. The daemon is protocol agnostic:
it works for SSH brute forcers as well as HTTP scanners and dir busters.

## Files

| File                  | Install to                        | Mode | Purpose                            |
|-----------------------|-----------------------------------|------|------------------------------------|
| `tcptarpit.pl`        | `/usr/local/bin/tcptarpit.pl`     | 0755 | the daemon (base perl, no ports)   |
| `tcptarpit`           | `/etc/rc.d/tcptarpit`             | 0555 | rc.d(8) start/stop integration     |
| `tcptarpit.conf.sample` | `/etc/tcptarpit.conf`           | 0644 | configuration (copy and edit)      |
| `tcptarpit.8`         | `/usr/local/man/man8/tcptarpit.8` | 0444 | manual page in mdoc(7) format      |
| `port/`               | -                                 | -    | OpenBSD port skeleton (see below)  |

## Requirements

* OpenBSD with pf enabled (the default).
* Base system perl (`/usr/bin/perl`). No packages or CPAN modules needed -
  the daemon only uses `IO::Socket::INET` and `IO::Select`, both core.

## Installation

### Option A: package via the port (recommended)

Building the package requires an OpenBSD machine with the ports tree
installed (not present by default). One-time setup:

```sh
cd /tmp
ftp https://cdn.openbsd.org/pub/OpenBSD/$(uname -r)/ports.tar.gz
doas tar -xzf ports.tar.gz -C /usr
```

The port must be built from inside the ports tree: bsd.port.mk derives
PKGPATH from the directory and refuses to build elsewhere ("Can't find
... under PORTSDIR_PATH=/usr/ports:/usr/ports/mystuff"). The tree
`/usr/ports/mystuff` is the designated place for local ports:

```sh
git clone https://github.com/oaNg5oog/TCPTarpit.git
mkdir -p /usr/ports/mystuff/net
cp -R TCPTarpit/port /usr/ports/mystuff/net/tcptarpit
cd /usr/ports/mystuff/net/tcptarpit
make package TCPTARPIT_SRCDIR=/root/projects/TCPTarpit
```

`TCPTARPIT_SRCDIR` points the build at the repository files (daemon,
rc script, man page, config sample). Or build and install in one step
with `doas make install TCPTARPIT_SRCDIR=...`.

One more one-time step: pkg_create(1) refuses `@newuser`/`@newgroup`
entries whose uid/gid are not in the ports registry, so register the
daemon uid locally (for an official port, the id would be claimed with
ports@ instead):

```sh
echo "960 _tcptarpit _tcptarpit net/tcptarpit" \
    >> /usr/ports/infrastructure/db/user.list
```

The path of the built `.tgz` is printed at the end, by default
`/usr/ports/packages/<arch>/all/tcptarpit-1.0.tgz`. Locally built
packages are unsigned; since OpenBSD 7.x pkg_add(1) needs an explicit
acknowledgment for them (verified on 7.9):

```sh
pkg_add -D unsigned /usr/ports/packages/<arch>/all/tcptarpit-1.0.tgz
```

The package does everything automatically, like other OpenBSD daemon
packages:

* creates the group and user `_tcptarpit` (`@newgroup`/`@newuser` in
  `port/pkg/PLIST`; uid/gid 960, see the comment there on collisions),
* installs the rc.d(8) script into `/etc/rc.d/tcptarpit` (`@rcscript`),
* installs `/etc/tcptarpit.conf` from the sample on first install and
  leaves an existing configuration untouched (`@sample`),
* the rc script runs the daemon as `_tcptarpit` (`daemon_user`), so no
  root privileges are ever needed at runtime.

`pkg_delete tcptarpit` removes files and configuration again
(configuration only if unchanged); add `-c` to also remove the
`_tcptarpit` user and group.

Quick check after installation:

```sh
id _tcptarpit
ls -l /etc/rc.d/tcptarpit /etc/tcptarpit.conf
rcctl enable tcptarpit && rcctl start tcptarpit
rcctl check tcptarpit
tail -f /var/log/daemon     # expect: "generic layer-4 TCP tarpit running ..."
```

### Option B: manual installation

Create the daemon user first - the rc script expects it:

```sh
groupadd -g 960 _tcptarpit
useradd -g _tcptarpit -c "tcptarpit daemon" \
    -d /nonexistent -s /sbin/nologin _tcptarpit
```

Then install the files:

```sh
install -m 0755 tcptarpit.pl         /usr/local/bin/tcptarpit.pl
install -m 0555 tcptarpit            /etc/rc.d/tcptarpit
install -m 0644 tcptarpit.conf.sample /etc/tcptarpit.conf
install -m 0444 tcptarpit.8          /usr/local/man/man8/tcptarpit.8

rcctl enable tcptarpit
rcctl start  tcptarpit
rcctl check  tcptarpit
```

`rcctl enable` appends `tcptarpit` to `pkg_scripts` in `rc.conf.local`;
at boot /etc/rc runs every `pkg_scripts` entry that is executable in
`/etc/rc.d`. All daemon output goes to syslog at `daemon.info`, i.e.
`/var/log/daemon`, through daemon(8).

## Configuration

The daemon reads `/etc/tcptarpit.conf`. If the file is missing it logs a
warning and continues with built-in defaults. A malformed file (unknown
key, syntax error, invalid value) aborts startup with a `file:line`
message, following the fail-fast convention of OpenBSD daemons.

| Key                | Default     | Meaning                                          |
|--------------------|-------------|--------------------------------------------------|
| `listen_ip`        | `127.0.0.1` | listen address; loopback keeps the tarpit unreachable without pf |
| `listen_port`      | `8024`      | listen port; must match the `rdr-to` rule in pf.conf |
| `cleanup_interval` | `1800`      | seconds between cleanup passes over stale connections |
| `max_age`          | `1800`      | seconds before a held connection is closed with FIN |
| `log_file`         | *(empty)*   | empty = stdout (syslog via daemon(8)); or an absolute path for file logging |
| `pid_file`         | *(empty)*   | optional pid file, e.g. `/var/run/tcptarpit/tcptarpit.pid` |
| `user`             | *(empty)*   | drop privileges to this user after startup (see below) |
| `group`            | *(empty)*   | drop group; empty = primary group of `user` |

A different configuration file can be passed as the only command line
argument, e.g. for tests.  Because the rc script runs the interpreter
with the script path as its first flag (see the comment in
`/etc/rc.d/tcptarpit`), overriding the flags must keep that path:

```sh
rcctl set tcptarpit flags "/usr/local/bin/tcptarpit.pl /etc/tcptarpit-test.conf"
```

## Logging

By default everything is logged to stdout, which daemon(8) pipes to
syslog at `daemon.info` (`/var/log/daemon`).

For a dedicated log file set `log_file=/var/log/tcptarpit.log`. The file
must exist and be writable by the daemon user:

```sh
install -o _tcptarpit -g _tcptarpit -m 0640 /dev/null /var/log/tcptarpit.log
```

Rotation through newsyslog(8): the daemon reopens its log file on
SIGHUP, and newsyslog signals the pid file given in the last column:

```sh
mkdir -p /var/run/tcptarpit && chown _tcptarpit /var/run/tcptarpit
# /etc/newsyslog.conf:
/var/log/tcptarpit.log _tcptarpit:_tcptarpit 640 7 250 * Z /var/run/tcptarpit/tcptarpit.pid
```

With `pid_file` set, the daemon writes its process id at startup and
removes the file on exit.

## Running unprivileged

Port 8024 needs no root, and the daemon never needs root after startup.
The shipped rc script already contains `daemon_user="_tcptarpit"`, so
with the package (or a manual install that created the user as shown
above) the daemon starts unprivileged from the beginning - nothing to
do.

The in-daemon alternative is the privilege drop via configuration: set
`user=_tcptarpit` (optionally `group=`) in `/etc/tcptarpit.conf`. The
daemon opens the listen socket, log file and pid file first, then
switches uid/gid before entering the event loop. If it is already
running as that user the drop is a no-op; switching to another user
without root aborts startup.

## Security: pledge(2) and unveil(2)

Like any OpenBSD-conformant daemon, tcptarpit restricts itself after
startup with the OpenBSD kernel security mechanisms, in this order:

1. **unveil(2)** reduces the filesystem view to the paths the daemon
   still touches after startup: the log file (`wc`, reopen on SIGHUP
   after newsyslog rotation) and the pid file directory (`wc`, unlink
   on exit). With neither `log_file` nor `pid_file` configured, unveils
   are locked immediately and the daemon has no filesystem access at
   all - it is a pure network service.
2. **pledge(2)** limits the available syscalls to `stdio` (implied) and
   `inet` (socket, accept, getpeername). `wpath cpath` are added when a
   log file is configured (reopen with O_CREAT on SIGHUP), `cpath` when
   a pid file is configured (unlink on exit).

Both steps are logged, so a successful restriction is verifiable in
`/var/log/daemon`:

```
[*] filesystem restricted via unveil(2)
[*] pledged to: stdio inet
```

On non-OpenBSD platforms the daemon logs `pledge/unveil unavailable`
instead and runs without these restrictions.

## pf configuration

Merge this into `/etc/pf.conf` (adjust `ext_if` and the port lists to your
setup) and reload with `pfctl -f /etc/pf.conf`:

```pf
ext_if = "em0"

table <bruteforcers> persist
# Optional: seed the table from a file so entries survive a reboot
# (runtime changes live in the kernel only, see below):
#table <bruteforcers> persist file "/etc/bruteforcers"

# Never tarpit your own admins - this rule must come first.
table <admins> const { 198.51.100.10 }
pass in quick on $ext_if from <admins>

# Everyone already on the list is pushed straight into the tarpit.
# Must be listed before the ordinary ssh/http rules below.
pass in quick on $ext_if proto tcp from <bruteforcers> to any port { ssh, http, https } \
    rdr-to 127.0.0.1 port 8024

# SSH watch: more than 3 connections within 30 seconds goes on the list.
pass in on $ext_if proto tcp to any port ssh flags S/SA keep state \
    (max-src-conn-rate 3/30, overload <bruteforcers> flush global)

# Webserver watch: protection against fast HTTP scanners / dir busters.
pass in on $ext_if proto tcp to any port { http, https } flags S/SA keep state \
    (max-src-conn-rate 30/10, overload <bruteforcers> flush global)
```

Rule order matters: the tarpit `pass in quick ... rdr-to` rule must appear
before the plain ssh/http pass rules, otherwise new connections from listed
addresses would match the ordinary rules first. A common
`set skip on lo { ... }` is not a problem - translation and state creation
happen on `$ext_if`, before the packet is handed to the loopback interface.

Because the daemon listens on `127.0.0.1` only, it is unreachable from the
outside unless pf redirects traffic to it.

## Log messages

The daemon logs four kinds of lines to `daemon.info`:

| Message                                             | Meaning                                   |
|-----------------------------------------------------|-------------------------------------------|
| `[+] bot trapped: IP:PORT`                          | new connection accepted and held          |
| `[-] bot gave up after N s/min/h/d: IP`             | client closed cleanly (FIN) after a readable duration in the tarpit |
| `[-] bot aborted after N s/min/h/d: IP (ERROR)`     | client sent RST or hit a socket error after a readable duration |
| `[-] bot vanished before capture`                   | client reset the connection before accept() could read its address; dropped |
| `[*] starting periodic cleanup of stale connections`| cleanup pass started                      |
| `[*] kicking bot after N s/min/h/d hold time: IP:PORT` | daemon timeout: connection closed after exceeding `max_age` |

## Operating the blocklist

```sh
pfctl -t bruteforcers -T show              # list trapped addresses
pfctl -t bruteforcers -T delete 203.0.113.7   # unblock a single address
pfctl -t bruteforcers -T flush             # empty the table
```

Table entries are kept by the running kernel only. With the `file` variant
shown above, the table is seeded from the file at load time; to persist
runtime additions across a reboot, dump the table back:

```sh
pfctl -t bruteforcers -T show | tail -n +2 > /etc/bruteforcers
```

## Behaviour and limits

* The daemon **never sends data** on any trapped connection - that is the
  whole point. Protocol-agnostic on layer 4.
* Idle connections are closed after `max_age` seconds at the next cleanup
  pass, i.e. effectively between `max_age` and
  `max_age + cleanup_interval` seconds (defaults: 30-60 minutes). Closing
  sends a normal FIN.
* IPv4 only (`IO::Socket::INET`), listener on `127.0.0.1:8024` by default.
* One process, one single-threaded event loop (`IO::Select`). Per
  connection cost: one file descriptor plus a small hash entry. The number
  of simultaneously held connections is bounded by the process fd limit.
* Incoming data is drained in 64 KiB chunks and discarded, so a flooding
  client costs the daemon almost nothing while its own window runs full.

## Packaging notes

The repository contains a ready OpenBSD port skeleton in `port/`
(`Makefile`, `pkg/PLIST`, `pkg/DESCR`) that installs the files directly
from this repository: the `@newgroup`/`@newuser` PLIST directives create
`_tcptarpit` automatically during `pkg_add(1)`, `@rcscript` installs the
rc.d script into `/etc/rc.d`, and `@sample` installs
`/etc/tcptarpit.conf` from the packaged sample without touching an
existing configuration. `make package` builds an installable
`tcptarpit-1.0.tgz`. See `Architektur.md` for details.

## Verification status

Runtime-verified on a development machine (Linux, perl 5.36): listen and
accept, tarpit silence, FIN and RST detection, parallel connections,
cleanup kick including real socket close and fd reclaim, configuration
parsing (defaults, valid overrides, fail-fast on errors), file logging
with SIGHUP reopen after rotation, pid file write/remove on TERM, and
privilege-drop guard cases (no-op as same user, abort when switching to
another user without root, abort on unknown user). CPU cost of a 1 MB
flood burst: ~0 s (the previous 1-byte-read variant needed ~11 s CPU per
MB). See `Architektur.md` for the measurements.

**Verified on OpenBSD 7.9 (amd64) test system:** complete package build
via `/usr/ports/mystuff` + `make package`, `pkg_add -D unsigned`,
automatic `_tcptarpit` user/group creation (uid/gid 960, confirmed in
`/var/log/messages`), file placement incl. `/etc/rc.d/tcptarpit` and
`/etc/tcptarpit.conf` via `@sample`, the full rcctl lifecycle
(enable/start/check/restart/stop - all `(ok)`), `daemon_logger` output
in `/var/log/daemon`, pledge(2) and unveil(2) active (`ps -o pledge`
shows `stdio,inet`, uid/gid 960) and a live tarpit catch with FIN
detection (`[+] bot trapped` / `[-] bot gave up`).

Package update verified as well: `pkg_add -D unsigned <file>` upgrades
in place (`tcctarpit-1.0->1.1: ok`; the `-u` form expects a package
name plus PKG_PATH, not a file path), the installed package ships
`share/doc/tcptarpit/CHANGES`, and an admin-modified
`/etc/tcptarpit.conf` survives reinstallation (verified with
`pkg_add -r`).

pf interaction verified end to end with httpd(8) on port 80 and no
listener on 443: 40 established connections within 0.02 s trigger
`max-src-conn-rate 30/10`, the source lands in `<bruteforcers>`
(`pfctl -t bruteforcers -T show`), subsequent connections to **both**
80 and 443 are redirected into the tarpit (HTTP request times out
silently; 443 changes from "refused" to "connected, then silence"),
`/var/log/daemon` shows `[+] bot trapped: <real.ip>` and
`[-] bot gave up after N s: <real.ip>` with the preserved original
source address, and `pfctl -t bruteforcers -T delete` restores normal
service immediately. Note for operations: the rate limits count
connections with a completed TCP handshake (pf.conf(5)) - bursts of
SYNs against a closed port create states but do not trigger the
overload.

**Still open:** newsyslog(8) rotation with `log_file`/`pid_file` in
production, and the in-daemon `setuid` branch (the package path runs
unprivileged from the start).

## Uninstall

Installed as a package:

```sh
rcctl stop tcptarpit
doas pkg_delete tcptarpit          # add -c to also remove _tcptarpit
```

Manual installation:

```sh
rcctl stop    tcptarpit
rcctl disable tcptarpit
rm /usr/local/bin/tcptarpit.pl /etc/rc.d/tcptarpit \
   /etc/tcptarpit.conf /usr/local/man/man8/tcptarpit.8
userdel _tcptarpit; groupdel _tcptarpit
# remove the tarpit/overload rules from /etc/pf.conf, then:
pfctl -f /etc/pf.conf
```
