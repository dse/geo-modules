package Geo::MapMaker::OSM::Way;
use warnings;
use strict;
use v5.10.0;

use lib "$ENV{HOME}/git/dse.d/geo-modules/Geo-MapMaker/lib";
use base 'Geo::MapMaker::OSM::Object';

use Geo::MapMaker::Constants qw(:all);
use Geo::MapMaker::SVG::PolyLine;
use List::MoreUtils qw(all);
use Data::Dumper qw(Dumper);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    bless($self, $class);

    return $self;
}

sub svg_object {
    my ($self, %args) = @_;
    my $map_area_index = $args{map_area_index} || 0;
    my $is_closed = $args{is_closed} // $self->{is_closed};
    my @svg_coords = grep { $_ } map { $_->{svg_coords}->[$map_area_index] } @{$self->{node_array}};
    return unless scalar @svg_coords;
    if (all { $_->[POINT_X_ZONE] == -1 } @svg_coords) { return; }
    if (all { $_->[POINT_X_ZONE] ==  1 } @svg_coords) { return; }
    if (all { $_->[POINT_Y_ZONE] == -1 } @svg_coords) { return; }
    if (all { $_->[POINT_Y_ZONE] ==  1 } @svg_coords) { return; }
    my $polyline = Geo::MapMaker::SVG::PolyLine->new(@svg_coords);
    return $polyline;
}

sub is_closed {
    my ($self) = @_;
    return $self->is_self_closing();
}

sub is_complete {
    my ($self) = @_;
    return scalar @{$self->{node_array}} == scalar @{$self->{node_ids}};
}

sub is_self_closing {
    my ($self) = @_;
    return $self->is_complete && scalar @{$self->{node_ids}} > 1 &&
        $self->{node_array}->[0]->{-id} eq $self->{node_array}->[-1]->{-id};
}

sub css_class_suffix {
    my ($self) = @_;
    if ($self->is_self_closing) {
        return ' CLOSED';
    }
    return ' OPEN';
}

1;
