#!/usr/bin/perl
#
# tcptarpit.pl -- generic layer-4 TCP tarpit for OpenBSD/pf.
#
# Listens on loopback (127.0.0.1 and ::1 by default) and never yields a
# real answer: incoming data is discarded and at most one filler byte
# per connection per stutter interval is dribbled back, spamd-style.
# Traffic is diverted here by pf (rdr-to) once a source has been
# overloaded into the <bruteforcers> table, e.g. by max-src-conn-rate
# rules.
#
# Install as /usr/local/bin/tcptarpit.pl, configuration goes into
# /etc/tcptarpit.conf (see tcptarpit.conf.sample).  Started via the
# rc.d(8) script -- see tcptarpit(8) and README.md.

use strict;
use warnings;
use IO::Socket::IP;
use IO::Select;
use IO::Handle;
use POSIX qw(setgid setuid);
use Errno qw(EAGAIN EWOULDBLOCK EINTR ECONNABORTED EMFILE ENFILE);
use File::Basename qw(dirname);

$| = 1;    # autoflush on stdout, output is piped to syslog via daemon(8) -l

# total dribble per connection is capped so the send buffer can never
# fill up completely, independent of kernel send buffer sizing
use constant STUTTER_CAP => 32000;

# Configuration: /etc/tcptarpit.conf overrides these defaults.
my $config_file = shift(@ARGV) // '/etc/tcptarpit.conf';
my %config = (
    listen_ip        => '127.0.0.1',  # IPv4 address, empty = IPv4 off
    listen_ip6       => '::1',        # IPv6 address, empty = IPv6 off
    listen_port      => 8024,
    cleanup_interval => 1800,    # seconds between cleanup passes
    max_age          => 1800,    # seconds before a connection is closed
    stutter          => 1,       # seconds per dribbled byte, 0 = pure silence
    log_file         => '/var/log/tcptarpit.log',   # empty = stdout/syslog
    pid_file         => '/var/run/tcptarpit/tcptarpit.pid',  # empty = none
    user             => '',      # empty = no privilege drop
    group            => '',      # empty = primary group of user
);

#########
# # /etc/pf.conf
#table <bruteforcers> persist
## Everyone on the list is pushed straight into the generic TCP tarpit
#pass in quick on ext_if proto tcp from <bruteforcers> to any port { ssh, http, https } \
#    rdr-to 127.0.0.1 port 8024
## SSH watch: more than 3 connections within 30 seconds goes on the list
#pass in on ext_if proto tcp to any port ssh flags S/SA keep state \
#    (max-src-conn-rate 3/30, overload <bruteforcers> flush global)
## Webserver watch: protection against fast HTTP scanners / dir busters
#pass in on ext_if proto tcp to any port { http, https } flags S/SA keep state \
#    (max-src-conn-rate 30/10, overload <bruteforcers> flush global)
##########

read_config($config_file, \%config);
validate_config(\%config);

my $log_fh;    # undef = log to stdout

sub read_config {
    my ($path, $cfg) = @_;

    unless (-f $path) {
        warn "config file $path not found, using built-in defaults\n";
        return;
    }

    open(my $fh, '<', $path) or die "cannot open config file $path: $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        $line =~ s/#.*//;          # strip comments
        $line =~ s/^\s+|\s+$//g;   # trim whitespace
        next unless length $line;

        my ($key, $value) = split /\s*=\s*/, $line, 2;
        unless (defined $value) {
            die "$path:$.: syntax error, expected key=value: \"$line\"\n";
        }
        unless (exists $cfg->{$key}) {
            die "$path:$.: unknown configuration key \"$key\"\n";
        }
        $cfg->{$key} = $value;
    }
    close($fh);
}

