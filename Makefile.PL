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

# LICENSE AND COPYRIGHT
# 
# Copyright (C) 2013-2014 eBay Software Foundation
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
