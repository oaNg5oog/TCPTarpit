# tcptarpit - Architecture

This document describes the design of tcptarpit, a generic layer-4 TCP
tarpit for OpenBSD/pf, and records the decisions and measurements behind
it. The operating manual for administrators lives in `README.md` and
`tcptarpit.8`.

## Overview

tcptarpit consists of three components: a pf ruleset on the firewall, a
single-process perl daemon on loopback, and an rc.d(8) wrapper that starts
it at boot.

```
                        Internet
                           |  abusive + normal clients
                           v
              +---------------------------+
              |  pf on ext_if             |
              |  1. <admins> pass quick   |  (exempt trusted sources)
              |  2. <bruteforcers>        |
              |     pass quick rdr-to     |-----> ssh/http/https never
              |     127.0.0.1:8024        |       reached for listed
              |  3. max-src-conn-rate     |       addresses
              |     overload <bruteforcers>
              +------------+--------------+
                           |  dst rewritten to 127.0.0.1:8024,
                           |  source address preserved
                           v
              +---------------------------+
              |  tcptarpit.pl             |
              |  IO::Select event loop    |  accepts, never answers,
              |  /etc/tcptarpit.conf      |  drains + discards data
              +------------+--------------+
                           |  stdout/stderr
                           v
              daemon(8) -l daemon.info -> syslogd(8) -> /var/log/daemon
```

The pattern is the same one OpenBSD uses for spamd(8): rate-based
overload into a persistent pf table, then `rdr-to` to a loopback
listener. Because `rdr-to` rewrites only the destination, the daemon
still sees the real peer address, which is what it logs.

## Deployment layout (OpenBSD conventions)

| Repository file        | Target                            | Note |
|------------------------|-----------------------------------|------|
| `tcptarpit.pl`         | `/usr/local/bin/tcptarpit.pl`     | interpreter daemon, shebang `/usr/bin/perl` (base system perl) |
| `tcptarpit`            | `/etc/rc.d/tcptarpit`             | daemon control scripts live in `/etc/rc.d`; packages(7) installs squid/mariadb scripts there as well |
| `tcptarpit.conf.sample`| `/etc/tcptarpit.conf`             | packages ship `.sample`; the admin copies it, existing files in `/etc` are never overwritten |
| `tcptarpit.8`          | `/usr/local/man/man8/tcptarpit.8` | mdoc(7) source, ready for a future port |

Boot integration: `rcctl enable tcptarpit` appends the service to
`pkg_scripts` in `rc.conf.local` (rcctl(8)). At boot, `/etc/rc` runs
every `pkg_scripts` entry that is executable in `/etc/rc.d`:

```sh
for _daemon in $pkg_scripts; do
        if [[ -x /etc/rc.d/$_daemon ]]; then
                start_daemon $_daemon
```

This makes `/etc/rc.d` the correct location for third-party daemon
scripts on OpenBSD. (`/usr/local/etc/rc.d` plus per-service `*_enable`
variables is the FreeBSD mechanism, not OpenBSD.)

## Configuration layer

`tcptarpit.pl` takes an optional config file argument (default
`/etc/tcptarpit.conf`):

1. Built-in defaults are defined for all eight keys (`listen_ip`,
   `listen_port`, `cleanup_interval`, `max_age`, `log_file`,
   `pid_file`, `user`, `group`).
2. If the file exists, every `key=value` line overrides a default;
   comments (`#`) and blank lines are ignored.
3. Unknown keys, lines without `=`, and values that fail validation
   (IPv4 address, port range, positive intervals, absolute paths,
   existing user/group) abort the daemon with a `file:line` message.
   Failing fast on broken configuration follows the convention of
   OpenBSD daemons.
4. If the file is absent, the daemon logs a warning and runs on
   defaults, so a bare installation still works.

Only core perl is used - the parser is ~25 lines, no Config:: modules
from CPAN, which keeps the "base system perl only" requirement intact.

## Process and connection model

