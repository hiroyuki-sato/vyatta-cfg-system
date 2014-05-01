#!/usr/bin/perl
#
# Module: vyatta-snmp.pl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Stig Thormodsrud
# Date: October 2007
# Description: Script to glue vyatta cli to snmp daemon
#
# **** End License ****
#

use strict;
use warnings;

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Config;
use Vyatta::Misc;
use NetAddr::IP;
use Getopt::Long;
use File::Copy;
use Socket;
use Socket6;

my $mibdir    = '/opt/vyatta/share/snmp/mibs';
my $snmp_init = 'invoke-rc.d snmpd';
my $snmp_conf = '/etc/snmp/snmpd.conf';
my $snmp_client = '/etc/snmp/snmp.conf';
my $snmp_tmp  = "/tmp/snmpd.conf.$$";
my $snmp_snmpv3_user_conf = '/usr/share/snmp/snmpd.conf';
my $snmp_snmpv3_createuser_conf = '/var/lib/snmp/snmpd.conf';
my $versionfile = '/opt/vyatta/etc/version';
my $local_agent = 'unix:/var/run/snmpd.socket';
my $password_file = '/config/snmp/superuser_pass';

my $snmp_level = 'service snmp';

sub snmp_running {
    open (my $pidf, '<', "/var/run/snmpd.pid")
	or return;
    my $pid = <$pidf>;
    close $pidf;

    chomp $pid;
    my $exe = readlink "/proc/$pid/exe";

    return (defined($exe) && $exe eq "/usr/sbin/snmpd");
}

sub snmp_stop {
    system("$snmp_init stop > /dev/null 2>&1");
}

sub snmp_start {
    # we must stop snmpd first for creating vyatta user
    system("$snmp_init stop > /dev/null 2>&1");
    open (my $fh, '>', $snmp_tmp)
	or die "Couldn't open $snmp_tmp - $!";

    select $fh;
    snmp_get_constants();
    snmp_get_values();
    snmp_get_traps();
    close $fh;
    select STDOUT;

    snmp_client_config();

    move($snmp_tmp, $snmp_conf)
	or die "Couldn't move $snmp_tmp to $snmp_conf - $!";
}

sub get_version {
    my $version = "unknown-version";

    if (open (my $f, '<', $versionfile)) {
	while (<$f>) {
	    chomp;
	    if (m/^Version\s*:\s*(.*)$/) {
		$version = $1;
		last;
	    }
	}
	close $f;
    }
    return $version;
}

# convert address to snmpd transport syntax
sub transport_syntax {
    my ($addr, $port) = @_;
    my $ip = new NetAddr::IP $addr;
    die "$addr: not a valid IP address" unless $ip;

    my $version = $ip->version();
    return "udp:$addr:$port"    if ($version == 4);
    return "udp6:[$addr]:$port" if ($version == 6);
    die "$addr: unknown IP version $version";
}

# Test if IPv6 is possible by opening a socket
sub ipv6_disabled {
    socket ( my $s, PF_INET6, SOCK_DGRAM, 0)
	or return 1;
    close($s);
    return;
}

# Find SNMP agent listening addresses
sub get_listen_address {
    my $config = new Vyatta::Config;
    my @listen;

    $config->setLevel('service snmp listen-address');
    my @address = $config->listNodes();

    if(@address) {
	foreach my $addr (@address) {
	    my $port = $config->returnValue("$addr port");
	    push @listen, transport_syntax($addr, $port);
	}
    } else {
	# default if no address specified
	@listen = ( 'udp:161' );
	push @listen, 'udp6:161' unless ipv6_disabled();
	return @listen;
    }

    return @listen;
}

sub snmp_get_constants {
    my $version = get_version();
    my $now = localtime;
    my @addr = get_listen_address();

    # add local unix domain target for use by operational commands
    unshift @addr, $local_agent;

    print "# autogenerated by vyatta-snmp.pl on $now\n";
    print "sysDescr Vyatta $version\n";
    print "sysObjectID 1.3.6.1.4.1.30803\n";
    print "sysServices 14\n";
    print "master agentx\n";	# maybe needed by lldpd
    print "agentaddress ", join(',',@addr), "\n";

    # add hook to read IF-MIB::ifAlias from sysfs
    print "pass .1.3.6.1.2.1.31.1.1.1.18 /opt/vyatta/sbin/if-mib-alias\n";

    print "smuxpeer .1.3.6.1.4.1.3317.1.2.2\n";		# ospfd
    print "smuxpeer .1.3.6.1.4.1.3317.1.2.5\n";		# bgpd
    print "smuxpeer .1.3.6.1.4.1.3317.1.2.3\n";		# ripd
    print "smuxpeer .1.3.6.1.4.1.3317.1.2.9\n";		# mribd
    print "smuxpeer .1.3.6.1.2.1.83\n";			# mribd
    print "smuxpeer .1.3.6.1.4.1.3317.1.2.8\n";		# pimd
    print "smuxpeer .1.3.6.1.2.1.157\n";		# pimd
    print "smuxsocket localhost\n";
}

