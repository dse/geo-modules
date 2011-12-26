package Transit::GTFS;

use warnings;
use strict;

=head1 NAME

Transit::GTFS - The great new Transit::GTFS!

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

Quick summary of what the module does.

Perhaps a little code snippet.

    use Transit::GTFS;

    my $foo = Transit::GTFS->new();
    ...

=cut

sub new {
	my ($class, $url, $options) = @_;
	my $self = bless({}, $class);
	$self->{url} = $url;
	if ($options) {
		while (my ($k, $v) = each(%$options)) {
			$self->{$k} = $v;
		}
	}
	$self->init();
	return $self;
}

sub DESTROY {
	my ($self) = @_;
	$self->destroy_dbh();
}

use LWP::Simple;
use URI;
use Archive::Zip qw( :ERROR_CODES :CONSTANTS );
use Carp qw(croak);
use DBI;
use File::Path qw(mkpath);
use File::Basename;

sub init {
	my ($self) = @_;
	my $url = $self->{url};
	my $zip_filename = $self->zip_filename();
	mkpath(dirname($zip_filename));
	if ($self->{force_update}) {
		unlink($zip_filename);
	}
	warn("Updating $url ...\n");
	my $rc = mirror($url, $zip_filename);
	warn("  $url => $rc\n");
	if ($rc == RC_NOT_MODIFIED) {
		$self->populate();
	}
	elsif (is_success($rc)) {
		$self->populate();
	}
	else {
		croak("Failure: $url => $rc\n");
	}
}

sub populate {
	my ($self) = @_;
	my $zip_filename = $self->zip_filename();
	if (!-e $zip_filename) {
		return;
	}
	my $file_mtime = (stat($zip_filename))[9];
	if (!$file_mtime) {
		return;
	}
	if ($self->{force_update} || $self->{force_repopulate}) {
		$self->force_repopulate();
		return;
	}
	my $db_mtime = $self->db_mtime();
	my $dbh = $self->dbh();
	if (!$db_mtime) {
		$self->force_repopulate();
	}
	elsif ($file_mtime != $db_mtime) {
		$self->force_repopulate();
	}
}

sub force_repopulate {
	my ($self) = @_;
	if ($self->{force}) {
		$self->clear_tables();
	}
	$self->create_tables();
	$self->populate_tables();
	$self->populate_mtime();
}

sub db_mtime {
	my ($self) = @_;
	my $dbh = $self->dbh();
	my $sth = $dbh->table_info('%', '%', 'mtime');
	$sth->execute();
	return undef unless $sth->fetchrow_arrayref();
	my ($mtime) = $dbh->selectrow_array("select mtime from mtime");
	$dbh->commit();		# stfu
	return $mtime;
}

sub clear_tables {
	my ($self) = @_;
	my $dbh = $self->dbh();
	warn("Deleting tables...\n");
	$dbh->do("drop table if exists mtime;");
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
	$dbh->commit();		# stfu dbi
	warn("  Done deleting tables.\n");
}

