#!perl -T

use Test::More tests => 1;

BEGIN {
	use_ok( 'Transit::MapMaker' );
}

diag( "Testing Transit::MapMaker $Transit::MapMaker::VERSION, Perl $], $^X" );
