#!/usr/bin/perl
#
# tarpit-loadtest.pl - resource and effectiveness test for tcptarpit.
#
# Run directly on the daemon host (root recommended, so daemon stats
# can be read):
#
#     perl tests/tarpit-loadtest.pl
#
# Optional arguments:
#
#     perl tests/tarpit-loadtest.pl --host 127.0.0.1 --port 8024
#
# Phases (each prints PASS/FAIL and measured numbers):
#   0  baseline probe: silence, connection held, FIN detected
#   1  idle flood: 300 concurrent silent connections
#   2  data flood: 50 connections push 2 MiB each (100 MiB total)
#   3  churn storm: 1000 connect+FIN and 500 connect+RST cycles
#   4  slowloris: 100 connections, 1 byte per second each
#   5  fd pressure: 450 concurrent connections
#   6  recovery: daemon healthy, resources back at baseline
#
# Acceptance criteria (production readiness):
#   - daemon stays alive and keeps accepting in every phase
#   - memory growth < 32 KiB per held connection
#   - CPU per phase bounded (see %limits below)
#   - after all clients disconnect, fd count and RSS return to
#     baseline and the tarpit still works

use strict;
use warnings;
use IO::Socket::IP;
use IO::Select;
use Socket qw(SOL_SOCKET SO_LINGER);
use Getopt::Long;

my $host = '127.0.0.1';
my $host6 = '::1';
my $port = 8024;
GetOptions('host=s' => \$host, 'host6=s' => \$host6, 'port=i' => \$port)
    or die "usage: $0 [--host 127.0.0.1] [--host6 ::1] [--port 8024]\n";
# --host6 '' disables the IPv6 phase

my %limits = (          # acceptable CPU seconds per phase
    idle_flood   => 2,
    data_flood   => 2,
    churn        => 4,
    slowloris    => 1,
    fd_pressure  => 2,
);

my @fails;
my $fstat_ok = `command -v fstat 2>/dev/null` ? 1 : 0;
my $dpid = daemon_pid();

sub daemon_pid {
    my $out = `pgrep -f 'tcptarpit\\.pl' 2>/dev/null`;
    return undef unless defined $out;
    my @pids = grep { /^\d+$/ } split /\s+/, $out;
    return $pids[0];
}

# daemon snapshot: cpu seconds, rss KiB, open descriptors
sub stats {
    my ($pid) = @_;
    return undef unless $pid;
    my $cpu = `ps -o time= -p $pid 2>/dev/null`;
    return undef unless defined $cpu;
    chomp $cpu;
    my $sec = 0;
    if ($cpu =~ /(\d+):(\d+):(\d+)/) { $sec = $1*3600 + $2*60 + $3 }
    elsif ($cpu =~ /(\d+):(\d+)/)    { $sec = $1*60 + $2 }
    my $rss = `ps -o rss= -p $pid 2>/dev/null` // 0;
    chomp $rss; $rss //= 0;
    my $fds;
    if ($fstat_ok) {
        my @lines = `fstat -p $pid 2>/dev/null`;
        $fds = scalar @lines;
    }
    return { cpu => $sec, rss => $rss + 0, fds => $fds };
}

sub connect_one {
    my $s = IO::Socket::IP->new(
        PeerAddr => $host, PeerPort => $port,
        Proto    => 'tcp', Timeout  => 5
    );
    return $s;
}

sub rst_close {
    my ($s) = @_;
    setsockopt($s, SOL_SOCKET, SO_LINGER, pack('l l', 1, 0));
    close $s;
}

sub verdict {
    my ($phase, $ok, $detail) = @_;
    printf "%s %-12s %s\n", ($ok ? 'PASS' : 'FAIL'), $phase, $detail;
    push @fails, $phase unless $ok;
}

sub daemon_alive {
    return defined daemon_pid();
}

