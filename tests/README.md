# tcptarpit tests

## tarpit-loadtest.pl

Resource and effectiveness test, run directly on the daemon host
(root, so daemon statistics are readable):

```sh
perl tests/tarpit-loadtest.pl                # against 127.0.0.1:8024
perl tests/tarpit-loadtest.pl --host H --port P
```

Core perl only (IO::Socket::IP, IO::Select), no dependencies. Exit
code 0 = all phases passed, 1 otherwise, so it can run as a smoke test
after deployment.

Note: the idle_flood and fd_pressure phases open hundreds of
connections from ONE source and therefore need the per-source cap
lifted for the run: append `max_per_source=0` to /etc/tcptarpit.conf,
restart, run the suite, remove the line again.

| Phase | What it does | What it proves |
|---|---|---|
| probe | connect, send, count bytes for 2 s, write again | no real response ever arrives (at most a few stutter bytes), connection held |
| stutter | count bytes for 4 s | default stutter dribbles ~1 byte/s (spamd-style) |
| v6_probe | same as probe against ::1 | IPv6 listener traps silently as well (SKIP if v6 unavailable) |
| idle_flood | 300 concurrent silent connections, 5 s | memory per held connection < 32 KiB, CPU bounded |
| data_flood | 50 connections push 100 MiB total | 64 KiB drain keeps daemon CPU near zero |
| churn | 1000 connect+FIN and 500 connect+RST cycles | disconnect storms cost bounded CPU, daemon survives |
| slowloris | 100 connections, 1 byte/s for 8 s | slow senders are held at ~zero cost |
| fd_pressure | 450 concurrent connections held | connection count scales linearly with fd usage |
| recovery | probe + resource comparison | fds/RSS return to baseline, tarpit fully functional |

While the test runs, the daemon side can be watched with:

```sh
ps -o pid,rss,vsz,time,pledge -p $(pgrep -f tcptarpit.pl)
fstat -p $(pgrep -f tcptarpit.pl)
tail -f /var/log/daemon
```

## Production sizing notes

* Every held connection costs one file descriptor plus roughly a few
  KiB of memory. The default 128 fd soft limit is reached at ~125
  connections - since 1.2.0 the package ships the `tcptarpit` login
  class (/etc/login.conf.d/tcptarpit, openfiles 1024/4096) and
  assigns it to `_tcptarpit` automatically. The load test client also
  needs a raised limit: run `ulimit -n 1024` first (verified root
  shell default is 128/1024 soft/hard).
* Every trapped connection and every disconnect writes one syslog
  line - a large DDoS generates proportionate log volume. If that
  matters, switch to `log_file` with newsyslog rotation (see
  README.md).
* Held connections are closed by the daemon after `max_age`; the fd
  count therefore cannot grow indefinitely from passive bots.