sub validate_config {
    my ($cfg) = @_;

    my $v4 = length $cfg->{listen_ip};
    my $v6 = length $cfg->{listen_ip6};
    ($v4 || $v6)
        or die "no listen address: set listen_ip (IPv4) and/or listen_ip6 (IPv6)\n";

    if ($v4) {
        my @octets = split /\./, $cfg->{listen_ip};
        (@octets == 4
            && !grep { $_ !~ /^\d{1,3}$/ || $_ > 255 } @octets)
            or die "invalid listen_ip \"$cfg->{listen_ip}\"\n";
    }
    if ($v6) {
        # loose literal check; the definitive validation is the bind
        # itself, which fails fast with a clear error
        $cfg->{listen_ip6} =~ /^[0-9A-Fa-f:.]+(%[A-Za-z0-9]+)?$/
            or die "invalid listen_ip6 \"$cfg->{listen_ip6}\"\n";
    }

    $cfg->{listen_port} =~ /^\d+$/
        && $cfg->{listen_port} >= 1
        && $cfg->{listen_port} <= 65535
        or die "invalid listen_port \"$cfg->{listen_port}\"\n";

    for my $key (qw(cleanup_interval max_age)) {
        $cfg->{$key} =~ /^\d+$/
            && $cfg->{$key} >= 1
            or die "invalid $key \"$cfg->{$key}\"\n";
    }

    $cfg->{stutter} =~ /^\d+$/
        or die "invalid stutter \"$cfg->{stutter}\" (seconds per byte, 0 = off)\n";

    for my $key (qw(log_file pid_file)) {
        next unless length $cfg->{$key};
        $cfg->{$key} =~ m|^/|
            or die "invalid $key \"$cfg->{$key}\": must be an absolute path\n";
    }
}

# All daemon messages go through logmsg().  With log_file unset, output
# goes to stdout, which daemon(8) pipes to syslog (daemon.info).  With
# log_file set, output is appended to that file instead.
sub logmsg {
    my ($msg) = @_;
    if ($log_fh) { print $log_fh $msg }
    else         { print $msg }
}

sub open_log {
    my ($path) = @_;
    return unless length $path;
    open($log_fh, '>>', $path) or die "cannot open log file $path: $!\n";
    $log_fh->autoflush(1);
}

# newsyslog(8) rotates by renaming the file, creating a fresh one and
# then sending SIGHUP (via the pid file): reopen the log so the daemon
# keeps logging into the new file.  If the file does not exist at this
# point it cannot be recreated here (unveil covers the file path, not
# its directory), so the daemon degrades to stdout instead of losing
# messages - one warning is emitted, nothing is silently dropped.
sub reopen_log {
    return unless length $config{log_file};
    my $path = $config{log_file};
    my $new_fh;
    unless (open($new_fh, '>>', $path)) {
        warn "cannot reopen log file $path after SIGHUP: $!"
            . " - falling back to stdout until the file exists again\n";
        $log_fh = undef;    # logmsg() prints to stdout from now on
        return;
    }
    close($log_fh) if $log_fh;
    $log_fh = $new_fh;
    $log_fh->autoflush(1);
    logmsg("[*] log file reopened after rotation\n");
}

my $wrote_pidfile = 0;

sub write_pidfile {
    my ($path) = @_;
    return unless length $path;
    open(my $pf, '>', $path) or die "cannot write pid file $path: $!\n";
    print $pf "$$\n";
    close($pf);
    $wrote_pidfile = 1;
}

sub remove_pidfile {
    return unless $wrote_pidfile;
    unlink($config{pid_file})
        or warn "cannot remove pid file $config{pid_file}: $!\n";
    $wrote_pidfile = 0;
}

# Drop root privileges before entering the event loop.  Socket, log file
# and pid file are already open by then; the descriptors survive setuid.
# Starting the daemon unprivileged in the first place (rc.subr
# daemon_user) is equally supported - the drop is then a no-op.
sub drop_privileges {
    my ($user, $group) = @_;
    return unless length $user;

    my ($login, $uid, $gid) = (getpwnam($user))[0, 2, 3];
    die "unknown user \"$user\"\n" unless defined $uid;
    if (length $group) {
        my $group_gid = (getgrnam($group))[2];
        die "unknown group \"$group\"\n" unless defined $group_gid;
        $gid = $group_gid;
    }

    if ($< == 0 || $> == 0) {
        setgid($gid) or die "setgid($gid) for user \"$user\" failed: $!\n";
        setuid($uid) or die "setuid($uid) for user \"$user\" failed: $!\n";
        die "privilege drop to \"$user\" failed\n" if $< == 0 || $> == 0;
        logmsg("[*] dropped privileges to $login (uid=$uid, gid=$gid)\n");
    }
    elsif ($< == $uid && $> == $uid) {
        logmsg("[*] already running as $login (uid=$uid), no drop needed\n");
    }
    else {
        die "cannot switch to user \"$user\": not running as root\n";
    }
}

