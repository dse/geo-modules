package Geo::MapMaker::Config;
use warnings;
use strict;
use YAML::Syck qw(LoadFile Dump);

sub new {
    my ($class, %args) = @_;
    my $self = bless(\%args, $class);
    $self->{file} //= "maps.yaml";
    $self->init();
    return $self;
}

sub init {
    my ($self) = @_;
    $self->{data} = LoadFile($self->{file});
    if (!$self->{data}) {
	die("No config to speak of at $self->{file}.\n");
    }
    $self->find_process_includes();
}

sub find_process_includes {
    my ($self, $data) = @_;
    $data //= $self->{data};
    if (ref($data) eq "ARRAY") {
	foreach my $item (@$data) {
	    $self->find_process_includes($item);
	}
    }
    elsif (ref($data) eq "HASH") {
	foreach my $k (keys(%$data)) {
	    if ($k eq "include") {
		$self->include($data, $data->{$k});
		delete $data->{include};
	    } else {
		$self->find_process_includes($data->{$k});
	    }
	}
    }
}

use Data::Dumper qw(Dumper);

sub include {
    my ($self, $hash, $from) = @_;
    if (ref($from) eq "HASH") {
	while (my ($k, $v) = each(%$from)) {
	    if ($k eq "include") {
		$self->include($hash, $v);
		delete $from->{include};
	    } else {
		$self->merge($hash, $k, $v);
		$self->find_process_includes($v);
	    }
	}
    } elsif (ref($from) eq "") { # string
	my $load = LoadFile($from);
	if (!$load) {
	    die("File $from not found.\n");
	}
	if (ref($load) eq "HASH") {
	    while (my ($k, $v) = each(%$load)) {
		if ($k eq "include") {
		    $self->include($hash, $v);
		    delete $load->{include};
		} else {
		    $self->merge($hash, $k, $v);
		    $self->find_process_includes($v);
		}
	    }
	} else {
	    die("YAML file $from is not a hash.\n");
	}
    } elsif (ref($from) eq "ARRAY") {
	foreach my $value (@$from) {
	    $self->include($hash, $value);
	}
    } elsif ($from->isa("YAML::Syck::BadAlias")) {
	print(Dumper($from));
	die();
    } else {
	die("include: $from (neither hash nor array nor string) specified.\n");
    }
}

sub merge {
    my ($self, $hash, $k, $v) = @_;
    if (exists($hash->{$k})) {
	if ($k eq "classes") {
	    if (ref($hash->{$k}) eq "HASH" && ref($v) eq "HASH") {
		%{$hash->{$k}} = (%{$hash->{$k}}, %$v);
	    } elsif (ref($hash->{$k}) eq "ARRAY" && ref($v) eq "ARRAY") {
		push(@{$hash->{$k}}, @$v);
	    } else {
		$hash->{$k} = $v;
	    }
	} else {
	    $hash->{$k} = $v;
	}
    } else {
	$hash->{$k} = $v;
    }
}

