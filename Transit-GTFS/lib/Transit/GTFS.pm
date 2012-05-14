package Transit::GTFS;

use warnings;
use strict;
	
=head1 NAME
	
Transit::GTFS - Maintain a SQLite database of GTFS data
	
=head1 VERSION
	
Version 0.02
	
=cut
	

our $VERSION = '0.02';
	
	
=head1 SYNOPSIS
	
    use Transit::GTFS;

    my $gtfs = Transit::GTFS->new("http://developer.trimet.org/schedule/gtfs.zip");

    $gtfs->update();		# update mirror if needed
    $gtfs->repopulate();	# repopulate data if needed

    my $dbh = $gtfs->dbh();
	
=head1 DESCRIPTION

Transit::GTFS creates and maintains a SQLite database of GTFS data.
You supply a GTFS feed URL, and this module downloads it, extracts all
the data from it, creates a SQLite database, populates it with that
data, and gives you a database handle.

=cut


use fields qw(url
	      data
	      verbose
	      _dbh
	      _dir
	      _zip_filename
	      _sqlite_filename);

=head1 CONSTRUCTOR

The following is the usual scenario for creating an object of this
class:

    my $feed_url = "http://developer.trimet.org/schedule/gtfs.zip";
    my $gtfs = Transit::GTFS->new($feed_url);

You usually just pass one argument to the constructor: a URL pointing
directly to the transit feed's ZIP file.  That argument is required.

See L</"SEE ALSO"> for lists of transit agency feeds worldwide.

You may also pass an optional options argument in the form of an
anonymous hash:

    my $options = {
        verbose => 1
    };
    my $gtfs = Transit::GTFS->new($feed_url, $options);

=cut

our $verbose = 0;

sub new {
	my ($class, $url, $options) = @_;
	my $self = fields::new($class);
	$self->{url} = $url;
	$self->{verbose} = $verbose;
	$self->{data} = {};
	if ($options) {
		while (my ($k, $v) = each(%$options)) {
			$self->{$k} = $v;
		}
	}
	return $self;
}

sub DESTROY {
	my ($self) = @_;
	$self->_DESTROY_DBH();	# stfu, DBI!
}

use LWP::Simple;
use URI;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Carp qw(croak);
use DBI;
use File::Path qw(mkpath);
use File::Basename;

sub update {
	my ($self) = @_;
	my $url = $self->{url};
	my $zip_filename = $self->get_zip_filename();

	mkpath(dirname($zip_filename));
	print STDERR ("GET $url ... ") if $self->{verbose};
	my $rc = mirror($url, $zip_filename);
	print STDERR ("$rc\n") if $self->{verbose};

	if ($rc == RC_NOT_MODIFIED) {
		# nothing further needs to be done, i guess.
	}
	elsif (is_success($rc)) {
		$self->_flag_as_dirty(); # force repopulation
	}
	else {
		croak("Failure: $url => $rc\n");
	}
	$self->commit();
}

sub force_update {
	my ($self) = @_;
	my $url = $self->{url};

	# force redownload
	my $zip_filename = $self->get_zip_filename();
	unlink($zip_filename);

	$self->update();
}

sub repopulate {
	my ($self, $force) = @_;
	if (!$force) {
		my $zip_filename = $self->get_zip_filename();
		my $file_mtime = (stat($zip_filename))[9];
		if (!$file_mtime) {
			die("could not get mtime of local copy of GTFS data " .
			    "($zip_filename): $!");
		}
		my $populated_mtime = $self->get_populated_mtime();
		if ($populated_mtime &&
		    $file_mtime == $populated_mtime) {
			return;
		}
	}
	$self->_create_tables();
	$self->_repopulate_tables();
	$self->_update_populated_mtime();

	print STDERR ("Committing database transaction ... ") if $self->{verbose};
	$self->commit();
	print STDERR ("done.\n") if $self->{verbose};
}

sub force_repopulate {
	my ($self) = @_;
	$self->_flag_as_dirty();
	$self->repopulate(1);
}

