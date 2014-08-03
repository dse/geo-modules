package Geo::GTFS::Realtime;	# -*- cperl -*-
use warnings;
use strict;

BEGIN {
    if (defined $ENV{REQUEST_METHOD}) {
	unshift(@INC, "/home/dse/git/HTTP-Cache-Transparent/lib");
	# my fork adds a special feature called NoUpdateImpatient.
    } else {
	unshift(@INC, "$ENV{HOME}/git/HTTP-Cache-Transparent/lib");
	# my fork adds a special feature called NoUpdateImpatient.
    }
}

# use Carp::Always;
use Geo::GTFS;
use LWP::Simple;
use HTTP::Cache::Transparent;
use Google::ProtocolBuffers;
use File::Path qw(make_path);
use POSIX qw(strftime floor uname);
use File::Basename qw(dirname);
use JSON qw(-convert_blessed_universally);
use YAML::Syck;
use Data::Dumper;
use Errno qw(EEXIST);
use File::Spec::Functions qw(abs2rel);
use Time::Local qw(timegm);
use open IO => ":locale";

BEGIN {
    # in osx you may have to run: cpan Crypt::SSLeay and do other
    # things
    my ($uname) = uname();
    if ($uname =~ m{^Darwin}) {
	my $ca_file = "/usr/local/opt/curl-ca-bundle/share/ca-bundle.crt";
	if (-e $ca_file) {
	    $ENV{HTTPS_CA_FILE} = $ca_file;
	} else {
	    warn(<<"END");

Looks like you are using a Mac.  You should run:
    brew install curl-ca-bundle.
You may also need to run:
    sudo cpan Crypt::SSLeay

END
	    exit(1);
	}
    }
}

sub new {
    my ($class, @args) = @_;
    my $self = bless({}, $class);
    $self->init(@args) if $self->can('init');
    $self->{gtfs} = Geo::GTFS->new($self->{gtfs_name});
    $self->{no_fetch} = 0;
    return $self;
}

sub set_cache_options {
    my ($self, %args) = @_;

    if (defined $ENV{REQUEST_METHOD}) {
	$self->{cache_path} = "/tmp/gtfs-realtime-data-$>/http-cache";
    } else {
	$self->{cache_path} = "$ENV{HOME}/.http-cache-transparent";
    }

    my $cache_options = $self->{cache_options} //= { BasePath => $self->{cache_path},
						     Verbose => 0,
						     NoUpdate => 30,
						     NoUpdateImpatient => 1 };
    %$cache_options = (%$cache_options, %args);
    HTTP::Cache::Transparent::init($cache_options);
}