One process, one single-threaded event loop around `IO::Select`. This is
sufficient because the daemon's entire job is to hold sockets open and
stay silent; there is no per-connection work that could justify threads
or preforking.

State per connection:

```perl
%connections = (
    "GLOB(0x...)" => {          # key: stringified socket handle
        fh         => $client,  # the real handle (see "The each() trap")
        ip         => "...",
        port       => "...",
        start_time => time(),
    },
);
```

Connection lifecycle:

| Phase   | Trigger                          | Behaviour |
|---------|----------------------------------|-----------|
| accept  | readable listen socket           | socket added to selector and `%connections`, `[+] bot trapped` logged |
| drop    | `peerhost()`/`peerport()` undef at accept | client reset before accept() could read its address - `[-] bot vanished before capture`, socket closed, never registered |
| hold    | client sends data                | read in 64 KiB chunks, discarded, no answer ever |
| exit    | `sysread` returns 0              | client sent FIN - `[-] bot gave up`, socket closed, state removed |
| exit    | `sysread` returns undef          | client sent RST / socket error - `[-] bot aborted: IP (ERROR)`, same cleanup path |
| exit    | age >= `max_age` at cleanup pass | `[*] kicking bot after N s hold time`, daemon closes with FIN, state removed |

The three `[-]`/`[*]` exit messages are deliberately distinct so the log
shows *why* a connection ended: the client closing cleanly, the client
resetting (with the OS error string), or the daemon-side hold-time
timeout. Daemon-side timeouts appear only in the cleanup pass, never in
the read path.

Timing semantics: the cleanup check runs after each return of
`can_read(10)`. Passive connections generate no events, so a cleanup
pass can be delayed by up to 10 s (the select timeout). With the default
1800 s interval this is irrelevant, but it is documented for
completeness. Effective hold time is therefore between `max_age` and
`max_age + cleanup_interval` seconds.

Resource bounds: one file descriptor and one hash entry per connection;
no payload is ever stored. Kicked and closed connections really release
their descriptor (verified), so the fd count tracks active connections
and the only limit is the process fd limit.

## Design decisions and their evidence

**64 KiB drain reads instead of 1-byte reads.**
The original variant read 1 byte per readable event to "check the
status". Measured: draining 1 MB of client data cost ~11 s of daemon CPU
at 100 % of one core, and EOF detection after a burst was delayed by
11-13 s. With 64 KiB chunks the same burst costs ~0 s CPU and EOF is
detected immediately. The tarpit effect is unchanged: the daemon still
never answers, and the client's window runs full between reads.

**The real handle is stored in the connection record.**
Hash keys in perl are strings; `$connections{$client}` stringifies the
glob. `each %connections` therefore yields *string* keys, not handles.
In the original cleanup loop `close($fh)` and `$selector->remove($fh)`
were called on such a string, and both fail *silently* (verified:
`close("GLOB(0x...)")` leaves `$! = "Bad file descriptor"` without
dying; `IO::Select::remove` on a string is a no-op while the count stays
at 1). Consequences measured before the fix: kicked connections never
received a FIN and stayed open at the OS level (fd leak - fatal for a
daemon whose entire purpose is to hold connections until the fd limit),
and the sockets remained in the select set, producing later events with
`Use of uninitialized value` warnings once the bot disconnected on its
own. Storing `fh` in the record and using it for remove/close fixed both
(kick sends a real FIN, fd count returns to baseline, no zombie events).
Only `delete $connections{$key}` was correct before, because string key
matches string key.

**`max_age` separate from `cleanup_interval`.**
Previously one constant doubled as pass interval and maximum age, which
made the effective hold time 30-60 min but kept both knobs coupled. With
the configuration file both are exposed separately; defaults preserve
the old behavior.

**Loopback-only listener.**
The daemon binds to 127.0.0.1 only. It is unreachable from the outside
unless pf redirects traffic to it, which removes the risk of exposing
the tarpit directly.

