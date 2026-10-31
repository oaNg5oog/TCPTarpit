#!/usr/bin/perl
#
# tcptarpit.pl -- generic layer-4 TCP tarpit for OpenBSD/pf.
#
# Listens on 127.0.0.1:8024 and never sends a single byte back.  Traffic
# is diverted here by pf (rdr-to) once a source has been overloaded into
# the <bruteforcers> table, e.g. by max-src-conn-rate rules.
#
# Install as /usr/local/bin/tcptarpit.pl, configuration goes into
# /etc/tcptarpit.conf (see tcptarpit.conf.sample).  Started via the
# rc.d(8) script -- see tcptarpit(8) and README.md.

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use IO::Handle;
use POSIX qw(setgid setuid);
use File::Basename qw(dirname);

$| = 1;    # autoflush on stdout, output is piped to syslog via daemon(8) -l

# Configuration: /etc/tcptarpit.conf overrides these defaults.
my $config_file = shift(@ARGV) // '/etc/tcptarpit.conf';
my %config = (
    listen_ip        => '127.0.0.1',
    listen_port      => 8024,
    cleanup_interval => 1800,    # seconds between cleanup passes
    max_age          => 1800,    # seconds before a connection is closed
    log_file         => '',      # empty = stdout (syslog via daemon(8))
    pid_file         => '',      # empty = no pid file
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

    my @octets = split /\./, $cfg->{listen_ip};
    (@octets == 4
        && !grep { $_ !~ /^\d{1,3}$/ || $_ > 255 } @octets)
        or die "invalid listen_ip \"$cfg->{listen_ip}\"\n";

    $cfg->{listen_port} =~ /^\d+$/
        && $cfg->{listen_port} >= 1
        && $cfg->{listen_port} <= 65535
        or die "invalid listen_port \"$cfg->{listen_port}\"\n";

    for my $key (qw(cleanup_interval max_age)) {
        $cfg->{$key} =~ /^\d+$/
            && $cfg->{$key} >= 1
            or die "invalid $key \"$cfg->{$key}\"\n";
    }

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

# newsyslog(8) sends SIGHUP after rotation (via the pid file): reopen
# the log file so the daemon keeps logging into the new file.
sub reopen_log {
    return unless $log_fh;
    my $path = $config{log_file};
    unless (open($log_fh, '>>', $path)) {
        warn "cannot reopen log file $path after SIGHUP: $!\n";
        return;
    }
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
    push @promises, qw(wpath cpath) if length $config{log_file};
    push @promises, 'cpath'
        if length $config{pid_file} && !length $config{log_file};

    OpenBSD::Pledge::pledge(@promises)
        or die "pledge(@promises) failed: $!\n";
    logmsg("[*] pledged to: stdio @promises\n");
}

END { remove_pidfile() }
$SIG{HUP}  = \&reopen_log;
$SIG{TERM} = sub { remove_pidfile(); exit 0 };
$SIG{INT}  = sub { remove_pidfile(); exit 0 };
$SIG{PIPE} = 'IGNORE';    # a broken syslog pipe must not kill the daemon

open_log($config{log_file});

# main listening socket
my $server = IO::Socket::INET->new(
    LocalAddr => $config{listen_ip},
    LocalPort => $config{listen_port},
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    ReuseAddr => 1
    ) or die "cannot create socket: $!\n";

write_pidfile($config{pid_file});
drop_privileges($config{user}, $config{group});
if ($has_pledge or $has_unveil) {
    apply_unveil();
    apply_pledge();
} else {
    logmsg("[*] pledge/unveil unavailable (not OpenBSD?), running without\n");
}

logmsg("generic layer-4 TCP tarpit running on $config{listen_ip}:$config{listen_port}"
    . " (config: $config_file, uid=$<)\n");

my $selector = IO::Select->new($server);
my %connections;
my $last_cleanup = time();

while (1) {
    # wait for events (10 seconds at most)
    my @ready = $selector->can_read(10);

    foreach my $fh (@ready) {
        if ($fh == $server) {
            # new connection
            my $client = $server->accept();
            if ($client) {
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
                    fh         => $client,
                    ip         => $ip,
                    port       => $port,
                    start_time => time(),
                };
            }
        } else {
            # a client socket became readable: data, EOF or error
            my $buffer;
            # Read in large chunks and discard everything.  The peer is
            # never answered and its data is dropped, so its TCP window
            # runs full; sysread returning 0 means EOF (FIN), undef
            # means error (e.g. RST).
            my $res = sysread($fh, $buffer, 65536);

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
                my $ip = $connections{$fh}->{ip};
                if (defined $res) {
                    logmsg("[-] bot gave up: $ip\n");
                } else {
                    logmsg("[-] bot aborted: $ip ($!)\n");
                }
                $selector->remove($fh);
                delete $connections{$fh};
                close($fh);
            }
        }
    }

    # periodic cleanup of stale connections
    my $now = time();
    if ($now - $last_cleanup >= $config{cleanup_interval}) {
        logmsg("[*] starting periodic cleanup of stale connections\n");
        while (my ($key, $data) = each %connections) {
            if ($now - $data->{start_time} >= $config{max_age}) {
                logmsg(sprintf("[*] kicking bot after %d s hold time: %s:%s\n",
                    $config{max_age}, $data->{ip}, $data->{port}));
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
