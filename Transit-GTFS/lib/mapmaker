#!/usr/bin/perl
use warnings;
use strict;
use Transit::GTFS;
use Transit::MapMaker;
use Getopt::Long;
use YAML;

our $verbose = 0;

sub usage {
	print(<<"END");
usage: $0 MAPNAME update
       $0 MAPNAME force-update
       $0 MAPNAME repopulate
       $0 MAPNAME force-repopulate
       $0 MAPNAME download-map-data
       $0 MAPNAME refresh-osm-styles
       $0 MAPNAME update-transit-stops
       $0 MAPNAME update-transit-routes
  -h, --help
  -v, --version
END
}

Getopt::Long::Configure("bundling", "gnu_compat");
Getopt::Long::GetOptions("v|verbose"        => sub { $verbose += 1; },
			 "h|help"           => sub { usage(); exit(0); });

my $maps = YAML::LoadFile("maps.yaml");
if (!$maps) {
	die("No maps.yaml data.\n");
}

my ($mapname, $command, @args) = @ARGV;
my $mapinfo = $maps->{$mapname};
if (!$mapinfo) {
	die("No mapinfo for map '$mapname'\n");
}
my $mm = Transit::MapMaker->new(%$mapinfo);

if (!defined $command) {
	die("Not gonna do anything.\n");
}
elsif ($command eq "update") {
	$mm->gtfs()->update();
	$mm->gtfs()->repopulate();
	$mm->create_all_layers();
	$mm->download_map_data();
	$mm->plot_osm_layers();
	$mm->update_transit_stops();
	$mm->update_transit_routes();
	$mm->update_grid();
}
elsif ($command eq "gtfs-update") {
	$mm->gtfs()->update();
}
elsif ($command eq "force-gtfs-update") {
	$mm->gtfs()->force_update();
}
elsif ($command eq "gtfs-repopulate") {
	$mm->gtfs()->repopulate();
}
elsif ($command eq "force-gtfs-repopulate") {
	$mm->gtfs()->force_repopulate();
}
elsif ($command eq "update-osm-map") {
	$mm->create_all_layers();
	$mm->download_map_data();
	$mm->plot_osm_layers();
}
elsif ($command eq "update-osm-map-styles") {
	$mm->create_all_layers();
	$mm->refresh_osm_styles();
}
elsif ($command eq "update-transit-stops") {
	$mm->create_all_layers();
	$mm->update_transit_stops();
}
elsif ($command eq "update-transit-routes") {
	$mm->create_all_layers();
	$mm->update_transit_routes();
}
elsif ($command eq "update-transit") {
	$mm->create_all_layers();
	$mm->update_transit_stops();
	$mm->update_transit_routes();
}
elsif ($command eq "update-grid") {
	$mm->create_all_layers();
	$mm->update_grid();
}
elsif ($command eq "update-map-border") {
	$mm->create_all_layers();
	$mm->update_map_border();
}
else {
	die("No such command: '$command'\n");
}

