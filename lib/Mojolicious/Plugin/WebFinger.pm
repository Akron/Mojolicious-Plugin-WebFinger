package Mojolicious::Plugin::WebFinger;
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::Util 'url_escape';
use Mojo::URL;

# This is a modern version of WebFinger
# without using LRDD

our $VERSION = 0.01;

# Todo:
# See https://github.com/evanp/webfinger

my $WK_PATH = '/.well-known/webfinger';

# Register Plugin
sub register {
  my ($plugin, $mojo, $param) = @_;

  $param ||= {};

  # Load parameter from Config file
  if (my $config_param = $mojo->config('HostMeta')) {
    $param = { %$config_param, %$param };
  };

  # Load HostMeta if not already loaded.
  # This automatically loads XRD,
  # Util::Endpoint and Util::Callback plugins.
  unless (exists $mojo->renderer->helpers->{hostmeta}) {
    $mojo->plugin('HostMeta');
  };

  # Check for 'prepare_webfinger' callback
  $mojo->callback(['prepare_webfinger'] => $param, -once);

  # Get seconds to expiration
  my $seconds = (60 * 60 * 24 * 10);
  if ($param->{expires} && $param->{expires} =~ /^\d+$/) {
    $seconds = delete $param->{expires};
  };

  # Establish WebFinger Route
  my $wfr = $mojo->routes->route($WK_PATH);

  # Establish endpoint
  $wfr->endpoint(
    webfinger => {
      query => [
	'resource' => '{uri}',
	'rel'      => '{rel?}',
	'format'   => '{format?}'
      ]
    });

  # Response to webfinger request
  $wfr->to(
    cb => sub {
      my $c = shift;

      # Get resource parameter
      my $res = $c->param('resource');

      # Delete invalid parameters
      if (!$res || $res eq '{uri}') {

	# Bad request - no resource defined
	return $c->render(status => 400);
      };

      # Set standard format
      unless ($c->stash('format') || $c->param('format')) {
	$c->stash(format => 'jrd');
      };

      # Normalize the resource
      my ($acct, $host, $nres) = _normalize_resource($c, $res);

      # Set host to local
      $host ||= $c->req->url->base->host || 'localhost';

      # Bad request - no resource defined
      return $c->render(status => 400) unless $nres;

      # Check for 'prepare_webfinger' callback
      if ($c->callback(prepare_webfinger => $nres)) {

	# The response body is already rendered
	return if $c->res->body;

	my $xrd =
	  _serve_webfinger($c, $acct, $nres, $res);

	# Seconds given
	if ($xrd && $seconds) {

	  # Set cache control
	  my $headers = $c->res->headers;
	  $headers->cache_control(
	    "public, max-age=$seconds"
	  );

	  # Set expires element
	  $xrd->expires( time + $seconds );

	  # Set expires header
	  $xrd->expires( $xrd->expires );
	};

	# Server xrd document
	return $c->render_xrd($xrd, $res);
      };

      # No valid xrd document is existing for this resource
      return $c->render_xrd(undef, $res);
    }
  );

  # Add Route to Hostmeta - exactly once
  $mojo->hook(
    prepare_hostmeta => sub {
      my ($c, $hostmeta) = @_;

      # Add JRD link
      $hostmeta->link(lrdd => {
	type     => 'application/jrd+json',
	template => $c->endpoint(
	  webfinger => {
	    '?' => undef
	  }
	)
      })->add(Title => 'Webfinger (JRD)');

      # Add XRD link
      $hostmeta->link(lrdd => {
	type     => 'application/xrd+xml',
	template => $c->endpoint(
	  webfinger => {
	    format => 'xrd',
	    '?' => undef
	  }
	)
      })->add(Title => 'Webfinger (XRD)');
    });

  # webfinger helper
  $mojo->helper(
    webfinger => \&_fetch_webfinger
  );
};