sub get_populated_mtime {
	my ($self) = @_;
	my $dbh = $self->dbh();
	my $mtime;
	eval {
		($mtime) = $dbh->selectrow_array("select mtime from mtime");
	};
	return $mtime;
}

sub drop_tables {
	my ($self) = @_;
	my $dbh = $self->dbh();
	print STDERR ("Dropping database tables ... ") if $self->{verbose};
	$dbh->do("drop table if exists agency;");
	$dbh->do("drop table if exists stops;");
	$dbh->do("drop table if exists routes;");
	$dbh->do("drop table if exists trips;");
	$dbh->do("drop table if exists stop_times;");
	$dbh->do("drop table if exists calendar;");
	$dbh->do("drop table if exists calendar_dates;");
	$dbh->do("drop table if exists fare_attributes;");
	$dbh->do("drop table if exists fare_rules;");
	$dbh->do("drop table if exists shapes;");
	$dbh->do("drop table if exists frequencies;");
	$dbh->do("drop table if exists transfers;");
	$dbh->do("drop table if exists feed_info;");
	$dbh->do("drop table if exists mtime;");
	print STDERR ("done.\n") if $self->{verbose};
}

sub _create_tables {
	my ($self) = @_;
	my $dbh = $self->dbh();
	print STDERR ("Creating database tables ...") if $self->{verbose};
	$dbh->do(<<"END");
create table if not exists mtime (
	mtime             integer
);
END
	$dbh->do(<<"END");
create table if not exists agency (
	agency_id		varchar(64)	primary key,
		-- optional if we have only one agency
	agency_name		varchar(64)	not null,
	agency_url		varchar(256)	not null,
	agency_timezone		varchar(256)	not null,
	agency_lang		varchar(2),
	agency_phone		varchar(32),
	agency_fare_url		varchar(256)
);
END
	$dbh->do(<<"END");
create table if not exists stops (
	stop_id			varchar(16)	primary key not null,
		-- internal codes
	stop_code		varchar(16),
		-- displayed to users, like for telephone services
	stop_name		varchar(64)	not null,
	stop_desc		text,
	stop_lat		real		not null, -- WGS84
	stop_lon		real		not null, -- WGS84
	zone_id			varchar(16),
		-- references fare_attributes(fare_id)
		-- required when using fare_rules.txt
	stop_url		varchar(256),
	location_type		integer		default 0,
		-- 0 = stop
		-- 1 = station with one or more stops
	parent_station		varchar(16)	references stops(stop_id)
);
END
	$dbh->do(<<"END");
create table if not exists routes (
	route_id		varchar(16)	primary key not null,
	agency_id		varchar(16)	references agency(agency_id),
	route_short_name	varchar(16)	not null,
		-- e.g., "32", "100X", "Green"
	route_long_name		varchar(64)	not null,
	route_desc		text,
	route_type		integer		not null,
		-- 0 = tram, streetcar, light rail;
		-- 1 = subway, metro;
		-- 2 = rail (intercity or long-distance);
		-- 3 = bus;
		-- 4 = ferry;
		-- 5 = cable car;
		-- 6 = gondola;
		-- 7 = funicular
	route_url		varchar(256),
	route_color		varchar(6),
	route_text_color	varchar(6)
);
END
	$dbh->do(<<"END");
create table if not exists trips (
	route_id		varchar(16)	not null
						references routes(route_id),
	service_id		varchar(16)	not null,
		-- references calendar.txt or calendar_dates.txt
	trip_id			varchar(16)	not null unique,
	trip_headsign		varchar(64),
	trip_short_name		varchar(64),
	direction_id		integer,
		-- for distinguishing between bi-directional trips
		-- within the same route_id:
		--   0 = one direction (e.g., outbound);
		--   1 = opposite direction (e.g., inbound)
	block_id		varchar(16),
		-- block = 2+ sequential trips with same vehicle
	shape_id		varchar(16)	references shapes(shape_id)
);
END
	$dbh->do(<<"END");
create table if not exists stop_times (
	trip_id			varchar(16)	not null
						references trips(trip_id),
	arrival_time		varchar(8)	not null,
		-- measured from 'noon minus 12 hours'
	departure_time		varchar(8)	not null,
		-- measured from 'noon minus 12 hours'
	stop_id			varchar(16)	not null
						references stops(stop_id),
	stop_sequence		integer		not null,
	stop_headsign		varchar(64),
	pickup_type		integer		default 0,
		-- 0 = regularly scheduled pickup;
		-- 1 = no pickup available;
		-- 2 = must phone agency;
		-- 3 = must coordinate with driver
	drop_off_type		integer		default 0,
		-- 0 = regularly scheduled dropoff;
		-- 1 = no dropoff available;
		-- 2 = must phone agency;
		-- 3 = must coordinate with driver
	shape_dist_traveled	real
);
END
	$dbh->do(<<"END");
create table if not exists calendar (
	service_id		varchar(16)	not null,
		-- FIXME: references trips(service_id)
	monday			integer		not null,
	tuesday			integer		not null,
	wednesday		integer		not null,
	thursday		integer		not null,
	friday			integer		not null,
	saturday		integer		not null,
	sunday			integer		not null,
	start_date		varchar(8)	not null, -- 'YYYYMMDD'
	end_date		varchar(8)	not null  -- 'YYYYMMDD'
);
END
	$dbh->do(<<"END");
create table if not exists calendar_dates (
	service_id		varchar(16)	not null,
		-- FIXME: references trips(service_id)
	date			varchar(8)	not null, -- 'YYYYMMDD'
	exception_type		integer		not null
		-- 1 = added;
		-- 2 = removed
);
END
	$dbh->do(<<"END");
create table if not exists fare_attributes (
	fare_id			varchar(16)	primary key not null,
	price			real		not null,
	currency_type		varchar(3)	not null, -- e.g., 'USD'
	payment_method		integer		not null,
		-- 0 = paid on board;
		-- 1 = paid before boarding
	transfers		integer,
		-- 0 = no transfers pemitted on this fare;
		-- 1 = passenger may transfer once;
		-- 2 = passenger may transfer twice;
		-- empty = unlimited transfers are permitted
		--   required per GTFS spec, but do not specify 'not null' here
	transfer_duration	integer		-- in seconds
);
END
	$dbh->do(<<"END");
create table if not exists fare_rules (
	fare_id			varchar(16)	primary key not null,
	route_id		varchar(16),	-- FIXME: references routes.txt
	origin_id		varchar(16),	-- FIXME: references stops.txt
	destination_id		varchar(16),	-- FIXME: references stops.txt
	contains_id		varchar(16)	-- FIXME: references stops.txt
);
END
	$dbh->do(<<"END");
create table if not exists shapes (
	shape_id		varchar(16)	not null, -- NOT unique
	shape_pt_lat		real		not null, -- WGS84
	shape_pt_lon		real		not null, -- WGS84
	shape_pt_sequence	integer		not null,
	shape_dist_traveled	real
);
END
	$dbh->do(<<"END");
create table if not exists frequencies (
	trip_id			varchar(16)	not null,
		-- FIXME: references trips.txt
	start_time		varchar(8)	not null,
	end_time		varchar(8)	not null,
	headway_secs		integer		not null, -- in seconds
	exact_times		integer		not null default 0
		-- 0 = frequency-based trips are not exactly scheduled
		-- 1 = exactly scheduled:
		--     trip_start_time = start_time + x * headway_secs
		--       for all x in (0, 1, 2, ...)
		--       where trip_start_time < end_time
);
END
	$dbh->do(<<"END");
create table if not exists transfers (
	from_stop_id		varchar(16)	not null
						references stops(stop_id),
	to_stop_id		varchar(16)	not null
						references stops(stop_id),
	transfer_type		integer		default 0,
	min_transfer_time	integer		-- in seconds
);
END
	$dbh->do(<<"END");
create table if not exists feed_info (
	feed_publisher_name	varchar(64)	not null,
	feed_publisher_url	varchar(256)	not null,
	feed_lang		varchar(32)	not null,
		-- IETF BCP 47 language code
	feed_start_date		varchar(8),
	feed_end_date		varchar(8),
	feed_version		varchar(64)
);
END

	print STDERR ("Creating indexes ... ") if $self->{verbose};
	$dbh->do(<<"END");
create index if not exists idx_shapes_id on shapes(shape_id);
END
	$dbh->do(<<"END");
create index if not exists idx_shapes_pt_sequence on shapes(shape_pt_sequence);
END
	$dbh->do(<<"END");
create index if not exists idx_trips_route_id on trips(route_id);
END
	$dbh->do(<<"END");
create index if not exists idx_trips_shape_id on trips(shape_id);
END
	$dbh->do(<<"END");
create index if not exists idx_stop_times_trip_id on stop_times(trip_id);
END

	$dbh->do(<<"END");
create index if not exists idx_trip_id on trips(trip_id);
END
	$dbh->do(<<"END");
create index if not exists idx_stop_times_stop_id on stop_times(stop_id);
END
	$dbh->do(<<"END");
create index if not exists idx_stop_id on stops(stop_id);
END
	$dbh->do(<<"END");
create index if not exists idx_stop_name on stops(stop_name);
END
	$dbh->do(<<"END");
create index if not exists idx_stop_code on stops(stop_code);
END
	$dbh->do(<<"END");
create index if not exists idx_route_id on routes(route_id);
END
	$dbh->do(<<"END");
create index if not exists idx_route_short_name on routes(route_short_name);
END

	print STDERR ("done.\n") if $self->{verbose};
}

