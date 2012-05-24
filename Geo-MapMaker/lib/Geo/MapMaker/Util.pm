package Geo::MapMaker::Util;
use warnings;
use strict;
use Carp qw(croak);

our @EXPORT = qw(file_get_contents
		 file_put_contents
		 move_line_away
		 %NS);

our @EXPORT_OK = qw(file_get_contents
		    file_put_contents
		    move_line_away
		    %NS);

our %NS;
$NS{"svg"}      = "http://www.w3.org/2000/svg";
$NS{"inkscape"} = "http://www.inkscape.org/namespaces/inkscape";
$NS{"sodipodi"} = "http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd";
$NS{"mapmaker"} = "http://webonastick.com/namespaces/transit-mapmaker";

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
use Inline C => file_get_contents(dirname(__FILE__) . "/util.c");

1;

