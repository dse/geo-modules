package Geo::GTFS::Realtime;
use warnings;
use strict;

use lib "$ENV{HOME}/git/HTTP-Cache-Transparent/lib";
# my fork adds a special feature called NoUpdateImpatient.

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
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->init() if $self->can('init');
    return $self;
}

sub cache_set {
    my ($self, %args) = @_;
    my $cache_options = $self->{cache_options} //=
      { BasePath => "$ENV{HOME}/.http-cache-transparent",
	Verbose => 1,
	NoUpdate => 30,
	NoUpdateImpatient => 1 };
    %$cache_options = (%$cache_options, %args);
    HTTP::Cache::Transparent::init($cache_options);
}

sub init {
    my ($self) = @_;

    $self->cache_set();
    $self->{ua} = LWP::UserAgent->new();

    $self->{gtfs_realtime_proto}   = "https://developers.google.com/transit/gtfs-realtime/gtfs-realtime.proto";
    $self->pull_protocol();

    $self->{my_cache}              = "$ENV{HOME}/.my-gtfs-realtime-data/cache";
    make_path($self->{my_cache});

    $self->{feed_types} = [ qw(alerts
			       realtime_feed
			       trip_updates
			       vehicle_positions) ];
    $self->{feed_urls}  = { qw(alerts             http://googletransit.ridetarc.org/realtime/alerts/Alerts.pb
			       realtime_feed      http://googletransit.ridetarc.org/realtime/gtfs-realtime/TrapezeRealTimeFeed.pb
			       trip_updates       http://googletransit.ridetarc.org/realtime/trip_update/TripUpdates.pb
			       vehicle_positions  http://googletransit.ridetarc.org/realtime/vehicle/VehiclePositions.pb) };
    $self->init_converters();
}

sub init_converters {
    my ($self) = @_;
    my $json = JSON->new()->allow_nonref()->pretty()->convert_blessed();
    $self->{output_formats} = [ qw(json yaml dumper) ]; 
    $self->{output_converters} = {
	"json" => { 
	    # "code" => sub { ... },
	    "ext"  => "json"
	},
	"yaml" => {
	    # "code" => sub { ... },
	    "ext"  => "yaml"
	},
	"dumper" => {
	    # "code" => sub { ... },
	    "ext"  => "dumper"
	},
    };
}

sub pull_protocol {
    my ($self) = @_;
    $self->cache_set(NoUpdate => 86400, NoUpdateImpatient => 0);
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
    $self->cache_set(NoUpdate => 30, NoUpdateImpatient => 1);
    warn(sprintf("Current time: %d %s\n", time(), scalar(localtime())));
    my $request = HTTP::Request->new("GET", $self->{feed_urls}->{vehicle_positions});
    my $response = $self->{ua}->request($request);
}

sub pull {
    my ($self) = @_;

    my @feed_types = @{$self->{feed_types}};

    my $make_hash_by_feed_type = sub {
	my ($sub) = @_;
	return map { ($_ => &$sub()) } @feed_types;
    };
    my %req = $make_hash_by_feed_type->(sub { HTTP::Request->new("GET", $self->{feed_urls}->{$_}) });
    $self->cache_set(NoUpdate => 30, NoUpdateImpatient => 1);
    my %res = $make_hash_by_feed_type->(sub { $self->{ua}->request($req{$_}) });
    my @failures = grep { !$_->is_success() } values %res;
    if (scalar(@failures)) {
	warn(sprintf("FAIL: %s => %s\n", $_->request()->uri(), $_->status_line())) foreach @failures;
	exit(1);
    }

    my %pb = $make_hash_by_feed_type->(sub { $res{$_}->content() });
    my %lm = $make_hash_by_feed_type->(sub { $res{$_}->last_modified() });
    my %ts = $make_hash_by_feed_type->(sub { strftime("%Y/%m/%d/%H%M%SZ", gmtime($lm{$_})) });

    warn("Decoding ...\n");
    my %message_object = $make_hash_by_feed_type->(sub { TransitRealtime::FeedMessage->decode($pb{$_}) });

    my %filename;
    my %latest;

    # write .pb files

    $filename{pb}   = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/pb/%s.pb",     $self->{my_cache}, $_, $ts{$_}) }) };
    $latest{pb}     = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/pb/latest.pb", $self->{my_cache}, $_         ) }) };

    foreach my $feed_type (@feed_types) {
	_file_put_contents($filename{pb}{$feed_type}, $pb{$feed_type}, "b");
    }

    # convert to other formats and write them

    my @output_formats = @{$self->{output_formats}};
    foreach my $output_format (@output_formats) {
	my $converter = $self->{output_converters}->{$output_format};
	$filename{$output_format} = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/%s/%s.%s",     $self->{my_cache}, $_, $output_format, $ts{$_}, $converter->{ext}) }) };
	$latest{$output_format}   = { $make_hash_by_feed_type->(sub { sprintf("%s/%s/%s/latest.%s", $self->{my_cache}, $_, $output_format,          $converter->{ext}) }) };
    }

    my $json = JSON->new()->allow_nonref()->pretty()->convert_blessed();

    my $output_formats = _join_and(@output_formats);
    warn("Encoding $output_formats ...\n");
    my %encoded;
    $encoded{json}   = { $make_hash_by_feed_type->(sub { $json->encode($message_object{$_}) }) };
    $encoded{yaml}   = { $make_hash_by_feed_type->(sub { YAML::Syck::Dump($message_object{$_}) }) };
    $encoded{dumper} = { $make_hash_by_feed_type->(sub { Data::Dumper::Dumper($message_object{$_}) }) };
    foreach my $feed_type (@feed_types) {
	foreach my $output_format (@output_formats) {
	    _file_put_contents($filename{$output_format}{$feed_type}, $encoded{$output_format}{$feed_type});
	}
    }

    # create symlinks

    warn("Creating symbolic links ...\n");
    foreach my $output_format (@output_formats, "pb") {
	foreach my $feed_type (@feed_types) {
	    my ($source, $dest) = ($filename{$output_format}{$feed_type}, $latest{$output_format}{$feed_type});
	    _symlink($source, $dest);
	}
    }

    # /home/dembry/.my-gtfs-realtime-data/cache/FEED_TYPE/OUTPUT_FORMAT/YYYY/MM/DD/HHMMSSZ.EXT

    # warn("Wildcards:\n");
    # foreach my $output_format (@output_formats, "pb") {
    # 	my $converter = $self->{output_converters}->{$output_format};
    # 	warn(sprintf("  %s/%s/%s/%s.%s\n", $self->{my_cache}, "*",        $output_format, "*/*/*/*", $converter->{ext}));
    # }
    # foreach my $feed_type (@feed_types) {
    # 	warn(sprintf("  %s/%s/%s/%s.%s\n", $self->{my_cache}, $feed_type, "*",            "*/*/*/*", "*"));
    # }
}

sub get_all_versions {
    my ($self) = @_;
    return if $self->{versions};

    my $v = $self->{versions} = {};

    my $dir = $self->{my_cache};
    my @pb = glob("$dir/*/pb/????/??/??/??????Z.pb");
    my %time_t;
    my %date;
    foreach my $pb (@pb) {
	my $rel = abs2rel($pb, $dir);
	if ($rel =~ m{(?:^|/)([^/]+)/pb/(\d+)/(\d+)/(\d+)/(\d\d)(\d\d)(\d\d)Z\.}) {
	    my ($feed_type, $yyyy, $mm, $dd, $hh, $mi, $ss) = ($1, $2, $3, $4, $5, $6, $7);
	    foreach ($yyyy, $mm, $dd, $hh, $mi, $ss) {
		$_ =~ s{^0+}{};	# avoid octal parsing
		$_ = $_ + 0;	# force to number
	    }
	    my $time_t = timegm($ss, $mi, $hh, $dd, $mm - 1, $yyyy);
	    my $date = strftime("%Y-%m-%d", localtime($time_t));
	    my $feed_type_rec = {
		time_t => $time_t,
		date => $date,
		pb => $pb,
	    };
	    my $rec = {
		time_t => $time_t,
		date => $date,
	    };
	    $v->{$feed_type}->{date}->{$date}->{$time_t} = $feed_type_rec;
	    $v->{$feed_type}->{time_t}->{$time_t} = $feed_type_rec;
	    $v->{date}->{$date}->{$time_t} = $rec;
	    $v->{time_t}->{$time_t} = $rec;
	}
    }
}

sub list_dates {
    my ($self) = @_;
    $self->get_all_versions();

    my @date = reverse sort keys %{$self->{versions}->{date}};
    if (scalar(@date) > 20) {
	splice(@date, 20);
    }
    return @date;
}

sub list_versions_by_date {
    my ($self, $date) = @_;
    $self->get_all_versions();

    my @time_t = reverse sort { $a <=> $b } keys %{$self->{versions}->{date}->{$date}};
    if (scalar(@time_t) > 20) {
	splice(@time_t, 20);
    }
    printf("  %12d => %s\n", $_, scalar(localtime($_))) foreach @time_t;
    return @time_t;
}

sub list_trip_updates {
    my ($self, $version) = @_;
    $self->get_all_versions();

    my $vp_pb_filename = $self->{versions}->{vehicle_positions}->{time_t}->{$version}->{pb};
    my $vp_pb_encoded = _file_get_contents($vp_pb_filename, "b");
    my $vp_pb = TransitRealtime::FeedMessage->decode($vp_pb_encoded);
    my $vp_header_timestamp = $vp_pb->{header}->{timestamp};

    my $tu_pb_filename = $self->{versions}->{trip_updates}->{time_t}->{$version}->{pb};
    my $tu_pb_encoded = _file_get_contents($tu_pb_filename, "b");
    my $tu_pb = TransitRealtime::FeedMessage->decode($tu_pb_encoded);
    my $tu_header_timestamp = $tu_pb->{header}->{timestamp};

    my $vp_header_time = strftime("%m/%d %H:%M:%S", localtime($vp_header_timestamp));
    my $tu_header_time = strftime("%m/%d %H:%M:%S", localtime($tu_header_timestamp));

    print("Trip updates      as of $tu_header_time\n");
    print("Vehicle positions as of $tu_header_time\n");

    my %vehicle;

    foreach my $entity (@{$vp_pb->{entity}}) {
	my $label     = eval { $entity->{vehicle}->{vehicle}->{label} } //
	  eval { $entity->{id} };
	my $timestamp = eval { $entity->{vehicle}->{timestamp} };
	my $trip_id   = eval { $entity->{vehicle}->{trip}->{trip_id} };
	next if !defined $label;
	my $rec = {
	    label => $label,
	    ((defined $timestamp) ? (timestamp => $timestamp) : ()),
	    ((defined $trip_id)   ? (trip_id   => $trip_id  ) : ()),
	};
	$vehicle{$label} = $rec;
    }

    foreach my $entity (@{$tu_pb->{entity}}) {
	my $tu       = eval { $entity->{trip_update} };
	next if !defined $tu;

	my $trip_id  = eval { $tu->{trip}->{trip_id} } // eval { $tu->{id} };
	my $route_id = eval { $tu->{trip}->{route_id} };
	my $label    = eval { $tu->{vehicle}->{label} };
	next if !defined $label;

	my $start_time = eval { $tu->{trip}->{start_time} };
	my $start_date = eval { $tu->{trip}->{start_date} };
	my $delay = eval { $tu->{stop_time_update}->[0]->{departure}->{delay} };
	$delay /= 60 if defined $delay;
	my $dep_arr_time = eval { $tu->{stop_time_update}->[0]->{departure}->{time} } // eval { $tu->{stop_time_update}->[0]->{arrival}->{time} };
	my $dep_arr_time_fmt = defined $dep_arr_time && eval { strftime("%m/%d %H:%M:%S", localtime($dep_arr_time)) };

	my $vehicle = $vehicle{$label};
	my $timestamp = eval { $vehicle->{timestamp} };
	my $timestamp_fmt = defined $timestamp && eval { strftime("%m/%d %H:%M:%S", localtime($timestamp)) };
	
	next if !defined $timestamp;
	next if $tu_header_timestamp - $timestamp >= 1800;

	printf("    veh %-8s  trip_id %-8s  route %-8s  deptime %-14s  timestamp %-14s  delay %d\n",
	       $label // "-",
	       $trip_id // "-", 
	       $route_id // "-",
	       $dep_arr_time_fmt // "-",
	       $timestamp_fmt // "-",
	       floor(($delay // 0) + 0.5));
    }
}

sub _symlink {
    my ($source, $dest) = @_;
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
    warn(sprintf("  Created symlink to %-27s: %s\n", $rel_source, $dest)); # assuming max 8 chars. extension
}

BEGIN {
    my $h = select(STDERR);
    $| = 1;
    select($h);
}

sub _file_put_contents {
    my ($filename, $data, $mode) = @_;
    make_path(dirname($filename));
    open(my $fh, ">", $filename) or do {
	warn("  cannot write $filename: $!\n");
	return;
    };
    printf STDERR ("  Writing %s (%d bytes) ... ", $filename, length($data));
    if (defined $mode && $mode eq "b") {
	binmode($fh);
    }
    print $fh $data;
    print STDERR ("Done.\n");
}

sub _file_get_contents {
    my ($filename, $mode) = @_;
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

1;