# generate a random character hex string
sub randhex {
    my $length = shift;
    return join "", map { unpack "H*", chr(rand(256)) } 1..($length/2);
}

# output snmpd.conf file syntax for community
sub print_community {
    my ($config, $community) = @_;
    my $ro = $config->returnValue('authorization');
    $ro = 'ro' unless $ro;

    my @clients = $config->returnValues('client');
    my @networks = $config->returnValues('network');

    my @restriction = (@clients, @networks);
    if (!@restriction) {
	print $ro . "community $community\n";
	print $ro . "community6 $community\n" unless ipv6_disabled();
	return;
    }

    foreach my $addr (@restriction) {
	my $ip = new NetAddr::IP $addr;
	die "$addr: Not a valid IP address" unless $ip;

	if ($ip->version() == 4) {
	    print $ro . "community $community $addr\n";
	} elsif ($ip->version() == 6) {
	    print $ro . "community6 $community $addr\n";
	} else {
	    die "$addr: bad IP version ", $ip->version();
	}
    }
}

sub snmp_get_values {
    my $config = new Vyatta::Config;

    my @communities = $config->listNodes("service snmp community");
    foreach my $community (@communities) {
	$config->setLevel("service snmp community $community");
	print_community($config, $community);
    }

    $config->setLevel("service snmp smuxpeer");
    my @smuxpeers = $config->returnValues();
    foreach my $smuxpeer (@smuxpeers) {
        print "smuxpeer $smuxpeer \n";
    }

    $config->setLevel($snmp_level);
    my $contact = $config->returnValue("contact");
    if (defined $contact) {
	print "syscontact \"$contact\" \n";
    }

    my $description = $config->returnValue("description");
    if (defined $description) {
	print "sysdescr \"$description\" \n";
    }

    my $location = $config->returnValue("location");
    if (defined $location) {
	print "syslocation \"$location\" \n";
    }
}

sub snmp_get_traps {
    my $config = new Vyatta::Config;
    $config->setLevel($snmp_level);

    # linkUp/Down configure the Event MIB tables to monitor
    # the ifTable for network interfaces being taken up or down
    # for making internal queries to retrieve any necessary information

    # create an internal snmpv3 user of the form 'vyattaxxxxxxxxxxxxxxxx'
    my $vyatta_user = "vyatta" . randhex(16);
    snmp_create_snmpv3_user($vyatta_user);
    snmp_write_snmpv3_user($vyatta_user);
    print "iquerySecName $vyatta_user\n";

    # Modified from the default linkUpDownNotification
    # to include more OIDs and poll more frequently
    print <<EOF;
notificationEvent  linkUpTrap    linkUp   ifIndex ifDescr ifType ifAdminStatus ifOperStatus
notificationEvent  linkDownTrap  linkDown ifIndex ifDescr ifType ifAdminStatus ifOperStatus
monitor  -r 10 -e linkUpTrap   "Generate linkUp" ifOperStatus != 2
monitor  -r 10 -e linkDownTrap "Generate linkDown" ifOperStatus == 2
EOF

    my @trap_targets = $config->listNodes("trap-target");
    return unless @trap_targets;

    foreach my $trap_target (@trap_targets) {
	my $port = $config->returnValue("trap-target $trap_target port");
	my $community
	    = $config->returnValue("trap-target $trap_target community");

        print "trap2sink $trap_target";
	print ":$port" if $port;
	print " $community" if $community;
	print "\n";
    }
}

# Configure SNMP client parameters
sub snmp_client_config {
    my $config = new Vyatta::Config;
    $config->setLevel($snmp_level);

    open (my $cf, '>', $snmp_client)
	or die "Couldn't open $snmp_client - $!";

    my $version = get_version();
    my $now = localtime;
    print {$cf}  "# autogenerated by vyatta-snmp.pl on $now\n";

    my $trap_source = $config->returnValue('trap-source');
    print {$cf} "clientaddr $trap_source\n" if ($trap_source);
    close $cf;
}

sub snmp_create_snmpv3_user {

    my $vyatta_user = shift;
    my $passphrase = randhex(32);

    my $createuser = "createUser $vyatta_user MD5 \"$passphrase\" DES";
    open(my $fh, '>', $snmp_snmpv3_createuser_conf) || die "Couldn't open $snmp_snmpv3_createuser_conf - $!";
    print $fh $createuser;
    close $fh;

    open(my $pass_file, '>', $password_file) || die "Couldn't open $password_file - $!";
    print $pass_file $passphrase;
    close $pass_file;
}

sub snmp_write_snmpv3_user {

    my $vyatta_user = shift;
    my $user = "rwuser $vyatta_user\n";
    open(my $fh, '>', $snmp_snmpv3_user_conf) || die "Couldn't open $snmp_snmpv3_user_conf - $!";
    print $fh $user;
    close $fh;
}


#
# main
#
my $update_snmp;
my $stop_snmp;

GetOptions("update-snmp!" => \$update_snmp,
           "stop-snmp!"   => \$stop_snmp);

snmp_start() if ($update_snmp);
snmp_stop()  if ($stop_snmp);