# pledge(2) and unveil(2), the OpenBSD security mechanisms.  Both perl
# modules are part of the OpenBSD base system; on other platforms the
# daemon logs a notice and runs without them.
my $has_pledge = eval { require OpenBSD::Pledge;  1 } ? 1 : 0;
my $has_unveil = eval { require OpenBSD::Unveil; 1 } ? 1 : 0;

# Restrict the filesystem view to the paths the daemon still touches
# after startup: the log file (reopen on SIGHUP, i.e. after newsyslog(8)
# rotation) and the directory of the pid file (unlink on exit).  With
# neither configured, the lock alone denies every filesystem access -
# the daemon is a pure network service then.  unveil(2) must happen
# before pledge(2).
sub apply_unveil {
    return unless $has_unveil;

    if (length $config{log_file}) {
        OpenBSD::Unveil::unveil($config{log_file}, "wc")
            or die "unveil($config{log_file}) failed: $!\n";
    }
    if (length $config{pid_file}) {
        my $dir = dirname($config{pid_file});
        OpenBSD::Unveil::unveil($dir, "wc")
            or die "unveil($dir) failed: $!\n";
        # unlink() on the pid file needs the file itself unveiled with
        # "cr": "r" because perl's unlink lstat()s the file first
        # (stat needs read permission under unveil), "c" for the
        # removal itself - the directory unveil alone is not
        # sufficient (verified on OpenBSD 8.0: EPERM and an empty $!
        # otherwise).  The file always exists at this point because
        # write_pidfile() ran before the unveil.
        OpenBSD::Unveil::unveil($config{pid_file}, "cr")
            or die "unveil($config{pid_file}) failed: $!\n";
    }
    OpenBSD::Unveil::unveil()    # lock: no further unveil calls
        or die "unable to lock unveil: $!\n";
    logmsg("[*] filesystem restricted via unveil(2)\n");
}

# Restrict the available syscalls: network sockets (accept, getpeername)
# plus the minimum needed for log reopening and pid file removal.
# "stdio" is always implied by the OpenBSD::Pledge module.
sub apply_pledge {
    return unless $has_pledge;

    my @promises = qw(inet);
    # wpath/cpath: (re)opening the log file after rotation.  cpath and
    # rpath for the pid file: perl's unlink() lstat()s the file first
    # (verified with ktrace on OpenBSD 8.0), which pledge flags as
    # "rpath" - without it every SIGTERM/SIGINT ended in a pledge
    # abort instead of a clean shutdown.  unveil limits the readable
    # and writable paths to the log file and the pid directory anyway.
    push @promises, 'wpath' if length $config{log_file};
    push @promises, 'cpath' if length $config{log_file} || length $config{pid_file};
    push @promises, 'rpath' if length $config{pid_file};

    OpenBSD::Pledge::pledge(@promises)
        or die "pledge(@promises) failed: $!\n";
    logmsg("[*] pledged to: stdio @promises\n");
}

# Format a duration in seconds with the two most significant units
# (e.g. "45 s", "1 min 20 s", "2 h 5 min", "3 d 4 h"), so the log shows
# how long bots actually endure the tarpit.
sub fmt_duration {
    my ($s) = @_;
    return "$s s" if $s < 60;

    my @parts;
    my @units = ([86400, 'd'], [3600, 'h'], [60, 'min']);
    for my $u (@units) {
        last if @parts >= 2;
        if ($s >= $u->[0]) {
            push @parts, sprintf("%d %s", int($s / $u->[0]), $u->[1]);
            $s %= $u->[0];
        }
    }
    push @parts, "$s s" if @parts < 2 && $s > 0;
    return join(' ', @parts);
}

