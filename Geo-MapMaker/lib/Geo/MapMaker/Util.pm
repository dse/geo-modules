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
		    file_put_contents);

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

1;