**rc.d wrapper details.**
`rc_bg=YES` runs the foreground daemon through daemon(8);
`daemon_logger="daemon.info"` makes daemon(8) pipe output to syslog;
`rc_reload=NO` because the daemon has no reload mechanism. For the
interpreted script the rc script sets `daemon="/usr/bin/perl"` and
`daemon_flags="/usr/local/bin/tcptarpit.pl"`: OpenBSD 7.9's rc.subr
rebuilds pexp unconditionally from daemon + daemon_flags (a custom
pexp is overwritten), and this way the computed pexp matches the
process list entry `/usr/bin/perl /usr/local/bin/tcptarpit.pl`, so
check/stop/restart find the process (verified).

## Logging

Since 1.4.0 the default is file logging; the modes, selected by
`log_file`:

1. **Default (`log_file=/var/log/tcptarpit.log`):** all messages are
   appended to that file; stdout stays empty, so `/var/log/daemon`
   remains clean of tarpit noise. The package creates the file
   (owned by `_tcptarpit`, 0640), the run directory for the pid file
   and an idempotent rotation entry in `/etc/newsyslog.conf`
   (newsyslog(8) has no include directory on OpenBSD 8.0, so the
   package appends a marked block instead).
2. **Empty `log_file`:** every message goes to stdout, which
   daemon(8) pipes to syslogd(8) at `daemon.info` -> `/var/log/daemon`.

All messages go through a single `logmsg()` function - there is no
direct `print` outside it (config errors on stderr are the exception:
they occur before logging is initialized).

Rotation: on SIGHUP the daemon reopens the log file. newsyslog(8)
sends that signal to the pid listed in `pid_file`
(`/var/run/tcptarpit/tcptarpit.pid` by default since 1.4.0).

`SIGPIPE` is ignored so a broken syslog pipe cannot kill the daemon;
`SIGTERM`/`SIGINT` remove the pid file and exit.

## Stutter mode

Since 1.3.0 the daemon dribbles one filler byte per connection per
`stutter` seconds (default 1), mirroring spamd(8): a client that
receives occasional data keeps waiting for a complete response and
stays far longer than against total silence. `stutter=0` restores
the previous pure-silence behaviour.

Implementation notes:

* the select timeout shrinks to the earliest due byte, so the event
  loop wakes at most once per interval; per wake-up one byte per due
  connection is written.
* the dribble per connection is capped at 32 KiB: a peer that never
  reads stops receiving filler instead of filling the socket send
  buffer - the daemon can never block on a write, independent of
  max_age and stutter settings.
* a failed write (typically a reset) closes the connection through
  the same path as a read-side abort, with hold duration and error
  in the log.
* resource cost is one byte per connection per interval - 450 held
  connections produce ~450 B/s of traffic (measured in the load
  test: no CPU increase, no RSS increase).

## Socket layer and address families

Since 1.3.0 the daemon uses IO::Socket::IP from the OpenBSD base
perl (dual-stack capable) instead of IO::Socket::INET (IPv4 only).
Design:

* one listening socket per enabled family - `listen_ip` (IPv4,
  default 127.0.0.1) and `listen_ip6` (IPv6, default ::1); an empty
  value switches that family off, at least one address must remain
  (fail-fast otherwise). Both default ON.
* each pf address family needs its own rules: rdr-to 127.0.0.1 for
  inet, rdr-to ::1 for inet6; the <bruteforcers> table holds both
  address types.
* peerhost() logs the family's notation (::1 style for v6).
* pledge "inet" covers both families; unveil is unaffected.

## Login class and fd budget

Every held connection costs the daemon one file descriptor. OpenBSD's
default fd soft limit is 128, so an unprotected daemon stops accepting
at ~125 connections - found by the load test, not by reading. Since
1.2.0 the package ships a dedicated login class:

* `tcptarpit.login.conf` is installed as
  `/etc/login.conf.d/tcptarpit` (one file per class, filename =
  classname per login.conf(5); takes precedence over login.conf).
  The class sets `openfiles-cur=1024` and `openfiles-max=4096`.
* The file must be self-contained: cap_mkdb(1) builds it standalone,
  and `tc=` interpolation only works within one file (verified:
  cap_mkdb rejects `tc=daemon` here with "Record not tc expanded").