END { remove_pidfile() }
$SIG{HUP}  = \&reopen_log;
$SIG{TERM} = sub { remove_pidfile(); exit 0 };
$SIG{INT}  = sub { remove_pidfile(); exit 0 };
$SIG{PIPE} = 'IGNORE';    # a broken syslog pipe must not kill the daemon

open_log($config{log_file});

# listening sockets: one per enabled address family (IPv4 and/or
# IPv6), each individually switchable through listen_ip / listen_ip6
my @servers;
if (length $config{listen_ip}) {
    my $s = IO::Socket::IP->new(
        LocalAddr => $config{listen_ip},
        LocalPort => $config{listen_port},
        Proto     => 'tcp',
        Listen    => SOMAXCONN,
        ReuseAddr => 1
        ) or die "cannot create IPv4 socket on $config{listen_ip}:$config{listen_port}: $!\n";
    push @servers, $s;
}
if (length $config{listen_ip6}) {
    my $s = IO::Socket::IP->new(
        LocalAddr => $config{listen_ip6},
        LocalPort => $config{listen_port},
        Proto     => 'tcp',
        Listen    => SOMAXCONN,
        ReuseAddr => 1,
        ) or die "cannot create IPv6 socket on $config{listen_ip6}:$config{listen_port}: $!\n";
    push @servers, $s;
}

write_pidfile($config{pid_file});
drop_privileges($config{user}, $config{group});
if ($has_pledge or $has_unveil) {
    apply_unveil();
    apply_pledge();
} else {
    logmsg("[*] pledge/unveil unavailable (not OpenBSD?), running without\n");
}

logmsg("generic layer-4 TCP tarpit running on "
    . join(' ', map { $_->sockhost . ':' . $_->sockport } @servers)
    . " (config: $config_file, uid=$<)\n");

my $selector = IO::Select->new(@servers);
my %connections;
my $last_cleanup = time();
my $accept_err_logged = 0;

