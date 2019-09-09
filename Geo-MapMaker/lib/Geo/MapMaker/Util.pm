package Geo::MapMaker::Util;
use warnings;
use strict;
use Carp qw(croak);

our $VERSION;
BEGIN {
    $VERSION = '0.02';
}

use base 'Exporter';
use vars qw(@EXPORT @EXPORT_OK);

@EXPORT = qw();
@EXPORT_OK = qw(file_get_contents file_put_contents normalize_space);

use Text::Trim;

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

sub normalize_space {
    my ($string) = @_;
    $string = trim($string);
    $string =~ s{\s+}{ }g;
    return $string;
}

1;