sub init_transit_agency_specific_data {
    my ($self) = @_;
    $self->{gtfs_name} = "ridetarc.org";
    $self->{feed_urls}  = { qw(alerts             http://googletransit.ridetarc.org/realtime/alerts/Alerts.pb
			       realtime_feed      http://googletransit.ridetarc.org/realtime/gtfs-realtime/TrapezeRealTimeFeed.pb
			       trip_updates       http://googletransit.ridetarc.org/realtime/trip_update/TripUpdates.pb
			       vehicle_positions  http://googletransit.ridetarc.org/realtime/vehicle/VehiclePositions.pb) };

    my $symbol_1 = ".";
    my $symbol_2 = ":";
    my $symbol_3 = "\N{DAGGER}";
    my $symbol_4 = "\N{DAGGER}";

    $self->{vehicle_notes} = [ { from => 1350, to => 1370, legend => $symbol_2, note => "FANCY BRT BUS WITH WIFI"          },
			       { from => 901,  to => 954,  legend => $symbol_1, note => "GET YOUR LAST RIDES ON THE 900'S" },
			       { from => 960,  to => 979,  legend => $symbol_1, note => "GET YOUR LAST RIDES ON THE 900'S" },
			       { from => 983,  to => 999,  legend => $symbol_1, note => "GET YOUR LAST RIDES ON THE 900'S" },
			       { from => 2001, to => 2012 },
			       { from => 2050, to => 2057 },
			       { from => 2101, to => 2111 },
			       { from => 2250, to => 2266 },
			       { from => 1110, to => 1121 },
			       { from => 2301, to => 2320 },
			       { from => 2401, to => 2405 },
			       { from => 2501, to => 2516 },
			       { from => 2701, to => 2704 },
			       { from => 2801, to => 2806 },
			       { from => 2901, to => 2903 },
			       { from => 2910, to => 2926 },
			       { from => 1001, to => 1009 },
			       { from => 1301, to => 1316 },
			       { from => 1320, to => 1330 },
			       { legend => $symbol_4, note => "UNEXPECTED FLEET NUMBER" }];
}

sub init_geonames_account_specific_data {
    my ($self) = @_;
    $self->{geonames} = { username => "dsembry",
			  password => "geo2014names",
			  email => "dse\@webonastick.com" };
}

sub init {
    my ($self, %args) = @_;

    $self->set_cache_options();
    $self->{ua} = LWP::UserAgent->new();

    $self->{gtfs_realtime_proto} = "https://developers.google.com/transit/gtfs-realtime/gtfs-realtime.proto";

    if (defined $ENV{REQUEST_METHOD}) {
	$self->{my_cache} = "/tmp/gtfs-realtime-data-$>/gtfsrt-cache";
    } else {
	$self->{my_cache} = "$ENV{HOME}/.my-gtfs-realtime-data/cache";
    }

    $self->{feed_types} = [ qw(alerts
			       realtime_feed
			       trip_updates
			       vehicle_positions) ];

    $self->init_transit_agency_specific_data();
    $self->init_geonames_account_specific_data();

    make_path($self->{my_cache});
    $self->pull_protocol();

    while (my ($k, $v) = each(%args)) {
	$self->{$k} = $v;
    }

    my $timestamp_to_time = sub {
	my ($time_t) = @_;
	if ($time_t =~ m{^\d+$}) {
	    return strftime("%m/%d %H:%M:%S", localtime($time_t));
	} else {
	    return $time_t;
	}
    };

    $self->{compact} //= My::JSON::Encoder::Compact->new(compactness   => 2,
							 extra_compact => { "stop_time_update[]" => 1 },
							 convert_key   => { "time"      => $timestamp_to_time,
									    "timestamp" => $timestamp_to_time });
}

###############################################################################

sub get_vehicle_note {
    my ($self, $vehicle) = @_;
    foreach my $note (@{$self->{vehicle_notes}}) {
	if (defined $note->{from} && defined $note->{to}) {
	    if ($vehicle >= $note->{from} && $vehicle <= $note->{to}) {
		my %note = %$note;
		delete $note{from};
		delete $note{to};
		if (scalar(keys(%note))) {
		    return \%note;
		} else {
		    return undef;
		}
	    }
	} else {
	    return $note;
	}
    }
}

=head2 pull_protocol

    $gtfsrt->pull_protocol();

This method is called when a Geo::GTFS::Realtime object is created, so
you probably don't need to call this method yourself.

=cut

sub pull_protocol {
    my ($self) = @_;
    $self->set_cache_options(NoUpdate => 86400, NoUpdateImpatient => 0);
    my $request = HTTP::Request->new("GET", $self->{gtfs_realtime_proto});
    my $response = $self->{ua}->request($request);
    if (!$response->is_success()) {
	warn(sprintf("Failed to pull protocol: %s\n", $response->status_line()));
	exit(1);
    }
    my $proto = $response->content();
    if (!defined $proto) {
	die("Failed to pull protocol: undefined content\n");
    }
    if (!$proto) {
	die("Failed to pull protocol: no content\n");
    }
    Google::ProtocolBuffers->parse($proto);
}

sub test {
    my ($self) = @_;
    $self->set_cache_options(NoUpdate => 30, NoUpdateImpatient => 1);
    if ($self->{verbose}) {
	warn(sprintf("Current time: %d %s\n", time(), scalar(localtime())));
    }
    my $request = HTTP::Request->new("GET", $self->{feed_urls}->{vehicle_positions});
    my $response = $self->{ua}->request($request);
}

sub json_A {
    my ($self) = @_;
    return $self->{json_A} //= JSON->new()->allow_nonref()->pretty()->convert_blessed();
}

sub fetch_latest_data {
    my ($self, @feed_types) = @_;
    if (!@feed_types) {
	@feed_types = @{$self->{feed_types}};
    }
    if ($self->{no_fetch}) {
	return $self->get_latest_data_fetched(@feed_types);
    }
    $self->{latest_data} = {};
    $self->set_cache_options(NoUpdate => 30, NoUpdateImpatient => 1);
    my $json = $self->json_A();
    foreach my $feed_type (@{$self->{feed_types}}) {
	my $feed_url = $self->{feed_urls}->{$feed_type};
	my $req = HTTP::Request->new("GET", $feed_url);
	my $res = $self->{ua}->request($req);
	if (!$res->is_success()) {
	    die(sprintf("FAIL: %s => %s\n", $res->request()->uri(), $res->status_line()));
	}
	my $pb = $res->content();
	my $last_modified = $res->last_modified();
	if (!defined $last_modified) {
	    print($res->headers->as_string);
	    exit(1);
	}
	my $gm_timestamp = strftime("%Y/%m/%d/%H%M%SZ", gmtime($last_modified));
	my $pb_object = TransitRealtime::FeedMessage->decode($pb);
	my $pb_filename   = sprintf("%s/%s/pb/%s.pb",         $self->{my_cache}, $feed_type, $gm_timestamp);
	my $json_filename = sprintf("%s/%s/json/%s.json",     $self->{my_cache}, $feed_type, $gm_timestamp);
	my $pb_latest     = sprintf("%s/%s/pb/latest.pb",     $self->{my_cache}, $feed_type);
	my $json_latest   = sprintf("%s/%s/json/latest.json", $self->{my_cache}, $feed_type);
	$self->_file_put_contents($pb_filename, $pb, "b");
	my $as_json = $json->encode($pb_object);
	$self->_file_put_contents($json_filename, $as_json);
	$self->_symlink($pb_filename, $pb_latest);
	$self->_symlink($json_filename, $json_latest);
	$self->{latest_data}->{$feed_type} = $pb_object;
    }
    if (scalar(@feed_type) == 1) {
	return $self->{latest_data}->{$feed_type[0]};
    }
}

sub get_latest_data_fetched {
    my ($self, @feed_types) = @_;
    if (!@feed_types) {
	@feed_types = @{$self->{feed_types}};
    }
    $self->{latest_data} = {};
    my $json = $self->json_A();
    foreach my $feed_type (@feed_types) {
	my $pb_latest = sprintf("%s/%s/pb/latest.pb", $self->{my_cache}, $feed_type);
	my $pb = $self->_file_get_contents($pb_latest, "b");
	if (!$pb) {
	    die("We've never fetched any $feed_type data.\n");
	}
	my $pb_object = TransitRealtime::FeedMessage->decode($pb);
	$self->{latest_data}->{$feed_type} = $pb_object;
    }
    if (scalar(@feed_type) == 1) {
	return $self->{latest_data}->{$feed_type[0]};
    }
}

sub get_version_list {
    my ($self) = @_;
    my $dir = $self->{my_cache};
    my @pb_filename = glob("$dir/*/pb/????/??/??/??????Z.pb");

    my %feed_info_by_version;
    my $process = sub {
	my ($time_t, $date, $feed_type, $pb_filename) = @_;
	my $rec = { time        => $time_t,
		    date        => $date,
		    feed_type   => $feed_type,
		    pb_filename => $pb_filename };
	$feed_info_by_version{$time_t}{$feed_type} = $rec;
    };

    foreach my $pb_filename (@pb_filename) {
	my $rel = abs2rel($pb_filename, $dir);
	if ($rel =~ m{(?:^|/)([^/]+)/pb/(\d+)/(\d+)/(\d+)/(\d\d)(\d\d)(\d\d)Z\.}) {
	    my ($feed_type, $yyyy, $mm, $dd, $hh, $mi, $ss) = ($1, $2, $3, $4, $5, $6, $7);
	    foreach ($yyyy, $mm, $dd, $hh, $mi, $ss) {
		if (defined $_) {
		    $_ =~ s{^0+}{};	  # avoid octal parsing
		    $_ = "0" if $_ eq ""; # want "0" not ""
		    $_ = $_ + 0;	  # force to number
		}
	    }
	    my $time_t = timegm($ss, $mi, $hh, $dd, $mm - 1, $yyyy);
	    my $date = strftime("%Y-%m-%d", localtime($time_t));
	    $process->($time_t, $date, $feed_type, $pb_filename);
	}
    }

    my %version_list;
    my %date_list;

    # postprocess
    my @all_feed_types = sort { $a cmp $b } @{$self->{feed_types}};
    my $all_feed_types = join(",", @all_feed_types);
    foreach my $time_t (sort { $a <=> $b } keys(%feed_info_by_version)) {
	my $gm_timestamp = strftime("%a %Y-%m-%d %H:%M:%S %Z", localtime($time_t));
	my $date = strftime("%Y-%m-%d", localtime($time_t));
	my @feed_types_for_this_time = sort { $a cmp $b } keys %{$feed_info_by_version{$time_t}};
	my $feed_types_for_this_time = join(",", @feed_types_for_this_time);
	if ($feed_types_for_this_time ne $all_feed_types) {
	    if ($self->{verbose}) {
		warn("WARNING: not all data available for $gm_timestamp.\n");
	    }
	} else {
	    $version_list{$time_t} = 1;
	    $date_list{$date} = 1;
	}
    }

    $self->{version_list} = [ sort { $a <=> $b } keys(%version_list) ];
    $self->{date_list}    = [ sort { $a cmp $b } keys(%date_list)    ];
}

sub output_list_of_dates {
    my ($self) = @_;
    $self->get_version_list();
    my @date_list = reverse @{$self->{date_list}};
    if (scalar(@date_list) > 20) {
	splice(@date_list, 20);
    }
    foreach my $date (@date_list) {
	printf("%s\n", $date);
    }
}

sub output_list_of_times {
    my ($self) = @_;
    $self->get_version_list();
    my @time_list = reverse @{$self->{version_list}};
    if (scalar(@time_list) > 20) {
	splice(@time_list, 20);
    }
    print("Version Num.  Date/Time\n");
    print("------------  ------------------------------------\n");
    foreach my $time_t (@time_list) {
	my $ts = strftime("%a %Y-%m-%d %H:%M:%S %Z", localtime($time_t));
	printf("%12d  %s\n", $time_t, $ts);
    }
}

sub output_list_of_versions_by_date {
    my ($self, $date) = @_;
    $self->get_version_list();
}

sub _special_cmp {
    my ($stringA, $stringB) = @_;
    if ($stringA =~ m{\d+}) {
	my ($prefixA, $numberA, $suffixA) = ($`, $&, $');
	if ($stringB =~ m{\d+}) {
	    my ($prefixB, $numberB, $suffixB) = ($`, $&, $');
	    if ($prefixA eq $prefixB) {
		return ($numberA <=> $numberB) || _special_cmp($suffixA, $suffixB);
	    }
	}
    }
    return $stringA cmp $stringB;
}

use Term::Size;
use vars qw($COLUMNS $ROWS);
BEGIN {
    ($COLUMNS, $ROWS) = Term::Size::chars *STDOUT{IO};
}
use Text::ASCIITable;
use Text::FormatTable;
# There are also:
#   Text::Table
#   Text::SimpleTable

=head2 list_trip_updates

=cut

sub list_trip_updates {
    my ($self) = @_;

    if (!$self->{latest_data}) {
	$self->fetch_latest_data();
    }

    my $vp_pb = $self->{latest_data}->{vehicle_positions};
    my $tu_pb = $self->{latest_data}->{trip_updates};

    my $vp_header_timestamp = $vp_pb->{header}->{timestamp};
    my $tu_header_timestamp = $tu_pb->{header}->{timestamp};

    my $vp_header_time = strftime("%m/%d %H:%M:%S", localtime($vp_header_timestamp));
    my $tu_header_time = strftime("%m/%d %H:%M:%S", localtime($tu_header_timestamp));

    print("Trip updates      as of $tu_header_time\n");
    print("Vehicle positions as of $vp_header_time\n");

    my %vehicle;

    my @vp_extras_1;

    foreach my $entity (@{$vp_pb->{entity}}) {
	my $rec = eval { $entity->{vehicle} };
	if (!$rec) {
	    push(@vp_extras_1, $entity);
	    next;
	}

	my $label = eval { $rec->{vehicle}->{label} } // eval { $entity->{id} };
	if (!defined $label) {
	    push(@vp_extras_1, $entity);
	    next;
	}

	my $trip_id = eval { $rec->{trip}->{trip_id} };
	$rec->{trip_id} = $trip_id if defined $trip_id;

	$vehicle{$label} = $rec;
    }

    my @entity = @{$tu_pb->{entity}};

    @entity = (map { $_->[0] }
		 sort { _special_cmp($a->[1], $b->[1]) }
		   map { [$_, eval { $_->{trip_update}->{trip}->{route_id} } // ""] }
		     @entity);

    $self->trip_updates_table_start();

    my @vp_extras_2;

    foreach my $entity (@entity) {
	my $tu       = eval { $entity->{trip_update} };
	if (!defined $tu) {
	    push(@vp_extras_2, $entity);
	    next;
	}

	my $trip_id  = eval { $tu->{trip}->{trip_id} } // eval { $tu->{id} };
	my $route_id = eval { $tu->{trip}->{route_id} };
	my $label    = eval { $tu->{vehicle}->{label} };
	if (!defined $label) {
	    push(@vp_extras_2, $entity);
	    next;
	}

	my $start_time = eval { $tu->{trip}->{start_time} };
	my $start_date = eval { $tu->{trip}->{start_date} };

	my $dep_delay = eval { $tu->{stop_time_update}->[0]->{departure}->{delay} };
	my $arr_delay = eval { $tu->{stop_time_update}->[0]->{arrival}->{delay} };
	my $delay = $dep_delay // $arr_delay;
	$delay /= 60 if defined $delay;

	my $dep_time     = eval { $tu->{stop_time_update}->[0]->{departure}->{time} };
	my $arr_time     = eval { $tu->{stop_time_update}->[0]->{arrival}->{time} };
	my $dep_arr_time = $dep_time // $arr_time;
	my $at_stop_id   = eval { $tu->{stop_time_update}->[0]->{stop_id} };

	if (!defined $at_stop_id || $at_stop_id eq "UN") {
	    push(@vp_extras_2, $entity);
	    next;
	}

	my $dep_or_arr   = defined($dep_time) ? "DEP" : defined($arr_time) ? "ARR" : "---";
	my $at_stop      = eval { $self->{gtfs}->get_stop_by_stop_id($at_stop_id) };
	my $at_stop_name = eval { $at_stop->{stop_name} };

	my $dep_arr_time_fmt = defined $dep_arr_time && eval { strftime("%H:%M:%S", localtime($dep_arr_time)) };

	my $vehicle = $vehicle{$label};
	my $timestamp = eval { $vehicle->{timestamp} };
	my $timestamp_fmt = defined $timestamp && eval { strftime("%H:%M:%S", localtime($timestamp)) };
	my $vehicle_note = $self->get_vehicle_note($label);

	if (!defined $timestamp) {
	    push(@vp_extras_2, $entity);
	    next;
	}
	if ($tu_header_timestamp - $timestamp >= 1800) {
	    push(@vp_extras_2, $entity);
	    next;
	}

	my $trip = $self->{gtfs}->get_trip_by_trip_id($trip_id);
	my $headsign = $trip->{trip_headsign};

	my %vehicle_notes;
	if ($vehicle_note) {
	    $vehicle_notes{$vehicle_note->{legend}} = $vehicle_note->{note};
	}

	my $lat = eval { $vehicle->{position}->{latitude} };
	my $lon = eval { $vehicle->{position}->{longitude} };
	my $location;

	if (0) {
	    my $gn_result = defined $lat && defined $lon && $self->reverse_geocode_via_geonames_nearest_intersection($lat, $lon);
	    $location = $gn_result && sprintf("%s @ %s",
					      $gn_result->{intersection}->{street1},
					      $gn_result->{intersection}->{street2});
	}
	if (1) {
	    $location = sprintf("%10.6f,%10.6f", $lat, $lon);
	}

	my @row = ($label,
		   $vehicle_note && $vehicle_note->{legend},
		   $location,
		   $trip_id,
		   $route_id,
		   $headsign,
		   $dep_arr_time_fmt,
		   $dep_or_arr,
		   $at_stop_name,
		   $timestamp_fmt,
		   floor(($delay // 0) + 0.5));

	$self->trip_updates_table_add_row(@row);
    }

    if (0) {
	my $t;
	my $UPPER_LEFT   = "\N{BOX DRAWINGS DOUBLE DOWN AND RIGHT}";
	my $UPPER_RIGHT  = "\N{BOX DRAWINGS DOUBLE DOWN AND LEFT}";
	my $LOWER_LEFT   = "\N{BOX DRAWINGS DOUBLE UP AND RIGHT}";
	my $LOWER_RIGHT  = "\N{BOX DRAWINGS DOUBLE UP AND LEFT}";
	my $UPPER        = "\N{BOX DRAWINGS DOUBLE HORIZONTAL}";
	my $LOWER        = "\N{BOX DRAWINGS DOUBLE HORIZONTAL}";
	my $UPPER_SEP    = "\N{BOX DRAWINGS DOWN SINGLE AND HORIZONTAL DOUBLE}";
	my $LOWER_SEP    = "\N{BOX DRAWINGS UP SINGLE AND HORIZONTAL DOUBLE}";
	my $LINE1_LEFT   = "\N{BOX DRAWINGS DOUBLE VERTICAL AND RIGHT}";
	my $LINE1_RIGHT  = "\N{BOX DRAWINGS DOUBLE VERTICAL AND LEFT}";
	my $LINE1        = "\N{BOX DRAWINGS DOUBLE HORIZONTAL}";
	my $LINE1_SEP    = "\N{BOX DRAWINGS VERTICAL SINGLE AND HORIZONTAL DOUBLE}";
	my $ROW_LEFT     = "\N{BOX DRAWINGS DOUBLE VERTICAL}";
	my $ROW_RIGHT    = "\N{BOX DRAWINGS DOUBLE VERTICAL}";
	my $ROW_SEP      = "\N{BOX DRAWINGS LIGHT VERTICAL}";
	my $table = $t->draw([$UPPER_LEFT, $UPPER_RIGHT, $UPPER, $UPPER_SEP],
			     [$ROW_LEFT, $ROW_RIGHT, $ROW_SEP],
			     [$LINE1_LEFT, $LINE1_RIGHT, $LINE1, $LINE1_SEP],
			     [$ROW_LEFT, $ROW_RIGHT, $ROW_SEP],
			     [$LOWER_LEFT, $LOWER_RIGHT, $LOWER, $LOWER_SEP]);
	$table =~ s{$ROW_LEFT }{$ROW_LEFT}g;
	$table =~ s{ $ROW_RIGHT}{$ROW_RIGHT}g;
	$table =~ s{ $ROW_SEP }{$ROW_SEP}g;
	$table =~ s{.$UPPER_SEP.}{$UPPER_SEP}g;
	$table =~ s{.$LOWER_SEP.}{$LOWER_SEP}g;
	$table =~ s{$UPPER_LEFT.}{$UPPER_LEFT}g;
	$table =~ s{$LOWER_LEFT.}{$LOWER_LEFT}g;
	$table =~ s{.$UPPER_RIGHT}{$UPPER_RIGHT}g;
	$table =~ s{.$LOWER_RIGHT}{$LOWER_RIGHT}g;
	$table =~ s{$LINE1_LEFT.}{$LINE1_LEFT}g;
	$table =~ s{.$LINE1_RIGHT}{$LINE1_RIGHT}g;
	$table =~ s{.$LINE1_SEP.}{$LINE1_SEP}g;
	print $table;
    }

    if (1) {
	$self->trip_updates_table_end();
    }

    if ($self->{extras}) {
	if (scalar(@vp_extras_1)) {
	    print("-------------------------------------------------------------------------------\n");
	    print($self->{compact}->encode(\@vp_extras_1));
	}
	if (scalar(@vp_extras_2)) {
	    print("-------------------------------------------------------------------------------\n");
	    print($self->{compact}->encode(\@vp_extras_2));
	}
    }
}

sub trip_updates_table_start {
    my ($self) = @_;
    $self->trip_updates_table__tft__start();
}
sub trip_updates_table_add_row {
    my ($self, @row) = @_;
    $self->trip_updates_table__tft__add_row(@row);
}
sub trip_updates_table_end {
    my ($self) = @_;
    $self->trip_updates_table__tft__end();
}

sub trip_updates_table__tft__start {
    my ($self) = @_;
    my $tft = $self->{tft} = Text::FormatTable->new("l|l|l|l|l|l|l|l|l|l|r");
    my @head = ("Veh.",
		"*",
		"Location",
		"Trip",
		"Rt.",
		"Headsign",
		"Dep.Time",
		"D/A",
		"Stop",
		"Timestmp",
		"Dly");
    $tft->head(@head);
    $tft->rule("=");
}
sub trip_updates_table__tft__add_row {
    my ($self, @row) = @_;
    my $tft = $self->{tft};
    $tft->row(@row);
}
sub trip_updates_table__tft__end {
    my ($self) = @_;
    my $tft = $self->{tft};
    if ($self->{width}) {
	print $tft->render($self->{width});
    } else {
	print $tft->render($COLUMNS);
    }
}

sub _symlink {
    my ($self, $source, $dest) = @_;
    if (!-e $source) {
	warn("  not creating link $dest: $source does not exist\n");
	return;
    }
    if (!symlink($source, $dest)) {
	if ($!{EEXIST}) {
	    if (!unlink($dest)) {
		warn("  cannot unlink $dest: $!\n");
		return;
	    }
	    if (!symlink($source, $dest)) {
		warn("  cannot symlink $source as $dest: $!\n");
		return;
	    }
	}
    }
    my $rel_source = abs2rel($source, dirname($dest));
    if ($self->{verbose}) {
	warn(sprintf("  Created symlink to %-27s: %s\n", $rel_source, $dest)); # assuming max 8 chars. extension
    }
}

BEGIN {
    my $h = select(STDERR);
    $| = 1;
    select($h);
}

sub _file_put_contents {
    my ($self, $filename, $data, $mode) = @_;
    make_path(dirname($filename));
    open(my $fh, ">", $filename) or do {
	warn("  cannot write $filename: $!\n");
	return;
    };
    if ($self->{verbose}) {
	printf STDERR ("  Writing %s (%d bytes) ... ", $filename, length($data));
    }
    if (defined $mode && $mode eq "b") {
	binmode($fh);
    }
    print $fh $data;
    if ($self->{verbose}) {
	print STDERR ("Done.\n");
    }
}

sub _file_get_contents {
    my ($self, $filename, $mode) = @_;
    open(my $fh, "<", $filename) or do {
	warn("  cannot read $filename: $!\n");
	return;
    };
    if (defined $mode && $mode eq "b") {
	binmode($fh);
    }
    my $data = "";
    my $status;
    while (($status = sysread($fh, $data, 4096, length($data)))) {
    }
    if (!defined $status) {
	warn("error reading $filename: $!\n");
    }
    return $data;
}

sub _join_and {
    my @items = @_;
    if (scalar(@items) == 2) {
	return join(" and ", @items);
    } elsif (scalar(@items) > 2) {
	my $last = pop(@items);
	return join(", ", @items) . ", and " . $last;
    } else {
	return join(" ", @items);
    }
}

use URI::Escape;
use JSON;
sub reverse_geocode_via_geonames {
    my ($self, $service, $lat, $lng) = @_;
    my $username = eval { $self->{geonames}->{username} };
    return unless defined $username;
    my $url = sprintf("http://api.geonames.org/%s?lat=%s&lng=%s&username=%s",
		      $service,
		      uri_escape($lat),
		      uri_escape($lng),
		      uri_escape($username));
    $self->set_cache_options(NoUpdate => 86400, NoUpdateImpatient => 0);
    my $request = HTTP::Request->new("GET", $url);
    my $response = $self->{ua}->request($request);
    return unless $response->is_success();
    my $json = $self->{json_C} //= JSON->new();
    my $result = $json->decode($response->content());
    return $result;
}
sub reverse_geocode_via_geonames_nearest_intersection {
    my ($self, $lat, $lng) = @_;
    return $self->reverse_geocode_via_geonames("findNearestIntersectionJSON", $lat, $lng);
}
sub reverse_geocode_via_geonames_nearest_address {
    my ($self, $lat, $lng) = @_;
    return $self->reverse_geocode_via_geonames("findNearestAddressJSON", $lat, $lng);
}
sub reverse_geocode_via_geonames_nearest_intersection_osm {
    my ($self, $lat, $lng) = @_;
    return $self->reverse_geocode_via_geonames("findNearestIntersectionOSMJSON", $lat, $lng);
}
sub reverse_geocode_via_geonames_nearby_streets_json {
    my ($self, $lat, $lng) = @_;
    return $self->reverse_geocode_via_geonames("findNearbyStreetsOSM", $lat, $lng);
}

=head2 show_trip

    $gtfsrt->show_trip(TRIP_ID);

Displays a list of stops on the specified trip.

=cut

sub show_trip {
    my ($self, $trip_id) = @_;
    my $gtfs = $self->{gtfs};

    if (!$self->{latest_data}) {
	$self->fetch_latest_data();
    }

    my $vp_pb = $self->{latest_data}->{vehicle_positions};
    my $tu_pb = $self->{latest_data}->{trip_updates};
    my $vp_header_timestamp = $vp_pb->{header}->{timestamp};
    my $tu_header_timestamp = $tu_pb->{header}->{timestamp};
    my $vp_header_time = strftime("%m/%d %H:%M:%S", localtime($vp_header_timestamp));
    my $tu_header_time = strftime("%m/%d %H:%M:%S", localtime($tu_header_timestamp));
    print("Trip updates      as of $tu_header_time\n");
    print("Vehicle positions as of $vp_header_time\n");


    my @vp_entity = grep { eval { $_->{vehicle}->{trip}->{trip_id} eq $trip_id } } @{$vp_pb->{entity}};
    if (scalar(@vp_entity) < 1) {
	warn("Unexpected transit data: more than one vehicle update record with trip id = $trip_id\n");
    } elsif (scalar(@vp_entity) > 1) {
	warn("Unexpected transit data: no vehicle update record with trip id = $trip_id\n");
    }
    my $vp_entity = $vp_entity[0];

    if ($self->{verbose}) {
	print("-------------------------------------------------------------------------------\n");
	print($self->{compact}->encode($vp_entity));
    }

    my @tu_entity = grep { eval { $_->{trip_update}->{trip}->{trip_id} eq $trip_id } } @{$tu_pb->{entity}};
    if (scalar(@tu_entity) < 1) {
	warn("Unexpected transit data: more than one trip entity with trip id = $trip_id\n");
    } elsif (scalar(@tu_entity) > 1) {
	warn("Unexpected transit data: no trip entity with trip id = $trip_id\n");
    }
    my $tu_entity = $tu_entity[0];
    my %su_by_stop_sequence;
    my %su_by_stop_id;
    foreach my $su (@{$tu_entity->{trip_update}->{stop_time_update}}) {
	$su_by_stop_sequence{$su->{stop_sequence}} = $su;
	$su_by_stop_id{$su->{stop_id}} = $su;
    }

    if ($self->{verbose}) {
	print($self->{compact}->encode($tu_entity));
	print("-------------------------------------------------------------------------------\n");
    }

    my $trip  = $gtfs->get_trip_by_trip_id($trip_id);
    my $route = $gtfs->get_route_by_trip_id($trip_id);
    my @stops = $gtfs->get_stops_by_trip_id($trip_id);

    printf("Trip %s on route %s -- [%s %s]\n",
	   $trip->{trip_id},
	   $trip->{route_id},
	   $trip->{route_id},
	   $trip->{trip_headsign});

    my @head = ("Sch.Arr.", "Sch.Dep.", "Est.Time", "Dly.", "Location", "StopID", "StopName", "StopDesc");
    my $tft   = Text::FormatTable->new("l|l|l|r|l|l|l|l");
    $tft->head(@head);
    $tft->rule("=");
    my $gotit = 0;

    my ($prev_lat, $prev_lon);
    
    foreach my $stop (@stops) {
	my $su = $su_by_stop_id{$stop->{stop_id}};

	my $est_time = eval { $su->{departure}->{time} }  // eval { $su->{arrival}->{time} };
	my $delay   = eval { $su->{departure}->{delay} } // eval { $su->{arrival}->{delay} };

	$est_time = $est_time && strftime("%H:%M:%S", localtime($est_time));

	my $lat = $stop->{stop_lat};
	my $lon = $stop->{stop_lon};

	if (!$gotit && defined $est_time && $vp_entity) {
	    my $go = 0;

	    my $ts = eval { $vp_entity->{vehicle}->{timestamp} };
	    $ts = defined($ts) && strftime("%H:%M:%S", localtime($ts));

	    if (defined $ts) {
		if ($ts le $est_time) {
		    $go = 1;
		}
	    } else {
		$go = 1;
	    }

	    if ($go) {
		$gotit = 1;
		my $lat = eval { $vp_entity->{vehicle}->{position}->{latitude} };
		my $lon = eval { $vp_entity->{vehicle}->{position}->{longitude} };
		my $location = defined($lat) && defined($lon) && sprintf("%10.6f,%10.6f", $lat, $lon);
		$tft->rule("-");
		$tft->row("", "", $ts // "-", "", $location // "-", "", "", "");
		$tft->rule("-");
	    }
	}

	my $location = sprintf("%10.6f,%10.6f", $lat, $lon);
	$tft->row($stop->{arrival_time}   // "-",
		  $stop->{departure_time} // "-",
		  $est_time                // "-",
		  $delay                  // "-",
		  $location               // "-",
		  $stop->{stop_id}        // "-",
		  $stop->{stop_name}      // "-",
		  $stop->{stop_desc}      // "-");

	$prev_lat = $lat if defined $lat;
	$prev_lon = $lon if defined $lon;
    }
    if ($self->{width}) {
	print $tft->render($self->{width});
    } else {
	print $tft->render($COLUMNS);
    }
}

use constant D2R => atan2(1, 1) / 45;
sub _dist_A_B {
    my ($lat1, $lng1, $lat2, $lng2) = @_;
    $lat1 *= D2R;
    $lng1 *= D2R;
    $lat2 *= D2R;
    $lng2 *= D2R;
    my $y1 = log(abs((1 + sin($lat1)) / cos($lat1)));
    my $y2 = log(abs((1 + sin($lat2)) / cos($lat2)));
    my $x1 = $lng1;
    my $x2 = $lng2;
    my $xx = $x1 - $x2;
    my $yy = $y1 - $y2;
    return sqrt($xx * $xx + $yy * $yy);
}

###############################################################################

package My::JSON::Encoder::Compact;
use JSON qw(-convert_blessed_universally);
sub new {
    my ($class, %args) = @_;
    my $self = bless({ json => JSON->new()->allow_nonref()->pretty()->convert_blessed(),
		       compactness => 1,
		       %args }, $class);
    return $self;
}
sub encode {
    my ($self, $data) = @_;
    if (ref($data)) {
	$data = $self->{json}->encode($data);
	$data = $self->{json}->decode($data);
    }
    my $encoded = "";
    $self->__encode(stringref => \$encoded, data => $data);
    return $encoded . "\n";
}
sub __encode {
    my ($self, %args) = @_;

    my $stringref     = $args{stringref};
    my $data          = $args{data};
    my $indent        = $args{indent}        // 0;
    my $extra_compact = $args{extra_compact} // 0;
    my $stack         = $args{stack}         // [];

    my $ref = ref($data);
    if (!$ref) {
	my $enc = $self->{json}->encode($data);
	chomp($enc);
	$$stringref .= $enc;
    } elsif ($ref eq "ARRAY") {
	if (scalar(@$data) == 0) {
	    $$stringref .= "[]";
	} else {
	    my $newlines = 1;
	    if ($extra_compact) {
		$newlines = 0;
	    } elsif ($self->{compactness} >= 2) {
		if (!grep { ref($_) } @$data) {
		    $newlines = 0;
		}
	    }
	    $$stringref .= "[ ";
	    $indent += 2;

	    my $extra_compact = $extra_compact || eval { $self->{extra_compact}->{$stack->[-1] . "[]"} };

	    for (my $i = 0; $i <= scalar(@$data); $i += 1) {
		if ($i) {
		    if ($newlines) {
			$$stringref .= ",\n" . (" " x $indent);
		    } else {
			$$stringref .= ", ";
		    }
		}
		$self->__encode(stringref => $stringref,
				data => $data->[$i],
				indent => $indent,
				extra_compact => $extra_compact,
				stack => [@$stack, "[]"]);
	    }
	    $$stringref .= " ]";
	}
    } elsif ($ref eq "HASH") {
	my @keys = keys(%$data);
	if (scalar(@keys) == 0) {
	    $$stringref .= "{}";
	} else {
	    my $newlines = 1;
	    if ($extra_compact) {
		$newlines = 0;
	    } elsif ($self->{compactness} >= 2) {
		if (!grep { ref($_) } values(%$data)) {
		    $newlines = 0;
		}
	    }
	    $$stringref .= "{ ";
	    $indent += 2;
	    for (my $i = 0; $i < scalar(@keys); $i += 1) {
		my $key = $keys[$i];
		my $extra_compact = $extra_compact || eval { $self->{extra_compact}->{$key} };
		my $value = $data->{$key};
		my $sub = eval { $self->{convert_key}->{$key} };
		if ($sub && ref($sub) eq "CODE") {
		    my $new_value = $sub->($value);
		    next if !defined $new_value;
		    $value = $new_value;
		}
		if ($i) {
		    if ($newlines) {
			$$stringref .= ",\n" . (" " x $indent);
		    } else {
			$$stringref .= ", ";
		    }
		}
		my $key_enc = $self->{json}->encode($key);
		chomp($key_enc);
		$$stringref .= $key_enc;
		$$stringref .= ": ";
		$self->__encode(stringref => $stringref,
				data => $value,
				indent => $indent + length($key_enc) + 2,
				extra_compact => $extra_compact,
				stack => [@$stack, $key]);
	    }
	    $$stringref .= " }";
	}
    } else {
	my $enc = $self->{json}->encode("$data");
	chomp($enc);
	$$stringref .= $enc;
    }
}

1;
