#!/usr/bin/env perl
use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;

$| = 1; # Autoflush für die Konsole

my $listen_ip   = '127.0.0.1';
my $listen_port = 8024;
my $last_cleanup = time();
my $cleanup_interval = 1800; # 30 Minuten in Sekunden

#########
# # /etc/pf.conf
#table <bruteforcers> persist
## Wer in der Liste ist, wird sofort ins generische TCP-Tarpit geschubst
#pass in quick on ext_if proto tcp from <bruteforcers> to any port { ssh, http, https } \
#    rdr-to 127.0.0.1 port 8024
## SSH-Überwachung: Wer mehr als 3 Verbindungen in 30 Sekunden aufbaut, fliegt auf die Liste
#pass in on ext_if proto tcp to any port ssh flags S/SA keep state \
#    (max-src-conn-rate 3/30, overload <bruteforcers> flush global)
## Webserver-Überwachung: Schutz vor schnellen HTTP-Scannern / Dir-Bustern
#pass in on ext_if proto tcp to any port { http, https } flags S/SA keep state \
#    (max-src-conn-rate 30/10, overload <bruteforcers> flush global)
##########

# Haupt-Socket erstellen
my $server = IO::Socket::INET->new(
    LocalAddr => $listen_ip,
    LocalPort => $listen_port,
    Proto     => 'tcp',
    Listen    => SOMAXCONN,
    ReuseAddr => 1
    ) or die "Konnte Socket nicht erstellen: $!\n";

print "Universelles Layer-4 TCP-Tarpit laeuft auf $listen_ip:$listen_port...\n";

my $selector = IO::Select->new($server);
my %connections;

while (1) {
    # Warte auf Ereignisse (max. 10 Sekunden)
    my @ready = $selector->can_read(10);

    foreach my $fh (@ready) {
        if ($fh == $server) {
            # Neue Verbindung
            my $client = $server->accept();
            if ($client) {
                my $ip = $client->peerhost();
                my $port = $client->peerport();
                print "[+] Bot gefangen: $ip:$port\n";
                
                $selector->add($client);
                $connections{$client} = { ip => $ip, port => $port, start_time => time() };
            }
        } else {
            # Ein Client-Socket hat Daten ODER hat die Verbindung getrennt
            my $buffer;
            # Wir versuchen 1 Byte zu lesen, um den Status zu prüfen
            my $res = sysread($fh, $buffer, 1);
            
            if (defined $res && $res > 0) {
                # Der Bot hat uns Daten geschickt! 
                # WIR IGNORIEREN SIE. Dadurch läuft sein TCP-Fenster voll.
                # Wir entfernen den Socket NICHT aus dem Selector, 
                # damit wir spätere FIN/RST-Pakete mitbekommen.
                next; 
            } else {
                # $res ist 0 (EOF) oder undef (Fehler) -> Der Bot hat WIRKLICH aufgegeben
                my $ip = $connections{$fh}->{ip};
                print "[-] Bot hat WIRKLICH aufgegeben oder Timeout: $ip\n";
                $selector->remove($fh);
                delete $connections{$fh};
                close($fh);
            }
        }
    }

    # Zykliches Aufräumen (alle 30 Min)
    my $now = time();
    if ($now - $last_cleanup >= $cleanup_interval) {
        print "[*] Starte zyklisches Aufräumen von alten Verbindungen...\n";
        while (my ($fh, $data) = each %connections) {
            if ($now - $data->{start_time} >= $cleanup_interval) {
                print "[*] Kicke passiven Bot nach 30 Min: $data->{ip}:$data->{port}\n";
                $selector->remove($fh);
                close($fh);
                delete $connections{$fh};
            }
        }
        $last_cleanup = $now;
    }
}
