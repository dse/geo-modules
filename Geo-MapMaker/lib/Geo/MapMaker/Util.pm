package Geo::MapMaker::Util;
use warnings;
use strict;
use Carp qw(croak);

our $VERSION;
BEGIN {
    $VERSION = '0.01';
}

our @EXPORT = qw();
our @EXPORT_OK = qw(file_get_contents
		    file_put_contents
		    move_line_away);

sub file_get_contents {		# php-like lol
    my ($filename) = @_;
    open(my $fh, "<", $filename) or die("Cannot read $filename: $!\n");
    return join("", <$fh>);
}

sub file_put_contents {		# php-like lol
    my ($filename, $contents) = @_;
    open(my $fh, ">", $filename) or die("Cannot write $filename: $!\n");
    print $fh $contents;
}

use File::Basename qw(dirname);
BEGIN {
    require Inline;
    if ($ENV{USE_INLINE_TEMP_CACHE}) {
	import Inline (C       => file_get_contents(dirname(__FILE__) . "/util.c"));
    } else {
	import Inline (C       => file_get_contents(dirname(__FILE__) . "/util.c"),
		       VERSION => $VERSION,
		       NAME    => "Geo::MapMaker::Util");
    }
}

1;