sub create_tables {
	my ($self) = @_;
	my $dbh = $self->dbh();
	warn("Creating tables...\n");
	$dbh->do(<<"END");
create table if not exists mtime (
  mtime             integer
);
END
	$dbh->do(<<"END");
create table if not exists agency (
  agency_id         varchar(64)   primary key, -- optional if we have only one agency --
  agency_name       varchar(64)   not null,
  agency_url        varchar(256)  not null,
  agency_timezone   varchar(256)  not null,
  agency_lang       varchar(2),
  agency_phone      varchar(32),
  agency_fare_url   varchar(256)
);
END
	$dbh->do(<<"END");
create table if not exists stops (
  stop_id           varchar(16)   primary key not null, -- internal codes
  stop_code         varchar(16),                        -- displayed to users, like for telephone services
  stop_name         varchar(64)   not null,
  stop_desc         text,
  stop_lat          real          not null,             -- WGS84
  stop_lon          real          not null,             -- WGS84
  zone_id           varchar(16)   references fare_attributes(fare_id), -- required when using fare_rules.txt
  stop_url          varchar(256),
  location_type     integer       default 0,            -- 0=stop; 1=station w/1+ stops
  parent_station    varchar(16)   references stops(stop_id)
);
END
	$dbh->do(<<"END");
create table if not exists routes (
  route_id          varchar(16)   primary key not null,
  agency_id         varchar(16)   references agency(agency_id),
  route_short_name  varchar(16)   not null, -- e.g., "32", "100X", "Green"
  route_long_name   varchar(64)   not null, 
  route_desc        text,
  route_type        integer       not null,     -- * 0 = tram, streetcar, light rail;
						--   1 = subway, metro;
						--   2 = rail (intercity or long-distance);
						--   3 = bus;
						--   4 = ferry;
						--   5 = cable car;
						--   6 = gondola;
						--   7 = funicular
  route_url         varchar(256),
  route_color       varchar(6),
  route_text_color  varchar(6)
);
END
	$dbh->do(<<"END");
create table if not exists trips (
  route_id          varchar(16)   not null references routes(route_id),
  service_id        varchar(16)   not null,     -- references calendar.txt or calendar_dates.txt
  trip_id           varchar(16)   not null unique,
  trip_headsign     varchar(64),
  trip_short_name   varchar(64),
  direction_id      integer,			-- for distinguishing between bi-directional trips within the same route_id
						--   0 = one direction (e.g., outbound); 1 = opposite direction (e.g., inbound)
  block_id          varchar(16),		-- block = 2+ sequential trips with same vehicle
  shape_id          varchar(16) references shapes(shape_id) -- FIXME: references shapes.txt
);
END
	$dbh->do(<<"END");
create table if not exists stop_times (
  trip_id           varchar(16)   not null references trips(trip_id),
  arrival_time      varchar(8)    not null,	-- measured from 'noon minus 12 hours'
  departure_time    varchar(8)    not null,	-- 
  stop_id           varchar(16)   not null references stops(stop_id),
  stop_sequence     integer       not null,
  stop_headsign     varchar(64),
  pickup_type       integer       default 0,	-- 0 = regularly scheduled pickup; 
						-- 1 = no pickup available;
						-- 2 = must phone agency;
						-- 3 = must coordinate with driver
  drop_off_type     integer       default 0,	-- 0 = regularly scheduled dropoff;
						-- 1 = no dropoff available;
						-- 2 = must phone agency;
						-- 3 = must coordinate with driver
  shape_dist_traveled  real			
);
END
	$dbh->do(<<"END");
create table if not exists calendar (
  service_id        varchar(16)   not null,	-- FIXME: references trips(service_id)
  monday            integer       not null,	
  tuesday           integer       not null,
  wednesday         integer       not null,
  thursday          integer       not null,
  friday            integer       not null,
  saturday          integer       not null,
  sunday            integer       not null,
  start_date        varchar(8)    not null,	-- 'YYYYMMDD' format
  end_date          varchar(8)    not null	-- 'YYYYMMDD' format
);
END
	$dbh->do(<<"END");
create table if not exists calendar_dates (
  service_id        varchar(16)   not null,	-- FIXME: references trips(service_id)
  date              varchar(8)    not null,	-- 'YYYYMMDD' format
  exception_type    integer       not null	-- 1 = added; 2 = removed
);
END
	$dbh->do(<<"END");
create table if not exists fare_attributes (
  fare_id           varchar(16)   primary key not null,
  price             real          not null,
  currency_type     varchar(3)    not null, -- e.g., 'USD'
  payment_method    integer       not null, -- * 0 = paid on board; 1=paid before boarding
  transfers         integer,                -- * 0 = no transfers pemitted on this fare;
                                            --   1 = passenger may transfer once;
					    --   2 = passenger may transfer twice;
                                            --   empty = unlimited transfers are permitted
					    --   required per GTFS spec, but do not specify 'not null' here
  transfer_duration integer                 -- * in seconds
);
END
	$dbh->do(<<"END");
create table if not exists fare_rules (
  fare_id           varchar(16)   primary key not null,
  route_id          varchar(16),		-- FIXME: references routes.txt
  origin_id         varchar(16),		-- FIXME: references stops.txt
  destination_id    varchar(16),		-- FIXME: references stops.txt
  contains_id       varchar(16)			-- FIXME: references stops.txt
);
END
	$dbh->do(<<"END");
create table if not exists shapes (
  shape_id          varchar(16)   not null,	-- NOT unique
  shape_pt_lat      real          not null,	-- WGS84
  shape_pt_lon      real          not null,	-- WGS84
  shape_pt_sequence integer       not null,	
  shape_dist_traveled real			-- 
);
END
	$dbh->do(<<"END");
create table if not exists frequencies (
  trip_id		varchar(16)	not null,		-- FIXME: references trips.txt
  start_time		varchar(8)	not null,
  end_time		varchar(8)	not null,
  headway_secs		integer		not null,		-- in seconds
  exact_times		integer		not null default 0	-- 0 = frequency-based trips are not exactly scheduled
								-- 1 = exactly scheduled
								--     trip_start_time = start_time + x * headway_secs
								--       for all x in (0, 1, 2, ...) where trip_start_time < end_time
);
END
	$dbh->do(<<"END");
create table if not exists transfers (
  from_stop_id		varchar(16)	not null references stops(stop_id),
  to_stop_id		varchar(16)	not null references stops(stop_id),
  transfer_type		integer		default 0,
  min_transfer_time	integer					-- in seconds
);
END
	$dbh->do(<<"END");
create table if not exists feed_info (
  feed_publisher_name	varchar(64)	not null,
  feed_publisher_url	varchar(256)	not null,
  feed_lang		varchar(32)	not null,	-- IETF BCP 47 language code
  feed_start_date	varchar(8),
  feed_end_date		varchar(8),
  feed_version		varchar(64)
);
END
	$dbh->commit();		# stfu dbi
	warn("Done creating tables.\n");
}

