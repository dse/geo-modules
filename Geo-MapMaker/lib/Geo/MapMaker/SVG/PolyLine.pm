package Geo::MapMaker::SVG::PolyLine;
use warnings;
use strict;
use v5.10.0;

use fields qw(points is_closed);

sub new {
    my $class = shift;
    my $self = fields::new($class);
    $self->{points} = [];
    if (scalar @_ == 0) {
        return $self;
    }
    if (scalar @_ == 1 && ref $_->[0] eq __PACKAGE__) {
        @{$self->{points}} = @{$_->[0]->{points}};
        return $self;
    }
    foreach my $point (@_) {
        push(@{$self->{points}}, Geo::MapMaker::SVG::Point->object($point));
    }
    return $self;
}

sub object {
    my $class = shift;
    return $_[0] if scalar @_ == 1 && eval { $_[0]->isa(__PACKAGE__) };
    return $class->new(@_);
}

sub add { goto &add_points; }

sub add_xy { goto &add_point; }

sub add_points {
    my ($self, @points) = @_;
    foreach my $point (@points) {
        push(@{$self->{points}}, Geo::MapMaker::SVG::Point->object($point));
    }
}

sub add_point {
    my $self = shift;
    push(@{$self->{points}}, Geo::MapMaker::SVG::Point->object(@_));
}

sub clear {
    my ($self) = @_;
    @{$self->{points}} = [];
}

sub points {
    my $self = shift;
    if (scalar @_) {
        @{$self->{points}} = @_;
    }
    return @{$self->{points}} if wantarray;
    return $self->{points};
}

sub as_string {
    my ($self, %args) = @_;
    my $position_dx = $args{position_dx};
    my $position_dy = $args{position_dy};
    my $is_first = $args{is_first} // 1;
    my $is_only  = $args{is_only} // 1;
    my $result;
    my $count = scalar @{$self->{points}};
    for (my $i = 0; $i < $count; $i += 1) {
        my $point = $self->{points}->[$i];
        my $x = $point->X;
        my $y = $point->Y;
        $x += $position_dx if defined $position_dx;
        $y += $position_dy if defined $position_dy;
        my $prev_point = ($i > 0) ? $self->{points}->[$i - 1] : undef;
        my ($dx, $dy) = ($i > 0) ? $point->DX_DY($prev_point) : (undef, undef);
        if ($is_first || $is_only) {
            if ($i == 0) {
                $result = sprintf('m %.2f,%.2f', $x, $y);
            } else {
                $result .= sprintf(' %.2f,%.2f', $dx, $dy);
            }
        } else {
            if ($i == 0) {
                $result = sprintf('M %.2f,%.2f', $x, $y);
            } elsif ($i == 1) {
                $result .= sprintf(' l %.2f,%.2f', $dx, $dy);
            } else {
                $result .= sprintf(' %.2f,%.2f', $dx, $dy);
            }
        }
    }
    if ($self->is_closed) {
        if ($is_only) {
            $result .= ' z';
        } else {
            my $point0 = $self->{points}->[0];
            my $x = $point0->X;
            my $y = $point0->Y;
            $x += $position_dx if defined $position_dx;
            $y += $position_dy if defined $position_dy;
            $result .= sprintf(' L %.2f,%.2f', $x, $y);
        }
    }
    return $result;
}

sub is_self_closing {
    my $self = shift;
    return 0 if scalar @{$self->{points}} < 2;
    my $a = $self->{points}->[0];
    my $b = $self->{points}->[-1];
    return $a->is_at($b);
}

sub is_closed {
    my $self = shift;
    return $self->{is_closed} unless scalar @_;
    return $self->{is_closed} = shift;
}

sub is_polygon {
    my $self = shift;
    return $self->{is_closed} unless scalar @_;
    return $self->{is_closed} = shift;
}

sub scale {
    my $self = shift;
    $self->foreach_point('scale', @_);
}

sub scale_x {
    my $self = shift;
    $self->foreach_point('scale_x', @_);
}

sub scale_y {
    my $self = shift;
    $self->foreach_point('scale_y', @_);
}

sub translate {
    my $self = shift;
    $self->foreach_point('translate', @_);
}

sub translate_x {
    my $self = shift;
    $self->foreach_point('translate_x', @_);
}

sub translate_y {
    my $self = shift;
    $self->foreach_point('translate_y', @_);
}

sub foreach_point {
    my $self = shift;
    my $method = shift;
    my @args = @_;
    if (defined $method) {
        $_->$method(@args) foreach @{$self->{points}};
    }
}

1;
