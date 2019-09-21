package Geo::MapMaker::OSM::Object;
use warnings;
use strict;
use v5.10.0;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";
use Geo::MapMaker::Constants qw(:tags);

use Sort::Naturally qw(nsort);
use Text::Trim;

sub new {
    my $class = shift;
    return bless(shift, $class);
}

sub convert_tags {
    my ($self) = @_;
    return if $self->{tags} || $self->{index};
    $self->{tags} = {};
    $self->{index} = {};
    foreach my $tag (@{$self->{tag}}) {
        my $k = $tag->{-k};
        my $v = $tag->{-v};
        $self->{tags}->{$k} = $v;
        $self->{index}->{$k} = 1; # incase of tags: { k: '...' } in a layer.
        if (defined $v && $v ne '') {
            $self->{index}->{$k,$v} = 1;
        }
    }
    delete $self->{tag};
}

# can be checked on all objects
sub is_multipolygon_relation {
    my $self = shift;
    return $self->isa('Geo::MapMaker::OSM::Relation') &&
        defined $self->{tags}->{type} &&
        $self->{tags}->{type} eq 'multipolygon';
}

sub css_id {
    my ($self, %args) = @_;
    my $result = '';
    if ($self->isa('Geo::MapMaker::OSM::Node')) {
        $result .= 'osm-node-';
    } elsif ($self->isa('Geo::MapMaker::OSM::Way')) {
        $result .= 'osm-way-';
    } elsif ($self->isa('Geo::MapMaker::OSM::Relation')) {
        $result .= 'osm-relation-';
    } else {
        $result .= 'osm-object-';
    }
    $result .= $self->{-id};
    return $result;
}

# https://wiki.openstreetmap.org/wiki/Map_Features

sub css_classes {
    my ($self, %args) = @_;
    my @css_classes = ('osm');
  tag:
    foreach my $k (nsort keys %{$self->{tags}}) {
        foreach my $t (@EXCLUDE_TAG_NAMES) {
            next tag if ref $t eq 'Regexp' && $k =~ $t;
        }
        next if $EXCLUDE_TAG_NAMES->{$k};
        my $v = $self->{tags}->{$k};
        next unless $TAG_NAME_WHITELIST->{$k} || $TAG_NAME_VALUE_WHITELIST->{"${k}=${v}"};
        push(@css_classes, "osm-tag-${k}");
        push(@css_classes, "osm-tag-${k}-${v}");
    }
    my $object_class = $args{object_class};
    if (defined $object_class && $object_class =~ m{\S}) {
        push(@css_classes, split(' ', trim($object_class)));
    }
    return @css_classes;
}

sub css_class_string {
    my ($self, %args) = @_;
    my $layer = $args{layer};
    my @css_classes = $self->css_classes(%args);
    my $css_class_string = join(' ', @css_classes);
    return $css_class_string;
}

1;
