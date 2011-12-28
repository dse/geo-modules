#!/usr/bin/perl
use warnings;
use strict;
use Transit::GTFS;
use Transit::MapMaker;
use Getopt::Long;

our $verbose          = 0;
our $force_repopulate = 0;
our $force_update     = 0;

sub usage {
	print(<<"END");
usage: $0 ...
  -h, --help
  -v, --version
END
}

Getopt::Long::Configure("bundling", "gnu_compat");
Getopt::Long::GetOptions("v|verbose"        => sub { $verbose += 1; },
			 "h|help"           => sub { usage(); exit(0); });

my $gtfs = Transit::GTFS->new("http://googletransit.ridetarc.org/feed/google_transit.zip", 
			      { verbose => $verbose });

my ($west, $south, $east, $north) = (-85.92, 37.98, -85.36, 38.42);
my $mm = Transit::MapMaker->new(filename => "map.svg",
				south => $south,
				north => $north,
				west  => $west,
				east  => $east,
				paper_width  => 22 * 90,
				paper_height => 17 * 90,
				paper_margin => 0.25 * 90);

my ($command, @args) = @ARGV;

if (!defined $command) {
	die("Not gonna do anything.\n");
}
elsif ($command eq "update") {
	$gtfs->update();
}
elsif ($command eq "force-update") {
	$gtfs->force_update();
}
elsif ($command eq "repopulate") {
	$gtfs->repopulate();
}
elsif ($command eq "force-repopulate") {
	$gtfs->force_repopulate();
}
elsif ($command eq "download-test-map-data") {
	my $mm = Transit::MapMaker->new(filename => "smaller-map.svg",
					south => 38.20,
					north => 38.25,
					west  => -85.80,
					east  => -85.74,
				map_data_south => $south,
				map_data_north => $north,
				map_data_west  => $west,
				map_data_east  => $east,
					paper_width  => 8.5 * 90,
					paper_height => 11 * 90,
					paper_margin => 0.25 * 90);
	$mm->download_map_data();
	$mm->plot_osm_layers();
}
elsif ($command eq "download-map-data") {
	$mm->download_map_data();
	$mm->plot_osm_layers();
}
else {
	die("No such command: '$command'\n");
}

