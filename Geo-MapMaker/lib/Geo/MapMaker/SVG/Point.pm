package Geo::MapMaker::SVG::Point;
use warnings;
use strict;
use v5.10.0;

use fields qw(x y);

use constant ROUND => 100;

use Data::Dumper qw(Dumper);

sub new {
    my $class = shift;
    my $self = fields::new($class);
    if (scalar @_ == 2) {
        my ($x, $y) = @_;
        $self->{x} = $x // 0;
        $self->{y} = $y // 0;
        return $self;
    }
    if (scalar @_ == 1) {
        my $from = shift;
        if (eval { $from->isa(__PACKAGE__) }) {
            $self->{x} = $from->x;
            $self->{y} = $from->y;
        } elsif (ref $from eq 'ARRAY') {
            $self->{x} = $from->[0] // 0;
            $self->{y} = $from->[1] // 0;
        } else {
            die("Geo::MapMaker::SVG::Point: " .
                    "one-argument new must be called with a ::Point or arrayref.\n");
        }
        return $self;
    }
    if (scalar @_ == 0) {
        $self->{x} = 0;
        $self->{y} = 0;
        return $self;
    }
    die("Geo::MapMaker::SVG::Point: " .
            "new must be called with between 0 and 2 arguments.\n");
}

sub object {
    my $class = shift;
    return $_[0] if scalar @_ == 1 && eval { $_[0]->isa(__PACKAGE__) };
    return $class->new(@_);
}

sub x {
    my $self = shift;
    return $self->{x} unless scalar @_;
    return $self->{x} = shift;
}

sub y : {                       # : is a cperl-mode workaround
    my $self = shift;
    return $self->{y} unless scalar @_;
    return $self->{y} = shift;
}

sub x_y {
    my ($self) = @_;
    my ($x, $y) = ($self->x, $self->y);
    return ($x, $y) if wantarray;
    return [$x, $y];
}

sub dx {
    my ($self, $other_point) = @_;
    return $self->x - $other_point->x;
}

sub dy {
    my ($self, $other_point) = @_;
    return $self->y - $other_point->y;
}

sub dx_dy {
    my ($self, $other_point) = @_;
    my ($dx, $dy) = ($self->x - $other_point->x,
                     $self->y - $other_point->y);
    return ($dx, $dy) if wantarray;
    return [$dx, $dy];
}

sub X {
    my ($self) = @_;
    return int($self->{x} * ROUND + 0.5) / ROUND;
}

sub Y {
    my ($self) = @_;
    return int($self->{y} * ROUND + 0.5) / ROUND;
}

sub DX {
    my ($self, $other_point) = @_;
    return $self->X - $other_point->X;
}

sub DY {
    my ($self, $other_point) = @_;
    return $self->Y - $other_point->Y;
}

sub X_Y {
    my ($self) = @_;
    return ($self->X, $self->Y) if wantarray;
    return [$self->X, $self->Y];
}

sub DX_DY {
    my ($self, $other_point) = @_;
    return ($self->DX($other_point), $self->DY($other_point)) if wantarray;
    return [$self->DX($other_point), $self->DY($other_point)];
}

sub scale {
    my ($self, $scale_x, $scale_y) = @_;
    $scale_y //= $scale_x;
    $scale_x //= $scale_y;
    $self->{x} *= $scale_x if defined $scale_x;
    $self->{y} *= $scale_y if defined $scale_y;
}

sub scale_x {
    my ($self, $scale) = @_;
    $self->{x} *= $scale if defined $scale;
}

sub scale_y {
    my ($self, $scale) = @_;
    $self->{y} *= $scale if defined $scale;
}

sub translate {
    my ($self, $dx, $dy) = @_;
    $dy //= $dx;
    $dx //= $dy;
    $self->{x} += $dx if defined $dx;
    $self->{y} += $dy if defined $dy;
}

sub translate_x {
    my ($self, $dx) = @_;
    $self->{x} += $dx if defined $dx;
}

sub translate_y {
    my ($self, $dy) = @_;
    $self->{y} += $dy if defined $dy;
}

1;