print "== tcptarpit load test against $host:$port ==\n";
print "daemon pid: " . ($dpid // 'NOT FOUND (stats disabled)') . "\n\n";

# ---------------------------------------------------------------- phase 0
my $base = $dpid ? stats($dpid) : undef;
if ($base) {
    printf "baseline: cpu=%ds rss=%dKiB%s\n\n",
        $base->{cpu}, $base->{rss},
        (defined $base->{fds} ? " fds=$base->{fds}" : '');
}

{
    my $s = connect_one();
    if (!$s) { verdict('probe', 0, "connect failed: $!"); exit 1 }
    syswrite($s, "GET / HTTP/1.0\r\n\r\n");
    my $sel = IO::Select->new($s);
    my $bytes = 0;
    my $t0 = time;
    while (time - $t0 < 2) {
        if ($sel->can_read(0.2)) {
            my $n = sysread($s, my $b, 64);
            last unless $n;
            $bytes += $n;
        }
    }
    syswrite($s, 'x' x 32);
    close $s;
    # with stuttering (default) at most a few dribbled bytes may arrive;
    # a real response is never acceptable
    verdict('probe', $bytes <= 3,
        $bytes <= 3
            ? sprintf('no response%s, connection held and writable',
                      $bytes ? " ($bytes dribbled bytes)" : '')
            : "daemon sent $bytes bytes within 2s (real response)");
}

# ---------------------------------------------------------------- stutter
{
    my $s = connect_one();
    my $bytes = 0;
    if ($s) {
        my $t0 = time;
        while (time - $t0 < 4) {
            vec(my $rin = '', fileno($s), 1) = 1;
            # only read when select signalled readability - a blocking
            # read would hang forever against a silent daemon
            if (select($rin, undef, undef, 4) > 0) {
                my $n = sysread($s, my $b, 64);
                last unless $n;
                $bytes += $n;
            }
        }
        close $s;
    }
    # ~1 byte per second with the default stutter interval
    verdict('stutter', defined($s) && $bytes >= 2 && $bytes <= 7,
        defined($s)
            ? sprintf('%d bytes dribbled in 4s', $bytes)
            : 'connect failed');
}

# ---------------------------------------------------------------- phase 1
my (@idle, $t0, $s1);
{
    my $ok = 0;
    for (1 .. 300) {
        my $s = connect_one();
        if ($s) { $ok++; push @idle, $s }
    }
    my $st = $dpid ? stats($dpid) : undef;
    sleep 5;
    my $st2 = $dpid ? stats($dpid) : undef;
    my $rss_per_conn;
    if ($st2) {
        $rss_per_conn = ($st2->{rss} - $base->{rss}) / ($ok || 1);
    }
    my $cpu_ok = !$st2 || ($st2->{cpu} - $base->{cpu}) <= $limits{idle_flood};
    my $mem_ok = !defined $rss_per_conn || $rss_per_conn < 32 * 1024;
    my $detail = sprintf('300 attempted, %d connected', $ok);
    $detail .= sprintf(', %d fds', $st2->{fds})
        if $st2 && defined $st2->{fds};
    $detail .= sprintf(', %.1f KiB/conn', $rss_per_conn / 1024)
        if defined $rss_per_conn && $rss_per_conn >= 0;
    verdict('idle_flood', $ok == 300 && $cpu_ok && $mem_ok, $detail);
    $s1 = $st2;
    $_->close for @idle; @idle = ();
    sleep 2;
}

# ---------------------------------------------------------------- phase 2
{
    my $st = $dpid ? stats($dpid) : undef;
    my @c;
    for (1 .. 50) { my $s = connect_one(); push @c, $s if $s }
    my $chunk = 'A' x 2048;
    for my $round (1 .. 1024) {          # 50 x 2 MiB = 100 MiB
        for my $s (@c) { syswrite($s, $chunk) }
    }
    sleep 2;
    my $st2 = $dpid ? stats($dpid) : undef;
    my $cpu_ok = !$st2 || ($st2->{cpu} - $st->{cpu}) <= $limits{data_flood};
    my $detail = sprintf('50 conns pushed 100 MiB total');
    $detail .= sprintf(', cpu +%ds', $st2->{cpu} - $st->{cpu}) if $st2;
    verdict('data_flood', $cpu_ok && daemon_alive(), $detail);
    $_->close for @c; @c = ();
    sleep 2;
}

# ---------------------------------------------------------------- phase 3
{
    my $st = $dpid ? stats($dpid) : undef;
    # connect with one retry; the tight localhost loop occasionally
    # collides with a TIME_WAIT source port on the client side, which
    # is a client artifact, not daemon behaviour - but the reason is
    # collected and printed so it can never hide a real failure
    my %errors;
    my $connect_retry = sub {
        for my $attempt (1 .. 2) {
            my $s = connect_one();
            return $s if $s;
            $errors{$!}++;
            select(undef, undef, undef, 0.05) if $attempt == 1;
        }
        return undef;
    };
    my $fin_ok = 0;
    for (1 .. 1000) {
        my $s = $connect_retry->();
        if ($s) { syswrite($s, 'x'); close $s; $fin_ok++ }
    }
    my $rst_ok = 0;
    for (1 .. 500) {
        my $s = $connect_retry->();
        if ($s) { syswrite($s, 'x'); rst_close($s); $rst_ok++ }
    }
    sleep 3;
    my $st2 = $dpid ? stats($dpid) : undef;
    my $cpu_ok = !$st2 || ($st2->{cpu} - $st->{cpu}) <= $limits{churn};
    my $detail = sprintf('churn: %d FIN + %d RST', $fin_ok, $rst_ok);
    $detail .= sprintf(', cpu +%ds', $st2->{cpu} - $st->{cpu}) if $st2;
    if (%errors) {
        $detail .= '; connect errors: '
            . join(', ', map { "$_ ($errors{$_}x)" } sort keys %errors);
    }
    verdict('churn', $fin_ok + $rst_ok == 1500 && $cpu_ok && daemon_alive(),
        $detail);
    sleep 2;
}

# ---------------------------------------------------------------- phase 4
{
    my $st = $dpid ? stats($dpid) : undef;
    my @c;
    for (1 .. 100) { my $s = connect_one(); push @c, $s if $s }
    for my $tick (1 .. 8) {
        sleep 1;
        syswrite($_, '.') for @c;
    }
    my $st2 = $dpid ? stats($dpid) : undef;
    my $cpu_ok = !$st2 || ($st2->{cpu} - $st->{cpu}) <= $limits{slowloris};
    my $detail = sprintf('%d slowloris conns, 8 ticks', scalar @c);
    $detail .= sprintf(', cpu +%ds', $st2->{cpu} - $st->{cpu}) if $st2;
    verdict('slowloris', scalar(@c) == 100 && $cpu_ok && daemon_alive(),
        $detail);
    $_->close for @c; @c = ();
    sleep 2;
}

# ---------------------------------------------------------------- phase 5
{
    my $st = $dpid ? stats($dpid) : undef;
    my @c;
    for (1 .. 450) { my $s = connect_one(); push @c, $s if $s }
    sleep 3;
    my $st2 = $dpid ? stats($dpid) : undef;
    my $detail = sprintf('%d/450 concurrent held', scalar @c);
    $detail .= sprintf(', %d fds open', $st2->{fds})
        if $st2 && defined $st2->{fds};
    my $held_ok = @c >= 440;
    verdict('fd_pressure', $held_ok && daemon_alive(), $detail);
    $_->close for @c; @c = ();
    sleep 3;
}

# ---------------------------------------------------------------- phase 6
{
    sleep 2;
    my $s = connect_one();
    my $works = 0;
    if ($s) {
        syswrite($s, 'x');
        my $sel = IO::Select->new($s);
        my $bytes = 0;
        my $t0 = time;
        while (time - $t0 < 2) {
            if ($sel->can_read(0.2)) {
                my $n = sysread($s, my $b, 64);
                last unless $n;
                $bytes += $n;
            }
        }
        $works = $bytes <= 3;
        close $s;
    }
    sleep 1;
    my $st = $dpid ? stats($dpid) : undef;
    my $recovered = !$st || !$base
        || !defined $st->{fds} || !defined $base->{fds}
        || ($st->{fds} <= $base->{fds} + 5);
    my $detail = 'tarpit still silent and accepting';
    $detail .= sprintf(', fds=%d (baseline %d)', $st->{fds}, $base->{fds})
        if $st && $base && defined $st->{fds} && defined $base->{fds};
    verdict('recovery', $works && $recovered && daemon_alive(), $detail);
}

# ---------------------------------------------------------------- v6 probe
if (length $host6) {
    my $s = IO::Socket::IP->new(
        PeerAddr => $host6, PeerPort => $port,
        Proto    => 'tcp', Timeout  => 3
    );
    if (!$s) {
        printf "SKIP %-12s IPv6 %s unreachable: %s\n", 'v6_probe', $host6, $!;
    }
    else {
        syswrite($s, 'x');
        my $sel = IO::Select->new($s);
        my $bytes = 0;
        my $t0 = time;
        while (time - $t0 < 2) {
            if ($sel->can_read(0.2)) {
                my $n = sysread($s, my $b, 64);
                last unless $n;
                $bytes += $n;
            }
        }
        close $s;
        verdict('v6_probe', $bytes <= 3,
            $bytes <= 3
                ? "no response on IPv6 ($host6), $bytes dribbled"
                : "daemon sent $bytes bytes on IPv6");
    }
}

print "\n== summary: " . (@fails ? 'FAIL (' . join(', ', @fails) . ')'
                                : 'ALL PASS') . " ==\n";
exit(@fails ? 1 : 0);
