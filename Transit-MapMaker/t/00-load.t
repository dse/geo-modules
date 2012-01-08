#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'Transit::GTFS' );
}

diag( "Testing Transit::GTFS $Transit::GTFS::VERSION, Perl $], $^X" );
