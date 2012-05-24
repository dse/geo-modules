use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Geo::MapMaker',
    AUTHOR              => 'Darren Embry <dse@webonastick.com>',
    VERSION_FROM        => 'lib/Geo/MapMaker.pm',
#    ABSTRACT_FROM       => 'lib/Geo/MapMaker.pm',
#    PL_FILES            => {},
    EXE_FILES           => [ "bin/mapmaker" ],
#    PREREQ_PM => {
#        'Test::More' => 0,
#    },
#    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
#    clean               => { FILES => 'Geo-MapMaker-*' },
);
