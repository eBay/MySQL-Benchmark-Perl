use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME               => 'MySQL::Benchmark',
    AUTHOR             => q{Luis Motta Campos <lmc@cpan.org>},
    VERSION_FROM       => 'lib/MySQL/Benchmark.pm',
    ABSTRACT_FROM      => 'lib/MySQL/Benchmark.pm',
    LICENSE            => 'GPL_2',
    PL_FILES           => {},
    EXE_FILES          => ['scripts/mysql-benchmark'],
    MIN_PERL_VERSION   => 5.006,
    CONFIGURE_REQUIRES => { 'ExtUtils::MakeMaker' => 0, },
    BUILD_REQUIRES     => { 'Test::More' => 0, },
    PREREQ_PM          => {
        'DBI'        => 0,
        'DBD::mysql' => 0,
        'YAML::XS'   => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES    => 'mysql-benchmark-*' },
);
