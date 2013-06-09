#!/usr/bin/env perl
use 5.010001;
use strict;
use warnings;
use ExtUtils::MakeMaker;

# First upload new Mojolicious::Plugin::Util::Endpoint

WriteMakefile(
  NAME         => 'Mojolicious::Plugin::WebFinger',
  AUTHOR       => 'Nils Diewald',
  ABSTRACT     => 'Serve and Retrieve WebFinger Documents',
  VERSION_FROM => 'lib/Mojolicious/Plugin/WebFinger.pm',
  BUILD_REQUIRES => {
    'Test::More' => 0
  },
  PREREQ_PM => {
    'Mojolicious' => 3.94,
    'XML::Loy' => 0.18,
    'Mojolicious::Plugin::XRD' => 0.06,
    'Mojolicious::Plugin::HostMeta' => 0.09,
    'Mojolicious::Plugin::Util::Endpoint' => 0.15,
    'Mojolicious::Plugin::Util::Callback' => 0.03
  },
  LICENSE      => 'perl',
  META_MERGE   => {
    requires  => { perl => '5.010001' },
    resources => {
      license     => 'http://www.opensource.org/licenses/artistic-license-2.0',
      repository  => 'https://github.com/Akron/Mojolicious-Plugin-WebFinger'
    }
  },
  MIN_PERL_VERSION => '5.010001',
  test => {TESTS => 't/*.t'}
);