* PLIST wiring: `@newuser` assigns the class through its loginclass
  field (`_tcptarpit:960:960:tcptarpit:...`), `@sample` installs the
  class file without ever overwriting an edited one, `@exec` runs
  cap_mkdb after installation, and a second `@exec` applies
  `usermod -L tcptarpit` on upgrades (an existing user is left
  untouched by `@newuser`).
* Package readme: `pkg/README` is installed as
  `/usr/local/share/doc/pkg-readmes/tcptarpit` (stem without version,
  like the base ports do) and printed by pkg_add after installation
  via the `@display` PLIST directive - the admin sees enable/start,
  pf integration and address management right after pkg_add.
* The load test client needs its own raised limit (`ulimit -n 1024`)
  - both sides were capped at 128 during the first run.

## Privilege model

Port 8024 is unprivileged; the daemon never needs root after startup.
Startup order:

1. parse and validate `/etc/tcptarpit.conf`
2. open the log file (if `log_file` is set)
3. bind the listen socket
4. write the pid file (if `pid_file` is set)
5. drop privileges: `setgid` first, then `setuid` (irreversible), then
   verify that neither real nor effective uid is 0
6. unveil(2): reduce the filesystem view, then lock it
7. pledge(2): reduce the syscall set
8. enter the event loop

### pledge(2) and unveil(2)

Both OpenBSD security mechanisms are applied right before the event
loop, in the prescribed order (unveil first, because a restrictive
pledge blocks further unveils):

* **unveil**: only the log file (`"wc"` - reopen after newsyslog(8)
  rotation opens with O_CREAT and appends) and the directory of the
  pid file (`"wc"` - unlink on exit, recreate on restart) remain
  visible. With neither key configured, unveils are locked empty: the
  daemon has no filesystem access at all.
* **pledge**: `inet` for the socket work (accept, getpeername);
  `stdio` is always implied by OpenBSD::Pledge. `wpath cpath` are only
  pledged when a log file is configured (SIGHUP reopen), `cpath` only
  when a pid file is configured (unlink on exit). The daemon never
  forks, execs, or resolves DNS (the config only accepts IPv4
  literals), so no further promises are needed.

Both steps log a line on success, so the restriction is verifiable in
the log; on other platforms the daemon logs
`pledge/unveil unavailable` and runs without them (the perl modules
OpenBSD::Pledge/OpenBSD::Unveil only exist in the OpenBSD base system).

All file descriptors opened in steps 2-4 survive the drop, which is why
they are opened before it. Three cases are distinguished:

| Situation | Behaviour |
|-----------|-----------|
| started as root, `user` set | drop to user/group, logged |
| already running as `user` (e.g. rc.subr `daemon_user`) | no-op, logged |
| `user` set to a different user without root | startup aborts |

Running unprivileged from the start via rc.subr's `daemon_user` and the
in-daemon drop are equivalent end states; both are supported.

## Testing

Verified at runtime on a development machine (Linux, perl 5.36), each
with the exact acceptance criteria:

1. Listen on 127.0.0.1:8024, backlog SOMAXCONN (4096).
2. Tarpit silence: no response within 2 s after client sends data,
   connection stays writable.
3. FIN and RST from clients are detected and logged with the peer IP.
4. Parallel connections (2+) held simultaneously.
5. Cleanup kick (interval/max_age shortened to 3 s for the test): daemon
   closes after max_age + at most 10 s select delay, client sees EOF,
   daemon fd count returns to baseline, no `uninitialized` warnings,
   daemon keeps accepting new connections afterwards.
6. 1 MB burst + immediate close: ~0 s daemon CPU, disconnect logged
   within 2 s.
7. Configuration: missing file -> warning + defaults; valid overrides
   applied (port, intervals); unknown key / bad value / missing `=` each
   abort with `file:line`.
8. File logging: messages land in `log_file` (stdout stays empty);
   SIGHUP after renaming the file reopens it and logging continues into
   the new file; daemon survives.