sub _repopulate_tables {
	my ($self) = @_;
	my $zip_filename = $self->get_zip_filename();
	
	my $zip = Archive::Zip->new();
	unless ($zip->read($zip_filename) == AZ_OK) {
		die("Error reading $zip_filename\n");
	}

	$self->_repopulate_data($zip, "agency", 1);
	$self->_repopulate_data($zip, "stops", 1);
	$self->_repopulate_data($zip, "routes", 1);
	$self->_repopulate_data($zip, "trips", 1);
	$self->_repopulate_data($zip, "stop_times", 1);
	$self->_repopulate_data($zip, "calendar", 1);
	$self->_repopulate_data($zip, "calendar_dates");
	$self->_repopulate_data($zip, "fare_attributes");
	$self->_repopulate_data($zip, "fare_rules");
	$self->_repopulate_data($zip, "shapes");
	$self->_repopulate_data($zip, "frequencies");
	$self->_repopulate_data($zip, "transfers");
	$self->_repopulate_data($zip, "feed_info");
}

use Archive::Zip::MemberRead;
use Text::CSV;

sub _repopulate_data {
	my ($self, $zip, $table, $required) = @_;

	my $file_name = "$table.txt";
	my $fullpath = $self->get_dir() . "/" . $file_name;
	my $member = $zip->memberNamed($file_name) // $zip->memberNamed("google_transit/$file_name");
	if (!$member) {
		if ($required) {
			die("member '$member' not found");
		}
		else {
			return;
		}
	}
	if ($member->extractToFileNamed($fullpath) != AZ_OK) {
		die("could not extract member $file_name to $fullpath");
	}
	open(my $fh, "<", $fullpath) or die("cannot read $fullpath: $!\n");
	my $csv = Text::CSV->new ({ binary => 1 });
	my $fields = $csv->getline($fh);
	die("no fields in $fullpath\n") unless $fields or scalar(@$fields);

	my $dbh = $self->dbh();

	print STDERR ("deleting rows from $table ...") if $self->{verbose};
	$dbh->do("delete from $table;");
	print STDERR ("done.\n") if $self->{verbose};

	print STDERR ("(re)populating into $table ...\n") if $self->{verbose};
	my $sql = sprintf("insert into $table(%s) values(%s);",
			  join(", ", @$fields),
			  join(", ", ('?') x scalar(@$fields)));
	my $sth = $dbh->prepare($sql);
	my $rows = 0;
	while (defined(my $row = $csv->getline($fh))) {
		$sth->execute(@$row);
		++$rows;
		print STDERR ("  $rows rows\r") if
			$self->{verbose} && $rows % 100 == 0;
	}
	print STDERR ("  done; inserted $rows rows.\n") if $self->{verbose};
	return;
}

