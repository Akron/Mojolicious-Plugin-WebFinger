#!/usr/bin/env perl
use strict;
use warnings;

use lib '../lib';

use Test::More;
use Test::Mojo;
use Mojo::ByteStream 'b';
use Mojolicious::Lite;

my $t = Test::Mojo->new;
my $app = $t->app;
$app->plugin('WebFinger');
my $c = Mojolicious::Controller->new;
$c->app($app);

my $webfinger_host = 'webfing.er';
my $acct = 'acct:akron@webfing.er';

# Rewrite req-url
$c->req->url->base->parse('http://'.$webfinger_host);
$app->hook(
  before_dispatch => sub {
    for (shift->req->url->base) {
      $_->host($webfinger_host);
      $_->scheme('http');
    }
  });


is($c->hostmeta->link('lrdd')->attrs('template'),
   'http://'.$webfinger_host.'/.well-known/webfinger?resource={uri}',
   'Correct uri');

is ($c->endpoint(webfinger => { uri => $acct, '?' => undef }),
    'http://'.$webfinger_host.'/.well-known/webfinger?resource=' . b($acct)->url_escape,
    'Webfinger endpoint');

app->callback(
  prepare_webfinger =>
    sub {
      my ($c, $norm) = @_;
      return 1 if $norm eq $acct;
    });

$app->hook(
  before_serving_webfinger =>
    sub {
      my ($c, $xrd, $norm) = @_;

      if ($norm eq $acct) {
	$xrd->link('http://microformats.org/profile/hcard' => {
	  type => 'text/html',
	  href => 'http://sojolicio.us/akron.hcard'
	});
	$xrd->link('describedby' => {
	  type => 'application/rdf+xml',
	  href => 'http://sojolicio.us/akron.foaf'
	});
      }

      else {
	$xrd = undef;
      };
    });

my $wf = $c->webfinger($acct);

ok($wf, 'Webfinger');
is($wf->subject, $acct, 'Subject');

is($wf->link('http://microformats.org/profile/hcard')
     ->attrs('href'), 'http://sojolicio.us/akron.hcard',
   'Webfinger-hcard');
is($wf->link('http://microformats.org/profile/hcard')
     ->attrs('type'), 'text/html',
   'Webfinger-hcard-type');
is($wf->link('describedby')
     ->attrs('href'), 'http://sojolicio.us/akron.foaf',
   'Webfinger-described_by');
is($wf->link('describedby')
     ->attrs('type'), 'application/rdf+xml',
   'Webfinger-descrybed_by-type');

$t->get_ok('/.well-known/webfinger?resource='.b($acct)->url_escape . '&format=xml')
  ->status_is('200')
  ->content_type_is('application/xrd+xml')
  ->text_is('Subject' => $acct);

$t->get_ok('/.well-known/webfinger?resource=nothing&format=xml')
  ->status_is('404')
  ->content_type_is('application/xrd+xml')
  ->text_is(Subject => 'nothing');

$t->get_ok('/.well-known/webfinger?resource='.b($acct)->url_escape)
  ->status_is('200')
  ->content_type_is('application/jrd+json')
  ->json_has('/subject' => $acct);

$t->get_ok('/.well-known/webfinger?resource=nothing')
  ->status_is('404')
  ->content_type_is('application/jrd+json')
  ->json_has('/subject' => 'nothing');

$app->callback(
  prepare_webfinger => sub {
    my ($c, $acct) = @_;
    return 1 if lc $acct eq 'acct:akron@sojolicio.us';
  });

$app->hook(
  before_serving_webfinger => sub {
    my ($c, $xrd, $acct) = @_;
    if (lc $acct eq 'acct:akron@sojolicio.us') {
      $xrd->link(author => 'Nils Diewald');
    };
  });

$acct = 'akron@sojolicio.us';

$t->get_ok('/.well-known/webfinger?resource='.b($acct)->url_escape)
  ->status_is('200')
  ->content_type_is('application/jrd+json')
  ->json_has('/subject' => $acct);

my ($alias) = $c->webfinger('akron')->alias;
is($alias, 'acct:akron@webfing.er', 'Webfinger');

done_testing;
exit;
__END__