package Apache2::Geo::Mirror;

use strict;
use warnings;
use vars qw($VERSION $GM $ROBOTS_TXT $DEFAULT $FRESH);

$VERSION = '1.99';

use Apache2::RequestRec ();
use Apache2::Const -compile => qw(REMOTE_HOST REDIRECT OK);
use Apache2::RequestUtil ();
use APR::Table ();
use Apache2::Log ();
use Apache2::Connection ();
use Apache2::URI ();
use APR::URI ();
use Apache2::RequestIO ();

use Geo::Mirror;

@Apache2::Geo::Mirror::ISA = qw(Apache2::RequestRec);

sub new {
  my ($class, $r) = @_;
  
  my $loc = $r->location;
  init($r, $loc) unless (exists $GM->{$loc});
  
  return bless { r => $r,
                 gm => $GM->{$loc},
                 robots_txt => $ROBOTS_TXT->{$loc},
                 default => $DEFAULT->{$loc},
                 fresh => $FRESH->{$loc},
               }, $class;
}

sub init {
  my ($r, $loc) = @_;

  my $file = $r->dir_config->get('GeoIPDBFile');
  if ($file)  {
    unless ( -e $file) {
      $r->log->error("Cannot find GeoIP database file '$file'");
      die;
    }
  }

  my $mirror_file = $r->dir_config->get('GeoIPMirror');
  unless (defined $mirror_file) {
    $r->log->error("Must specify location of the mirror file");
     die;
  }
  unless (-e $mirror_file) {
    $r->log->error("Cannot find the mirror file '$mirror_file'");
    die;
  }

  my $gm = Geo::Mirror->new(mirror_file => $mirror_file,
                            database_file => $file,
                            );
  unless (defined $gm) {
    $r->log->error("Cannot create Geo::Mirror object");
    die;
  }
  $GM->{$loc} = $gm;
  
  my $robot = $r->dir_config->get('GeoIPRobot') || '';
  my $robots_txt;
  if (defined $robot) {
    if (lc $robot eq 'default') {
      $robots_txt = <<'END';
User-agent: *
Disallow: /
END
    }
    else {
      my $fh;
      unless (open($fh, '<', $robot) {
        $r->log->error("Cannot open GeoIP robots file '$robot': $!");
        die;
      }
      my @lines = <$fh>;
      close($fh);
      $robots_txt = join "\n", @lines;
    }
  }    
  $ROBOTS_TXT->{$loc} = $robots_txt;
  
  $DEFAULT->{$loc} = $r->dir_config->get('GeoIPDefault') || 'us';

  $FRESH->{$loc} = $r->dir_config->get('GeoIPFresh') || 0;
}

sub find_mirror_by_country {
  my ($self, $country) = @_;
  my $gm = $self->{gm};
  my $default = $self->{default};
  my $fresh = $self->{fresh};
  my $url;
  if ($country) {
    $url = $gm->find_mirror_by_country($country, $fresh) || $default;
  }
  else {
    my $addr = $self->connection->remote_ip;
    my $url = $gm->find_mirror_by_addr($addr, $fresh) || $default;
  }
  return $url;
}

sub find_mirror_by_addr {
  my $self = shift;
  my $addr = shift || $self->connection->remote_ip;
  
  my $gm = $self->{gm};
  my $url = $gm->find_mirror_by_addr($addr, $self->{fresh}) || $self->{default};
  return $url;
}

sub auto_redirect : method {
  my $class = shift;
  my $r = __PACKAGE__->new(shift);
  my $uri = $r->parsed_uri();
  my $robots_txt = $self->{robots_txt} || '';
  if ($uri =~ /robots\.txt$/ and defined $robots_txt) {
    $r->content_type('text/plain');
    $r->print("$robots_txt\n");
    return Apache2::Const::OK;
  }
  my $ReIpNum = qr{([01]?\d\d?|2[0-4]\d|25[0-5])};
  my $ReIpAddr = qr{^$ReIpNum\.$ReIpNum\.$ReIpNum\.$ReIpNum$};
  my $host =  $r->headers_in->get('X-Forwarded-For') || 
    $r->connection->remote_ip;
  if ($host =~ /,/) {
      my @a = split /\s*,\s*/, $host;
      for my $i (0 .. $#a) {
          if ($a[$i] =~ /$ReIpAddr/ and $a[$i] ne '127.0.0.1') {
              $host = $a[$i];
              last;
          }
      }
      $host = '127.0.0.1' if $host =~ /,/;
  }
  my $chosen = $r->find_mirror_by_addr($host);
  my ($scheme, $name, $path) = $chosen =~ m!^(http|ftp)://([^/]+/?)(.*)!;
  $uri->scheme($scheme);
  $uri->hostname($name);
  my $location = $r->location;
  (my $uri_path = $uri->path) =~ s!$location!!;
  $uri->path($path . $uri_path);
  my $where = $uri->unparse;
  $where =~ s!:\d+!!;
  #  $r->log->warn("$where $host");
  $r->headers_out->set(Location => $where);
  return Apache2::Const::REDIRECT;
}
  
1;


=head1 NAME

Apache2::Geo::Mirror - Find closest Mirror

=head1 SYNOPSIS

 # in httpd.conf
 # PerlModule Apache2::HelloMirror
 #<Location /mirror>
 #   SetHandler perl-script
 #   PerlResponseHandler Apache2::HelloMirror
 #   PerlSetVar GeoIPDBFile "/usr/local/share/GeoIP/GeoIP.dat"
 #   PerlSetVar GeoIPMirror "/usr/local/share/data/mirror.txt"
 #   PerlSetVar GeoIPDefault "http://www.cpan.org/"
 #</Location>
 
 # file Apache2::HelloMirror
 
 use Apache2::Geo::Mirror;
 use strict;
 
 use Apache2::Const -compile => 'OK';
 
 sub handler {
   my $r = Apache2::Geo::Mirror->new(shift);
   $r->content_type('text/plain');
   my $mirror = $r->find_mirror_by_addr();
   $r->print($mirror);
  
   Apache2::Const::OK;
 }
 1;
 

=head1 DESCRIPTION

This module provides a mod_perl (version 2) interface to the
I<Geo::Mirror> module, which
finds the closest mirror for an IP address.  It uses I<Geo::IP>
to identify the country that the IP address originated from.  If
the country is not represented in the mirror list, then it finds the
closest country using a latitude/longitude table.

=head1 CONFIGURATION

This module subclasses I<Apache2::RequestRec>, and can be used as follows
in an Apache module.
 
  # file Apache2::HelloMirror
  
  use Apache2::Geo::Mirror;
  use strict;
 
  sub handler {
     my $r = Apache2::Geo::Mirror->new(shift);
     # continue along
  }
 
The C<PerlSetVar> directives in F<httpd.conf> are as follows:
 
  <Location /mirror>
    PerlSetVar GeoIPDBFile "/usr/local/share/geoip/GeoIP.dat"
    PerlSetVar GeoIPMirror "/usr/local/share/data/mirror.txt"
    PerlSetVar GeoIPDefault "http://www.cpan.org/"
    PerlSetVar GeoIPFresh 2
    # other directives
  </Location>
 
The directives available are

=over 4

=item PerlSetVar GeoIPDBFile "/path/to/GeoIP.dat"

This specifies the location of the F<GeoIP.dat> file.
If not given, it defaults to the location specified
upon installing the module.

=item PerlSetVar GeoIPFresh 5

This specifies a minimum freshness that the chosen mirror must satisfy.
If this is not specified, a value of 0 is assumed.

=item PerlSetVar GeoIPMirror "/path/to/mirror.txt"

This specifies the location of a file containing
the list of available mirrors. No default location for this file is assumed.
This file contains a list of mirror sites and the corresponding 
country code in the format

  http://some.server.com/some/path         us
  ftp://some.other.server.fr/somewhere     fr

An optional third field may be specified, such as

  ftp://some.other.server.ca/somewhere    ca  3

where the third number indicates the freshness of the mirror. A default
freshness of 0 is assumed when none is specified. When choosing a mirror,
if the I<GeoIPFresh> directive is specified, only those mirrors
with a freshness equal to or above this value may be chosen.

=item PerlSetVar GeoIPDefault "http://some.where.org/"

This specifies the default url to be used if no nearby mirror is found.

=back

=head1 METHODS

The available methods are as follows.

=over 4

=item $mirror = $r->find_mirror_by_country( [$country] );

Finds the nearest mirror by country code. If I<$country> is not
given, this defaults to the country as specified by a lookup
of C<$r-E<gt>connection-E<gt>remote_ip>.

=item $mirror = $r->find_mirror_by_addr( [$ipaddr] );

Finds the nearest mirror by IP address. If I<$ipaddr> is not
given, this defaults C<$r-E<gt>connection-E<gt>remote_ip>.

=back

=head1 AUTOMATIC REDIRECTION

If I<Apache2::Geo::Mirror> is used as

  PerlModule Apache2::Geo::Mirror
  <Location /CPAN>
    PerlSetVar GeoIPDBFile "/usr/local/share/geoip/GeoIP.dat"
    PerlSetVar GeoIPMirror "/usr/local/share/data/mirror.txt"
    PerlSetVar GeoIPDefault "http://www.cpan.org/"
    PerlResponseHandler Apache2::Geo::Mirror->auto_redirect
  </Location>

then an automatic redirection is made. Within this, the directive

    PerlSetVar GeoIPRobot "/path/to/a/robots.txt"

can be used to handle robots that honor a I<robots.txt> file. This can be
a physical file that exists on the system or, if it is set to the special
value I<default>, the string

    User-agent: *
    Disallow: /

will be used, which disallows robot access to anything.

=head1 VERSION

0.10

=head1 SEE ALSO

L<Geo::IP>, L<Geo::Mirror>, and L<Apache2::RequestRec>.

=head1 AUTHOR

The look-up code for associating a country with an IP address 
is based on the GeoIP library and the Geo::IP Perl module, and is 
Copyright (c) 2002, T.J. Mather, E<lt> tjmather@tjmather.com E<gt>, New York, NY, 
USA. See http://www.maxmind.com/ for details. The mod_perl interface is 
Copyright (c) 2002, 2009 Randy Kobes E<lt> randy.kobes@gmail.com E<gt>.

All rights reserved.  This package is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