sub _update_populated_mtime {
	my ($self, $mtime) = @_;
	if (!defined $mtime) {
		my $zip_filename = $self->get_zip_filename();
		my @stat = stat($zip_filename);
		$mtime = (stat($zip_filename))[9];
	}
	my $dbh = $self->dbh();
	$dbh->do("delete from mtime;");
	$dbh->do("insert into mtime (mtime) values(?)", {}, $mtime);
}

sub _flag_as_dirty {
	my ($self) = @_;
	$self->_create_tables();
	$self->_update_populated_mtime(-1);
}

sub dbh {
	my ($self) = @_;
	my $sqlite_filename = $self->get_sqlite_filename();
	return $self->{_dbh} //= do {
		DBI->connect("dbi:SQLite:$sqlite_filename", "", "",
			     { RaiseError => 1, AutoCommit => 0 });
	};
}

sub commit {
	my ($self) = @_;
	my $dbh = $self->dbh();
	return $dbh->commit();
}

sub rollback {
	my ($self) = @_;
	my $dbh = $self->dbh();
	return $dbh->rollback();
}

sub do {
	my ($self, $statement, $attr, @bind_values) = @_;
	my $dbh = $self->dbh();
	return $dbh->do($statement, $attr, @bind_values);
}

sub _DESTROY_DBH {
	my ($self) = @_;
	if ($self->{_dbh}) {
		$self->{_dbh}->rollback(); # shut up dbi
	}
}