9. Pid file: written at startup, contains the daemon pid, removed on
   SIGTERM together with a clean exit.
10. Privilege drop guards: running as the same user -> no-op with log
    line; switching to another user without root -> abort; unknown
    user -> abort.

Verified on the OpenBSD 7.9 (amd64) test system (2026-10-31):

* Port build in `/usr/ports/mystuff/net/tcptarpit` with
  `make package TCPTARPIT_SRCDIR=...` (after registering uid 960 in
  /usr/ports/infrastructure/db/user.list - pkg_create refuses
  unregistered @newuser ids) and install via
  `pkg_add -D unsigned` (7.9 refuses unsigned packages by default).
* `_tcptarpit` user/group created automatically by pkg_add
  (uid/gid 960, confirmed in /var/log/messages), rc.d script in
  /etc/rc.d, config installed from the sample via @sample.
* Full rcctl lifecycle enable/start/check/restart/stop: all ok.
  Note: OpenBSD 7.9's rc.subr rebuilds pexp from daemon+daemon_flags
  (custom pexp is overwritten), so the rc script runs the interpreter
  as `daemon` and the script path as `daemon_flags`.
* pledge(2)/unveil(2) active: log lines on every start, and
  `ps -o pledge` shows "stdio,inet" with uid/gid 960.
