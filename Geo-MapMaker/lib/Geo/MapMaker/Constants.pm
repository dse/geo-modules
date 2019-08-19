package Geo::MapMaker::Constants;
use warnings;
use strict;

use constant FALSE => 0;
use constant TRUE  => 1;

use constant POINT_X => 0;
use constant POINT_Y => 1;
use constant POINT_X_ZONE => 2;
use constant POINT_Y_ZONE => 3;

use base qw(Exporter);
use Exporter;

our @EXPORT_OK = qw(FALSE
                    TRUE
                    POINT_X
                    POINT_Y
                    POINT_X_ZONE
                    POINT_Y_ZONE);

our %EXPORT_TAGS = (
    all => [qw(FALSE
               TRUE
               POINT_X
               POINT_Y
               POINT_X_ZONE
               POINT_Y_ZONE)]
);

1;
