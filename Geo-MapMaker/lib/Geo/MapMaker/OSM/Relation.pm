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
}

sub svg_object_non_mpr {
    my ($self, %args) = @_;
    my $map_area_index = $args{map_area_index} || 0;
}

1;