sub populate_tables {
	my ($self) = @_;
	my $zip_filename = $self->zip_filename();

	my $zip = Archive::Zip->new();
	unless ($zip->read($zip_filename) == AZ_OK) {
		die("Error reading $zip_filename\n");
	}

	$self->populate_data($zip, "agency");
	$self->populate_data($zip, "stops");
	$self->populate_data($zip, "routes");
	$self->populate_data($zip, "trips");
	$self->populate_data($zip, "stop_times");
	$self->populate_data($zip, "calendar");
	$self->populate_data($zip, "calendar_dates");
	$self->populate_data($zip, "fare_attributes");
	$self->populate_data($zip, "fare_rules");
	$self->populate_data($zip, "shapes");
	$self->populate_data($zip, "frequencies");
	$self->populate_data($zip, "transfers");
	$self->populate_data($zip, "feed_info");
}

use Archive::Zip::MemberRead;
use Text::CSV;

sub populate_data {
	my ($self, $zip, $table) = @_;
	my $member = "$table.txt";
	my $fullpath = $self->dir() . "/" . $member;
	if (!$zip->memberNamed($member)) {
		warn("No member named $member\n");
		return;
	}
	if ($zip->extractMember($member, $fullpath) != AZ_OK) {
		die("could not extract $member");
	}
	open(my $fh, "<", $fullpath) or die("cannot read $fullpath: $!\n");
	my $csv = Text::CSV->new ({ binary => 1 });
	my $fields = $csv->getline($fh);
	die("no fields in $fullpath\n") unless $fields or scalar(@$fields);

	warn("Populating $table...\n");

	my $dbh = $self->dbh();
	$dbh->do("delete from $table;");
	$dbh->commit();
	my $sql = sprintf("insert into $table(%s) values(%s);",
			  join(", ", @$fields),
			  join(", ", ('?') x scalar(@$fields)));
	my $sth = $dbh->prepare($sql);
	my $rows = 0;
	while (defined(my $row = $csv->getline($fh))) {
		$sth->execute(@$row);
		++$rows;
		print STDERR ("  $rows rows\r") if $rows % 100 == 0;
	}
	print STDERR ("  $rows rows.  Committing...\n");
	$dbh->commit();
	print STDERR ("  Done.\n");
	return;
}

sub populate_mtime {
	my ($self) = @_;
	my $zip_filename = $self->zip_filename();
	my $mtime = (stat($zip_filename))[9];
	my $dbh = $self->dbh();
	$dbh->do("delete from mtime;");
	$dbh->do("insert into mtime (mtime) values(?)", {}, $mtime);
	$dbh->commit();
}

sub dbh {
	my ($self) = @_;
	my $sqlite_filename = $self->sqlite_filename();
	return $self->{_dbh} //= do {
		return DBI->connect("dbi:SQLite:$sqlite_filename", "", "",
				    { RaiseError => 1, AutoCommit => 0 });
	};
}

sub destroy_dbh {
	my ($self) = @_;
	if ($self->{_dbh}) {
		$self->{_dbh}->commit(); # shut up dbi
	}
}

sub dir {
	my ($self) = @_;
	return $self->{_dir} //= do {
		my $u = URI->new($self->{url});
		my $host = $u->host();
		my $path = $u->path();
		$path =~ s{^/|/$}{}g;
		$path =~ s{/}{__}g;
		$path =~ s{\.zip$}{}i;
		return sprintf("%s/.transit-gtfs/%s/%s",
			       $ENV{HOME}, $host, $path);
	};
}

sub zip_filename {
	my ($self) = @_;
	return $self->{_zip_filename} //= do {
		return sprintf("%s/google_transit.zip",
			       $self->dir());
	};
}

sub sqlite_filename {
	my ($self) = @_;
	return $self->{_sqlite_filename} //= do {
		return sprintf("%s/google_transit.sqlite",
			       $self->dir());
	};
}

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
