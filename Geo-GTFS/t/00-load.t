#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'Geo::GTFS' );
}

diag( "Testing Geo::GTFS $Geo::GTFS::VERSION, Perl $], $^X" );
