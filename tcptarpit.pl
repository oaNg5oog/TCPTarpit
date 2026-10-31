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

$| = 1;    # autoflush, output is piped to syslog via daemon(8) -l

# Configuration: /etc/tcptarpit.conf overrides these defaults.
my $config_file = shift(@ARGV) // '/etc/tcptarpit.conf';
my %config = (
    listen_ip        => '127.0.0.1',
    listen_port      => 8024,
    cleanup_interval => 1800,    # seconds between cleanup passes
    max_age          => 1800,    # seconds before a connection is closed
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
}

# main listening socket
my $server = IO::Socket::INET->new(
    LocalAddr => $config{listen_ip},
    LocalPort => $config{listen_port},
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    ReuseAddr => 1
    ) or die "cannot create socket: $!\n";

print "generic layer-4 TCP tarpit running on $config{listen_ip}:$config{listen_port}"
    . " (config: $config_file)\n";

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
                    print "[-] bot vanished before capture\n";
                    close($client);
                    next;
                }
                print "[+] bot trapped: $ip:$port\n";

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
                    print "[-] bot gave up: $ip\n";
                } else {
                    print "[-] bot aborted: $ip ($!)\n";
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
        print "[*] starting periodic cleanup of stale connections\n";
        while (my ($key, $data) = each %connections) {
            if ($now - $data->{start_time} >= $config{max_age}) {
                printf "[*] kicking bot after %d s hold time: %s:%s\n",
                    $config{max_age}, $data->{ip}, $data->{port};
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
