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
`pexp` is set to `perl /usr/local/bin/tcptarpit.pl` because rc.subr(8)
must find the interpreter process, not the script file; `rc_reload=NO`
because the daemon has no reload mechanism.

## Logging

Two modes, selected by the `log_file` configuration key:

1. **Default (empty `log_file`):** every message goes to stdout, which
   daemon(8) pipes to syslogd(8) at `daemon.info` -> `/var/log/daemon`.
2. **File mode (`log_file=/var/log/tcptarpit.log`):** all messages are
   appended to that file; stdout stays empty. The file is opened in
   append mode with autoflush before privileges are dropped, so root
   only needs to create it once with the right ownership.

All messages go through a single `logmsg()` function - there is no
direct `print` outside it (config errors on stderr are the exception:
they occur before logging is initialized).

Rotation: on SIGHUP the daemon reopens the log file. newsyslog(8)
sends that signal to the pid listed in `pid_file`:

```sh
/var/log/tcptarpit.log _tcptarpit:_tcptarpit 640 7 250 * Z /var/run/tcptarpit/tcptarpit.pid
```

`SIGPIPE` is ignored so a broken syslog pipe cannot kill the daemon;
`SIGTERM`/`SIGINT` remove the pid file and exit.

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

Not testable on the development machine, must be verified on OpenBSD
after installation:

* Port build and package install: `make install` / `make package` +
  `pkg_add`, especially the automatic `_tcptarpit` user/group creation
  (`@newuser`/`@newgroup`), `@rcscript` into /etc/rc.d and `@sample`
  config handling.
* pledge(2)/unveil(2) actually taking effect (expect the two log lines
  `[*] filesystem restricted via unveil(2)` and `[*] pledged to:
  stdio inet`; then e.g. `ps -o pledge -p <pid>` shows the promised
  set, and opening any other file must fail).
* The actual root-to-user `setuid` drop (guard cases are covered above,
  the setuid branch itself requires starting as root).
* `rcctl start/stop/check/status` lifecycle including `pkg_scripts`
  boot start.
* `daemon_logger` output actually landing in `/var/log/daemon`.
* newsyslog(8) rotation in production.
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
