#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'Geo::MapMaker' );
}

diag( "Testing Geo::MapMaker $Geo::MapMaker::VERSION, Perl $], $^X" );