sub get_dir {
	my ($self) = @_;
	return $self->{_dir} //= do {
		my $u = URI->new($self->{url});
		my $host = $u->host();
		my $path = $u->path();
		$path =~ s{^/|/$}{}g;
		$path =~ s{/}{__}g;
		$path =~ s{\.zip$}{}i;
		sprintf("%s/.transit-gtfs/%s/%s", $ENV{HOME}, $host, $path);
	};
}

sub get_zip_filename {
	my ($self) = @_;
	return $self->{_zip_filename} //=
		sprintf("%s/google_transit.zip", $self->get_dir());
}

sub get_sqlite_filename {
	my ($self) = @_;
	return $self->{_sqlite_filename} //=
		sprintf("%s/google_transit.sqlite", $self->get_dir());
}

=head1 SEE ALSO

=over 4

=item * Google's General Transit Feed Specification

http://code.google.com/transit/spec/transit_feed_specification.html

=back

Transit data sources:

=over 4

=item * Google's list of publicly-accessible transit data feeds:

L<http://code.google.com/p/googletransitdatafeed/wiki/PublicFeeds>

=item * GTFS Data Exchange's list of official transit feeds:

L<http://www.gtfs-data-exchange.com/agencies#filter_official>

=item * GTFS Data Exchange's list of all transit feeds:

L<http://www.gtfs-data-exchange.com/agencies#filter_all>
(includes both official and unofficial data)

=back

Note that while some feed URLs listed at the above resources may point
to "about this feed" pages instead of ZIP files directly, you must
provide a direct link to the ZIP file as an argument to the object
constructor.

=head1 AUTHOR

Darren Embry, C<< <dse at webonastick.com> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-transit-gtfs at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Transit-GTFS>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Transit::GTFS


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Transit-GTFS>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Transit-GTFS>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Transit-GTFS>

=item * Search CPAN

L<http://search.cpan.org/dist/Transit-GTFS>

=back


=head1 ACKNOWLEDGEMENTS


=head1 COPYRIGHT & LICENSE

Copyright 2011 Darren Embry, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.


=cut

1; # End of Transit::GTFS
