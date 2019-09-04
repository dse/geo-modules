#!/usr/bin/env perl -T
use warnings;
use strict;
use v5.10.0;

use Test::More;

plan tests => 74;

use Geo::MapMaker::SVG::Point;
use Geo::MapMaker::SVG::Polyline;
use Geo::MapMaker::SVG::Path;

{
    my $point0 = Geo::MapMaker::SVG::Point->new();
    ok($point0->x == 0);
    ok($point0->y == 0);
    $point0->x(0.1234);
    $point0->y(0.5678);
    ok($point0->x == 0.1234);
    ok($point0->y == 0.5678);
    ok($point0->X == 0.12);
    ok($point0->Y == 0.57);

    my $xy = $point0->x_y;
    ok(ref $xy eq 'ARRAY');
    ok(scalar @$xy == 2);
    ok($xy->[0] == 0.1234);
    ok($xy->[1] == 0.5678);

    my @xy = $point0->x_y;
    ok(scalar @xy == 2);
    ok($xy[0] == 0.1234);
    ok($xy[1] == 0.5678);

    my $XY = $point0->X_Y;
    ok(ref $XY eq 'ARRAY');
    ok(scalar @$XY == 2);
    ok($XY->[0] == 0.12);
    ok($XY->[1] == 0.57);

    my @XY = $point0->X_Y;
    ok(scalar @XY == 2);
    ok($XY[0] == 0.12);
    ok($XY[1] == 0.57);

    diag("scale");

    $point0->x(12);
    $point0->y(34);
    $point0->scale(2);
    ok($point0->x == 24);
    ok($point0->y == 68);
    $point0->scale(0.5);
    ok($point0->x == 12);
    ok($point0->y == 34);
    $point0->scale(2, undef);
    ok($point0->x == 24);
    ok($point0->y == 68);
    $point0->scale(undef, 0.5);
    ok($point0->x == 12);
    ok($point0->y == 34);
    $point0->scale_x(2);
    ok($point0->x == 24);
    ok($point0->y == 34);
    $point0->scale_y(2);
    ok($point0->x == 24);
    ok($point0->y == 68);

    diag("translate");

    $point0->translate(1);
    ok($point0->x == 25);
    ok($point0->y == 69);
    $point0->translate(-1);
    ok($point0->x == 24);
    ok($point0->y == 68);
    $point0->translate(1, undef);
    ok($point0->x == 25);
    ok($point0->y == 69);
    $point0->translate(undef, -1);
    ok($point0->x == 24);
    ok($point0->y == 68);
    $point0->translate_x(10);
    ok($point0->x == 34);
    ok($point0->y == 68);
    $point0->translate_y(10);
    ok($point0->x == 34);
    ok($point0->y == 78);
}

diag("X/Y/DX/DY");

{
    my $point0 = Geo::MapMaker::SVG::Point->new(0.1234, 0.5678);
    ok($point0->x == 0.1234);
    ok($point0->y == 0.5678);
    ok($point0->X == 0.12);
    ok($point0->Y == 0.57);

    my $point1 = Geo::MapMaker::SVG::Point->new(1.5678, 1.1234);
    ok($point1->dx($point0) == (1.5678 - 0.1234));
    ok($point1->dy($point0) == (1.1234 - 0.5678));
    ok($point1->DX($point0) == (1.57 - 0.12));
    ok($point1->DY($point0) == (1.12 - 0.57));

    my $dx_dy = $point1->dx_dy($point0);
    ok(ref $dx_dy eq 'ARRAY');
    ok(scalar @$dx_dy == 2);
    ok($dx_dy->[0] == (1.5678 - 0.1234));
    ok($dx_dy->[1] == (1.1234 - 0.5678));

    my @dx_dy = $point1->dx_dy($point0);
    ok(scalar @dx_dy == 2);
    ok($dx_dy[0] == (1.5678 - 0.1234));
    ok($dx_dy[1] == (1.1234 - 0.5678));

    my $DX_DY = $point1->DX_DY($point0);
    ok(ref $DX_DY eq 'ARRAY');
    ok(scalar @$DX_DY == 2);
    ok($DX_DY->[0] == (1.57 - 0.12));
    ok($DX_DY->[1] == (1.12 - 0.57));

    my @DX_DY = $point1->DX_DY($point0);
    ok(scalar @DX_DY == 2);
    ok($DX_DY[0] == (1.57 - 0.12));
    ok($DX_DY[1] == (1.12 - 0.57));

    my $s;

    my $polyline0 = Geo::MapMaker::SVG::Polyline->new($point0, $point1);
    ok($polyline0->as_string() eq 'm 0.12,0.57 1.45,0.55');
    $polyline0->is_closed(1);
    ok($polyline0->as_string() eq 'm 0.12,0.57 1.45,0.55 z');
    $polyline0->is_closed(0);
    ok($polyline0->as_string() eq 'm 0.12,0.57 1.45,0.55');
    $polyline0->add_xy(3, 4);
    ok($polyline0->as_string() eq 'm 0.12,0.57 1.45,0.55 1.43,2.88');
    ok($polyline0->as_string(is_only => 0) eq 'm 0.12,0.57 1.45,0.55 1.43,2.88');
    ok($polyline0->as_string(is_first => 0) eq 'm 0.12,0.57 1.45,0.55 1.43,2.88');
    ok(($s = $polyline0->as_string(is_only => 0, is_first => 0)) eq 'M 0.12,0.57 l 1.45,0.55 1.43,2.88');
    $polyline0->is_closed(1);
    ok(($s = $polyline0->as_string(is_only => 0, is_first => 0)) eq 'M 0.12,0.57 l 1.45,0.55 1.43,2.88 L 0.12,0.57');
    $polyline0->is_closed(0);
}

{
    my $s;
    
    my $polyline0 = Geo::MapMaker::SVG::Polyline->new();
    $polyline0->add_xy(12, 34);
    $polyline0->add_xy(78, 56);
    $polyline0->add_xy(12, 34);
    $polyline0->add_xy(78, 56);
    ok(($s = $polyline0->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00');

    my $polyline1 = Geo::MapMaker::SVG::Polyline->new();
    $polyline1->add_xy(12, 34);
    $polyline1->add_xy(78, 56);
    $polyline1->add_xy(12, 34);
    $polyline1->add_xy(78, 56);
    $polyline1->translate(300, 300);
    ok(($s = $polyline1->as_string) eq 'm 312.00,334.00 66.00,22.00 -66.00,-22.00 66.00,22.00');

    my $path = Geo::MapMaker::SVG::Path->new($polyline0);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00');
    $polyline0->is_closed(1);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00 z');
    $polyline0->is_closed(0);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00');

    $path->add($polyline1);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00 M 312.00,334.00 l 66.00,22.00 -66.00,-22.00 66.00,22.00');
    $polyline0->is_closed(1);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00 L 12.00,34.00 M 312.00,334.00 l 66.00,22.00 -66.00,-22.00 66.00,22.00');
    $polyline1->is_closed(1);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00 L 12.00,34.00 M 312.00,334.00 l 66.00,22.00 -66.00,-22.00 66.00,22.00 L 312.00,334.00');
    $polyline0->is_closed(0);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00 M 312.00,334.00 l 66.00,22.00 -66.00,-22.00 66.00,22.00 L 312.00,334.00');
    $polyline1->is_closed(0);
    ok(($s = $path->as_string) eq 'm 12.00,34.00 66.00,22.00 -66.00,-22.00 66.00,22.00 M 312.00,334.00 l 66.00,22.00 -66.00,-22.00 66.00,22.00');
}
