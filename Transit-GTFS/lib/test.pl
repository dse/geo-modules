#!/usr/bin/perl
use warnings;
use strict;
use Transit::GTFS;
use Getopt::Long;

our $verbose          = 0;
our $force_repopulate = 0;
our $force_update     = 0;

sub usage {
	print(<<"END");
usage: $0 ...
  -h, --help
  -v, --version
  -f, --force
END
}

Getopt::Long::Configure("bundling", "gnu_compat");
Getopt::Long::GetOptions("v|verbose"        => sub { $verbose += 1; },
			 "force-repopulate" => \$force_repopulate,
			 "force-update"     => \$force_update,
			 "f|force"          => \$force_repopulate,
			 "force-all"        => sub { $force_repopulate = 1;
						     $force_update = 1; },
			 "h|help"           => sub { usage(); exit(0); });

my $gtfs = Transit::GTFS->new("http://googletransit.ridetarc.org/feed/google_transit.zip", 
			      { verbose => $verbose,
				force_repopulate => $force_repopulate,
				force_update     => $force_update,
			      });

