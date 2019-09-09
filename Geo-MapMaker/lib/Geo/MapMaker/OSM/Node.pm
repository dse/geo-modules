package Geo::MapMaker::OSM::Node;
use warnings;
use strict;
use v5.10.0;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";
use base 'Geo::MapMaker::OSM::Object';

sub svg_object {
    # placeholder
    return;
}

sub css_classes {
    my ($self, %args) = @_;
    my @css_classes = $self->SUPER::css_classes(%args);
    push(@css_classes, 'osm-node');
    return @css_classes;
}

1;