# Fetch webfinger resource
sub _fetch_webfinger {
  my $c = shift;

  my ($acct, $res, $nres, $host);

  # Request with host information
  if ($_[1] && !ref($_[1]) && index($_[1], '-') != 0) {
    $host = shift;
    $nres  = shift;
  }

  # Get host information from resource
  else {
    $res = shift;
    ($acct, $host, $nres) = _normalize_resource($c, $res);
  };

  # Get flags
  my %flag;
  while ($_[-1] && index($_[-1], '-') == 0) {
    $flag{ pop() } = 1;
  };

  # Optimize flags for known services
  if ($host && $host =~ /(?:gmail|yahoo|mozilla)\.(?:com|org|net)$/i) {
    $flag{-old} = 1 unless $flag{-modern};
  };

  # Get callback
  my $cb = $_[-1] && ref $_[-1] eq 'CODE' ? pop : undef;

  # Get header information for requests
  my $header = {};
  if ($_[0] && ref $_[0] && ref($_[0]) eq 'HASH') {
    $header = shift;
  };

  # Get relation information
  my $rel = shift;

  # If local, serve local
  if (!$host ||
	($host eq ($c->req->url->base->host || 'localhost'))) {
    my $xrd = _serve_webfinger($c, $acct, $nres, $res);
    return $cb->($xrd, Mojo::Headers->new) if $cb;
    return ($xrd, Mojo::Headers->new) if wantarray;
    return $xrd;
  };

  # Delete resource
  $nres =~ s/^acct://;

  my ($xrd, $headers) = $c->callback(
    fetch_webfinger => ($host, $nres, $header)
  );

  if ($xrd) {
    # Filter relations
    $xrd = $xrd->filter_rel( $rel ) if $rel;

    # Set headers to default
    $headers ||= Mojo::Headers->new if $cb || wantarray;

    # Return cached hostmeta document
    return $cb->( $xrd, $headers ) if $cb;
    return ( $xrd, $headers ) if wantarray;
    return $xrd;
  };

  # Not found
  unless ($host && $res) {
    return $cb ? $cb->() : undef;
  };

  # Set secure value
  my $secure;
  if (exists $flag{-secure} || exists $flag{-modern}) {
    $secure = 1;
  };

# Begin Blocking/Non-Blocking treatment

  unless (exists $flag{-old}) {
    my $path = '//' . $host . $WK_PATH . '?resource=' . url_escape $nres;
    $path = 'https:' . $path if $secure;

    ($xrd, $headers) = $c->get_xrd($path => $header);

    # Todo: support header expiration date
    if ($xrd && !$xrd->expired) {
      $xrd = $xrd->filter_rel($rel) if $rel;
      return ($xrd, $headers) if wantarray;
      return $xrd;
    };
  };

  # No further discovery
  return if exists $flag{-modern};

  # Hostmeta and lrdd
  $xrd = $c->hostmeta(
    $host,
    $header,
    ['lrdd'],
    ($secure ? '-secure' : undef)
  );

  return unless $xrd;

  my $lrdd = $xrd->link('lrdd');

  return unless $lrdd;

  my $template = $lrdd->attrs('template');

  # template not found
  return unless $template;

  # Interpolate template
  $lrdd = $c->endpoint($template => {
    uri => $nres,
    '?' => undef
  });

  ($xrd, $headers) = $c->get_xrd($lrdd => $header);

  return unless $xrd;

  $xrd = $xrd->filter_rel($rel) if $rel;

  return ($xrd, $headers) if wantarray;
  return $xrd;
};


# Serve webfinger
sub _serve_webfinger {
  my $c = shift;
  my ($acct, $nres, $res) = @_;

  # No resource given
  $res ||= $nres;

  # Create new XRD document
  my $xrd = $c->new_xrd;

  # Set Subject
  $xrd->subject($res);

  # Set Alias
  $xrd->alias($nres) if $res ne $nres;

  # Run hook
  $c->app->plugins->emit_hook(
    before_serving_webfinger => ($c, $xrd, $nres)
  );

  # Filter relations
  $xrd = $xrd->filter_rel($c->param('rel')) if $c->param('rel');

  # Return webfinger document
  return $xrd;
};


# Normalize resource
sub _normalize_resource {
  my ($c, $res) = @_;

  # Resource is qualified
  if (index($res, 'acct:') != 0 and $res =~ /^[^:]+:/) {

    return $res unless wantarray;

    # Check host
    my $url = Mojo::URL->new($res);

    # Get host information
    my $host = $url->host;

    # Return array
    return (undef, $host, $res) if wantarray;
  };

  # Delete scheme if exists
  $res =~ s/^acct://i;

  # Split user from domain
  my ($acct, $host) = split '@', lc $res;

  # Create norm writing
  my $norm = 'acct:' . $acct . '@';

  # Use request host if no host is given
  $norm .= ($host || $c->req->url->base->host || 'localhost');

  return ($acct, $host, $norm) if wantarray;
  return $norm;
};


1;


__END__

=pod

=head1 NAME

Mojolicious::Plugin::WebFinger - Serve and Retrieve WebFinger Documents


=head1 SYNOPSIS

  # Mojolicious
  $app->plugin('WebFinger');

  # Mojolicious::Lite
  plugin 'WebFinger';

  # Serves XRD or JRD from /.well-known/webfinger

  # Discover WebFinger resources the blocking ...
  print $c->webfinger('acct:bob@example.com')
          ->link('describedby')
          ->attrs('href');

  # ... or non-blocking way
  $c->webfinger('acct:bob@example.com' => sub {
    my ($xrd, $header) = @_;
    # ...
  });