while (1) {
    # wait for events; with stuttering active, wake up in time for the
    # next byte due to a connection (otherwise up to 10 seconds).
    # Connections that reached the dribble cap do not participate:
    # their deadline is stale and would pin the timeout at zero, busy
    # looping the daemon.
    my $timeout = 10;
    if ($config{stutter} > 0) {
        my ($now, $earliest) = (time());
        for my $key (keys %connections) {
            my $rec = $connections{$key};
            next if $rec->{sent_bytes} >= STUTTER_CAP;
            my $when = $rec->{next_stutter};
            $earliest = $when if !defined $earliest || $when < $earliest;
        }
        if (defined $earliest) {
            $timeout = $earliest - $now;
            $timeout = 0 if $timeout < 0;
            $timeout = 10 if $timeout > 10;
        }
    }
    my @ready = $selector->can_read($timeout);

    my $accepted = 0;
    foreach my $fh (@ready) {
        if (grep { $fh == $_ } @servers) {
            # new connection on one of the listening sockets
            my $client = $fh->accept();
            if ($client) {
                # non-blocking: a full send buffer must suspend the
                # dribble instead of blocking the whole event loop
                $client->blocking(0);
                $accepted++;
                my $ip   = $client->peerhost();
                my $port = $client->peerport();
                if (!defined $ip || !defined $port) {
                    # the peer reset the connection before accept()
                    # could query its address - nothing to trap, drop it
                    logmsg("[-] bot vanished before capture\n");
                    close($client);
                    next;
                }
                logmsg("[+] bot trapped: $ip:$port\n");

                $selector->add($client);
                # Hash keys are stringified globs, therefore the real
                # handle is stored in the value as well (see cleanup loop).
                $connections{$client} = {
                    fh           => $client,
                    ip           => $ip,
                    port         => $port,
                    start_time   => time(),
                    next_stutter => time() + $config{stutter},
                    sent_bytes   => 0,
                };
            } else {
                # ECONNABORTED is expected under connection churn: the
                # peer reset during the handshake, the kernel dropped
                # the queued connection - just skip it (found on the
                # 8.0 test system: pacing this error throttled accept
                # until client connects timed out).
                next if $! == ECONNABORTED;
                # a real accept failure (EMFILE/ENFILE at the fd limit)
                # keeps the listening socket readable while connections
                # keep arriving, which would spin the loop at full CPU.
                # Log once and pace the retry.
                if (!$accept_err_logged) {
                    logmsg("[!] accept() failed: $! - file descriptor limit reached?\n");
                    $accept_err_logged = 1;
                }
                select(undef, undef, undef, 0.1);
            }
        } else {
            # a client socket became readable: data, EOF or error
            my $buffer;
            # Read in large chunks and discard everything.  The peer is
            # never answered and its data is dropped, so its TCP window
            # runs full; sysread returning 0 means EOF (FIN), undef
            # means error (e.g. RST).
            my $res = sysread($fh, $buffer, 65536);
            if (!defined $res && ($! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR)) {
                # spurious wakeup on a non-blocking socket - nothing to do
                next;
            }

            if (defined $res && $res > 0) {
                # the bot sent data, we ignore it on purpose; the socket
                # stays in the selector so a later FIN/RST is noticed
                next;
            } else {
                # the client side ended the connection:
                #   0     = clean close, the client sent FIN
                #   undef = socket error, usually an RST
                # Daemon-side timeouts are logged by the cleanup pass
                # ("kicking bot ... hold time"), never here.
                my $rec  = $connections{$fh};
                my $ip   = $rec->{ip};
                my $held = fmt_duration(time() - $rec->{start_time});
                if (defined $res) {
                    logmsg("[-] bot gave up after $held: $ip\n");
                } else {
                    logmsg("[-] bot aborted after $held: $ip ($!)\n");
                }
                $selector->remove($fh);
                delete $connections{$fh};
                close($fh);
            }
        }
    }

    # reset the accept-error latch once connections succeed again
    $accept_err_logged = 0 if $accepted;

    # stutter pass: dribble one byte per connection per interval, like
    # spamd(8).  Client sockets are non-blocking, so a full send buffer
    # (peer never reads) suspends the dribble for that connection with
    # EAGAIN instead of blocking the whole event loop; the total dribble
    # is capped (STUTTER_CAP) as a second guard.  A connection whose
    # peer never reads simply stops receiving dribble and is still held
    # and closed at max_age.
    if ($config{stutter} > 0) {
        my $now = time();
        for my $key (keys %connections) {
            my $rec = $connections{$key};
            next if $now < $rec->{next_stutter};
            next if $rec->{sent_bytes} >= STUTTER_CAP;
            my $sock = $rec->{fh};
            my $wrote = syswrite($sock, ' ');
            if (!defined $wrote) {
                if ($! == EAGAIN || $! == EWOULDBLOCK) {
                    # send buffer full: suspend the dribble for this
                    # connection, retry at the next interval
                    $rec->{next_stutter} = $now + $config{stutter};
                    next;
                }
                # write error, usually a reset: the connection is gone
                my $held = fmt_duration($now - $rec->{start_time});
                logmsg("[-] bot aborted after $held: $rec->{ip} (write: $!)\n");
                $selector->remove($sock);
                close($sock);
                delete $connections{$key};
                next;
            }
            $rec->{sent_bytes} += $wrote;
            $rec->{next_stutter} = $now + $config{stutter};
        }
    }

    # periodic cleanup of stale connections
    my $now = time();
    if ($now - $last_cleanup >= $config{cleanup_interval}) {
        logmsg("[*] starting periodic cleanup of stale connections\n");
        while (my ($key, $data) = each %connections) {
            if ($now - $data->{start_time} >= $config{max_age}) {
                logmsg(sprintf("[*] kicking bot after %s hold time: %s:%s\n",
                    fmt_duration($config{max_age}), $data->{ip}, $data->{port}));
                # each() yields stringified keys, so remove/close must
                # go through the handle stored in the record
                my $sock = $data->{fh};
                $selector->remove($sock);
                close($sock);
                delete $connections{$key};
            }
        }
        $last_cleanup = $now;
    }
}
