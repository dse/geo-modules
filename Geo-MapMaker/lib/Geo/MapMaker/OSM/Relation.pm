package Geo::MapMaker::OSM::Relation;
use warnings;
use strict;
use v5.10.0;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";
use base 'Geo::MapMaker::OSM::Object';

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    bless($self, $class);

    return $self;
}

sub svg_object {
    my ($self, %args) = @_;
    if ($self->is_multipolygon_relation()) {
        return $self->svg_object_mpr(%args);
    }
    return $self->svg_object_non_mpr(%args);
}

sub svg_object_mpr {
    my ($self, %args) = @_;
    my $map_area_index = $args{map_area_index} || 0;
    my $map_area = $args{map_area};
    my $css_class = $args{css_class};
    my $css_id = $self->css_id();
    my $attr = $args{attr} || {};
    $css_class .= $self->css_class_suffix();

    my $path = Geo::MapMaker::SVG::Path->new();
    foreach my $way (@{$self->{way_array}}) {
        my $polyline = $way->svg_object(map_area_index => $map_area_index);
        next unless $polyline;
        $path->add($polyline);
    }
    $path->stitch_polylines();
    return $path;
}

sub svg_object_non_mpr {
    my ($self, %args) = @_;
    my $map_area_index = $args{map_area_index} || 0;
    my $map_area = $args{map_area};
    my $css_class = $args{css_class};
    my $css_id = $self->css_id();
    my $attr = $args{attr} || {};
    $css_class .= $self->css_class_suffix();

    my $path = Geo::MapMaker::SVG::Path->new();
    foreach my $way (@{$self->{way_array}}) {
        my $polyline = $way->svg_object(map_area_index => $map_area_index);
        next unless $polyline;
        $path->add($polyline);
    }
    return $path;
}

sub css_class_suffix {
    my ($self) = @_;
    if ($self->is_multipolygon_relation) {
        return ' MPR';
    }
    return ' NMPR';
}

sub css_classes {
    my ($self, %args) = @_;
    my @css_classes = $self->SUPER::css_classes(%args);
    push(@css_classes, 'osm-relation');
    if ($self->is_multipolygon_relation) {
        push(@css_classes, 'osm-relation-multipolygon');
    } else {
        push(@css_classes, 'osm-relation-non-multipolygon');
    }
    return @css_classes;
}

1;