* daemon_logger path: output lands in /var/log/daemon.
* Live tarpit catch over loopback: nc connection trapped without any
  answer, FIN after Ctrl-C logged ("[+] bot trapped" / "[-] bot gave
  up").
* Package update: `pkg_add -D unsigned <file>` upgrades 1.0 -> 1.1 in
  place; admin-modified /etc/tcptarpit.conf survives `pkg_add -r`
  (@sample semantics confirmed); CHANGES lands in
  /usr/local/share/doc/tcptarpit/.
* Uninstall matrix: plain `pkg_delete` removes all files, keeps a
  modified configuration (with a manual-removal hint) and keeps
  user/group (with userdel/groupdel hints); `pkg_delete -c` with an
  unchanged configuration removes configuration and user/group. The
  pkg_scripts entry in rc.conf.local survives both - disable
  explicitly for a complete removal.
* Operational lesson from the test ruleset: replacing the whole pf.conf
  without a stateful `pass out` broke the test system's own outgoing
  traffic - DNS and HTTPS replies matched `block return in` because no
  state existed for them (SSH survived because the inbound ssh pass is
  stateful). pkg_add then blocked silently on its installurl check,
  which first looked like an offline system. `pfctl -d` identified the
  ruleset as the cause within seconds; the test pf.conf and the README
  example now include `pass out ... keep state`. Fully offline
  installs work with `PKG_PATH=<local pkgdir> pkg_add -D unsigned
  <name>`; SIGINT-aborted pkg_add runs leave no stale locks or child
  processes.
* pf interplay end to end (httpd on 80, no listener on 443): 40
  established connections in 0.02 s trigger max-src-conn-rate 30/10,
  the source appears in <bruteforcers>, connections to 80 AND 443 are
  then redirected into the tarpit (HTTP request times out silently,
  443 flips from refused to connected-then-silence), the daemon logs
  the preserved original source IP, and `pfctl -t bruteforcers -T
  delete` restores normal service immediately.

Operational finding from the same test: pf's src-limit counter stayed
at 0 when 40 connections were attempted against a *closed* port
(RST, no completed handshake) - the overload limits count
established connections only (pf.conf(5): the 3-way handshake
ensures the source is not spoofed). SYN-only scanners against closed
ports are therefore not counted by max-src-conn-rate.

Re-verified from scratch on OpenBSD 8.0 after sysupgrade (2026-10-31):
ports tree 8.0 (the uid registry entry has to be re-added after every
ports tree refresh), `make package` migrated the PLIST format
automatically (`@version 15 -> @version 18`), install, rcctl
lifecycle, pledge/unveil (ps: stdio,inet, uid 960) and the complete
pf chain (overload -> table -> rdr -> trapped with real source IP ->
hold duration -> delete restores service) all behave identically to
7.9. Operational finding: with a stale `.tgz` from an older release
still in the package repository, `make package` on 8.0 is a silent
no-op ("package considered up to date") - remove the old tgz before
rebuilding after a release upgrade.

* Load and resource suite (tests/tarpit-loadtest.pl) on OpenBSD
  8.0/amd64 with the login class active: all phases pass - 300 idle
  connections (307 fds), 100 MiB data flood for +1 s CPU, 1500
  FIN/RST churn cycles for +1 s CPU, 100 slowloris connections at
  +0 s CPU, 450 concurrent connections (457 fds), full recovery to
  baseline (7 fds). Without the class the daemon caps at ~125
  connections (default 128 fd soft limit) but stays alive and
  recovers - no crash, no leak.

* IPv6 (1.3.0): default dual-stack listeners verified on the
  development machine (v4 and v6 connections trapped and held
  silently, ::1 in the log) and on the OpenBSD 8.0 test system on
  ::1; v6-only and "both empty" fail-fast cases verified. External
  IPv6 traffic through pf could NOT be tested - the test VM has no
  global IPv6 address on vio0; the inet6 pf rules are documented
  accordingly.

Still open:

* The in-daemon root-to-user `setuid` branch (the package path runs
  unprivileged from the start via daemon_user, so the drop is a no-op).
* newsyslog(8) rotation with log_file/pid_file in production.
* pf interplay: `max-src-conn-rate` overload entries, `rdr-to` redirect
  of listed sources, `flush global` behaviour, whitelisting via an
  `<admins>` quick-pass rule.

## OpenBSD port and automatic daemon user

The `port/` directory contains a complete port skeleton:

```
port/Makefile     local port without distfile, installs from the
                  repository via TCPTARPIT_SRCDIR (defaults to ../)
port/pkg/PLIST    file list + @newgroup/@newuser/@rcscript/@sample
port/pkg/DESCR    package description
```

bsd.port.mk derives PKGPATH from the port directory and refuses to
build outside the ports tree ("Can't find ... under
PORTSDIR_PATH=/usr/ports:/usr/ports/mystuff" - observed on OpenBSD
7.9). Local ports therefore live in /usr/ports/mystuff: copy port/ to
/usr/ports/mystuff/net/tcptarpit and build with
`make package TCPTARPIT_SRCDIR=<repository>`.

`make install` (or `make package` + `pkg_add tcptarpit-1.0.tgz`) does
the following automatically, like other OpenBSD daemon packages:

* `@newgroup _tcptarpit:960` and
  `@newuser _tcptarpit:960:960::tcptarpit daemon:/nonexistent:/sbin/nologin`
  create the group and user during pkg_add(1) (field order
  name:uid:gid:loginclass:comment:home:shell, as documented in
  pkg_create(1) and used by e.g. audio/mpd and net/mosquitto). The
  uid/gid 960 lies above the current ports uid registry (which ends
  below 910) to avoid collisions with official ports; it is noted in a
  PLIST `@comment` and can be changed if it ever collides locally.
* `@rcscript ${RCDIR}/tcptarpit` installs the rc.d script
  (`RCDIR ?= /etc/rc.d` in bsd.port.mk), i.e. packages really do place
  daemon control scripts in /etc/rc.d.
* `@sample ${SYSCONFDIR}/tcptarpit.conf` copies the packaged sample
  (share/examples/tcptarpit/tcptarpit.conf) to /etc/tcptarpit.conf on
  first install and leaves an existing configuration untouched; on
  pkg_delete the configuration is only removed if unchanged.
* The rc script sets `daemon_user="_tcptarpit"`, so the daemon runs
  unprivileged out of the box.

On pkg_delete(1) the `_tcptarpit` user and group are removed with
extra clean-up (`pkg_delete -c`) if no other package references them.

Building a package requires an OpenBSD machine with the ports tree
(ports must be built on the target OS); the port skeleton therefore
follows the porting conventions exactly but its build could not be
executed on the Linux development machine - see the verification
matrix below.
