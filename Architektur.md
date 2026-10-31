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

1. Built-in defaults are defined for all four keys (`listen_ip`,
   `listen_port`, `cleanup_interval`, `max_age`).
2. If the file exists, every `key=value` line overrides a default;
   comments (`#`) and blank lines are ignored.
3. Unknown keys, lines without `=`, and values that fail validation
   abort the daemon with a `file:line` message. Failing fast on broken
   configuration follows the convention of OpenBSD daemons.
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

## Logging path

`print`/`warn` in the daemon -> daemon(8) `-l daemon.info` -> syslogd(8)
-> `/var/log/daemon`. Autoflush (`$| = 1`) is required so lines reach
syslog promptly.

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

Not testable on the development machine, must be verified on OpenBSD
after installation:

* `rcctl start/stop/check/status` lifecycle including `pkg_scripts`
  boot start.
* `daemon_logger` output actually landing in `/var/log/daemon`.
* pf interplay: `max-src-conn-rate` overload entries, `rdr-to` redirect
  of listed sources, `flush global` behaviour, whitelisting via an
  `<admins>` quick-pass rule.

## Future: OpenBSD port

The tree is already shaped for packaging: mdoc(7) manual page, `.sample`
configuration for `/etc`, rc.d script for `/etc/rc.d` + `pkg_scripts`,
binary path under `/usr/local/bin`, no dependencies beyond base perl.
A port would add `Makefile`/`distinfo`/`pkg/PLIST` around exactly these
files.