=head1 DESCRIPTION

L<Mojolicious::Plugin::WebFinger> provides several functions for the
L<WebFinger Protocol|https://datatracker.ietf.org/doc/draft-ietf-appsawg-webfinger/>.
It supports C<.well-known/webfinger> discovery as well as HostMeta
and works with both XRD and JRD.


=head1 HELPERS

=head2 webfinger

  # In Controllers:
  my $xrd = $self->webfinger('acct:me@sojolicio.us');

  # Only secure discovery
  my $xrd = $self->webfinger('acct:me@sojolicio.us', -secure);

  # Use lrdd with host and resource description
  my $xrd = $self->webfinger('sojolicio.us' => 'http://sojolicio.us/me.html', -secure);

  # Use rel parameters
  my $xrd = $self->webfinger('acct:me@sojolicio.us' => ['describedBy'], -secure);

  # Use non-blocking
  $self->webfinger('acct:me@sojolicio.us' => [qw/describedBy author/] => sub {
    my $xrd = shift;
    ...
  });

  # Serve local WebFinger documents
  my $xrd = $self->webfinger('me');

Returns the WebFinger resource as a L<XML::Loy::XRD> document.
Accepts the WebFinger resource, an optional array reference
of relations, and an optional callback for non-blocking requests.
The appended flag indicates, how the discovery should be done.
C<-secure> indicates, that discovery over C<https> only is allowed.
C<-modern> indicates, that only C</.well-known/host-meta> is discovered.
C<-old> indicates, that only host-meta and lrdd discovery is used.


=head1 CALLBACKS

=head2 fetch_webfinger

  # Establish a callback
  $mojo->callback(
    fetch_webfinger=> sub {
      my ($c, $host, acct, $header) = @_;

      my $doc = $c->chi->get("webfinger-$host-$acct");
      return unless $doc;

      my $header = $c->chi->get("webfinger-$host-$acct-headers");

      # Return document
      return ($c->new_xrd($doc), Mojo::Headers->new->parse($header));
    }
  );

This callback is released before a WebFinger document
is retrieved from a foreign server. The parameters passed to the
callback include the current controller object, the host's
name and the resource name.

If a L<XML::Loy::XRD> document associated with the requested
host name is returned (and optionally a L<Mojo::Headers> object),
the retrieval will stop.

The callback can be established with the
L<callback|Mojolicious::Plugin::Util::Callback/callback>
helper or on registration.

This can be used for caching.


=head2 prepare_webfinger

  if ($c->callback(prepare_webfinger => sub {
    my ($c, $resource) = @_;
    if ($resource eq 'acct:akron@sojolicio.us') {
      $c->stash('profile' => 'http://sojolicio.us/user/akron');
      return 1;
    };
  })) {
    print 'The requested resource exists!';
  };

This callback is triggered before a webfinger document is served.
The requested resource is passed. A boolean value indicating the
validity of the resource is expected.
A rendered response in the callback will be respected and further
serving won't be processed.

The callback can be either set using the
L<callback helper|Mojolicious::Plugin::Util::Callback/callback>
or on registration.


=head1 HOOKS

=head2 before_serving_webfinger

  $mojo->hook(
    before_serving_webfinger => sub {
      my ($c, $res, $xrd) = @_;
      if ($c->stash('profile')) {
        $xrd->link(profile => { href => $c->stash('profile') } );
      };
    });

This hook is run before the requested WebFinger document is served.
The hook passes the current controller object,
the resource name and the L<XRD|XML::Loy::XRD> object.


=head1 ROUTES

The route C</.well-known/webfinger> is established as the
lrdd L<endpoint|Mojolicious::Plugin::Util::Endpoint>.
This plugin depends on this route,
and the C<resource> and C<rel> attributes. Although other
routes are possible for webfinger/lrdd in older drafts of
the specification, and different forms for the resource definition,
this is assumed to be a future-proof best practice.


=head1 DEPENDENCIES

L<Mojolicious> (best with SSL support),
L<Mojolicious::Plugin::Util::Endpoint>,
L<Mojolicious::Plugin::Util::Callback>,
L<Mojolicious::Plugin::HostMeta>.

=head1 AVAILABILITY

  https://github.com/Akron/Mojolicious-Plugin-WebFinger


=head1 COPYRIGHT AND LICENSE

Copyright (C) 2011-2013, L<Nils Diewald|http://nils-diewald.de/>.

This program is free software, you can redistribute it
and/or modify it under the same terms as Perl.

=cut
