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

## Requirements

* OpenBSD with pf enabled (the default).
* Base system perl (`/usr/bin/perl`). No packages or CPAN modules needed -
  the daemon only uses `IO::Socket::INET` and `IO::Select`, both core.

## Installation

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
argument, e.g. for tests:

```sh
rcctl set tcptarpit flags /etc/tcptarpit-test.conf
```

## Logging

By default everything is logged to stdout, which daemon(8) pipes to
syslog at `daemon.info` (`/var/log/daemon`).

For a dedicated log file set `log_file=/var/log/tcptarpit.log`. The file
must exist and be writable by the daemon user:

```sh
install -o _tarpit -g _tarpit -m 0640 /dev/null /var/log/tcptarpit.log
```

Rotation through newsyslog(8): the daemon reopens its log file on
SIGHUP, and newsyslog signals the pid file given in the last column:

```sh
mkdir -p /var/run/tcptarpit && chown _tarpit /var/run/tcptarpit
# /etc/newsyslog.conf:
/var/log/tcptarpit.log _tarpit:_tarpit 640 7 250 * Z /var/run/tcptarpit/tcptarpit.pid
```

With `pid_file` set, the daemon writes its process id at startup and
removes the file on exit.

## Running unprivileged

Port 8024 needs no root. Two supported ways, use either:

1. **rc.subr `daemon_user`** (recommended): uncomment
   `daemon_user="_tarpit"` in `/etc/rc.d/tcptarpit`. The daemon starts
   unprivileged from the beginning.

2. **In-daemon privilege drop**: set `user=_tarpit` (optionally
   `group=`) in `/etc/tcptarpit.conf`. The daemon opens the listen
   socket, log file and pid file first, then switches uid/gid before
   entering the event loop. If it is already running as that user the
   drop is a no-op; switching to another user without root aborts
   startup.

Create the dedicated user once:

```sh
useradd -c "tcptarpit daemon" -d /nonexistent -s /sbin/nologin _tarpit
```

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
| `[-] bot gave up: IP`                               | client closed cleanly (FIN), socket closed |
| `[-] bot aborted: IP (ERROR)`                       | client sent RST or socket error, socket closed |
| `[-] bot vanished before capture`                   | client reset the connection before accept() could read its address; dropped |
| `[*] starting periodic cleanup of stale connections`| cleanup pass started                      |
| `[*] kicking bot after N s hold time: IP:PORT`      | daemon timeout: connection closed after exceeding `max_age` |

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

The repository is laid out for a later OpenBSD port: mdoc(7) manual page,
configuration shipped as `.sample` (ports must not overwrite files in
`/etc`), rc.d script in `/etc/rc.d` enabled through `pkg_scripts`, daemon
binary under `/usr/local/bin`.

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

**Not yet verified on OpenBSD hardware:** the actual root-to-user
`setuid` drop (requires starting as root), the rc.d lifecycle
(`rcctl start/stop/check/status`), the `daemon_logger` path into
`/var/log/daemon`, newsyslog(8) rotation in production, and the pf
table/`rdr-to` interaction. Verify these on the target system after
installation - see *Installation* and `Architektur.md` for the expected
results.

## Uninstall

```sh
rcctl stop    tcptarpit
rcctl disable tcptarpit
rm /usr/local/bin/tcptarpit.pl /etc/rc.d/tcptarpit \
   /etc/tcptarpit.conf /usr/local/man/man8/tcptarpit.8
# remove the tarpit/overload rules from /etc/pf.conf, then:
pfctl -f /etc/pf.conf
```
