package TestGeoIP::mirror;
use Apache::Geo::Mirror;
use strict;
use warnings FATAL => 'all';

use Apache::Constants qw(OK);

sub handler {
  my $r = Apache::Geo::Mirror->new(shift);
  $r->content_type('text/plain');
  $r->send_http_header;
  my $ip = $r->args;
  my $mirror;
  if ($ip =~ /^\d/) {
    $mirror = $r->find_mirror_by_addr($ip);
  }
  else {
    $mirror = $r->find_mirror_by_country($ip);

  }
  
  $r->print($mirror);
  
  OK;
}
1;

__DATA__
<NoAutoConfig>
<Location /cpan>
  SetHandler perl-script
  PerlHandler TestGeoIP::mirror
  PerlSetVar GeoIPMirror "@ServerRoot@/conf/cpan_mirror.txt"
  PerlSetVar GeoIPFlag MEMORY_CACHE
</Location>

<Location /apache>
  SetHandler perl-script
  PerlHandler TestGeoIP::mirror
  PerlSetVar GeoIPMirror "@ServerRoot@/conf/apache_mirror.txt"
  PerlSetVar GeoIPDefault kr
</Location>

PerlModule Apache::Geo::Mirror
<Location /mirror>
  SetHandler perl-script
  PerlHandler Apache::Geo::Mirror->auto_redirect
  PerlSetvar GeoIPMirror "@ServerRoot@/conf/auto_mirror.txt"
  PerlSetVar GeoIPDefault jp
</Location>
</NoAutoConfig>

