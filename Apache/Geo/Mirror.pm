package Apache::Geo::Mirror;

use strict;
use warnings;
use vars qw($VERSION $GIP %lat %lon $MIRROR $NEARBY_CACHE $DEFAULT);
use Apache::GeoIP;
use POSIX;

$VERSION = '1.63';

my $GEOIP_DBFILE;

use Apache;
use Apache::Constants qw(REMOTE_HOST REDIRECT);
use Apache::URI;

@Apache::Geo::Mirror::ISA = qw(Apache);

use constant PI => 3.14159265358979323846;
use constant GEOIP_STANDARD => 0;
use constant GEOIP_MEMORY_CACHE => 1;
use constant GEOIP_CHECK_CACHE => 2;
use constant GEOIP_INDEX_CACHE => 4;

unless (%lat and %lon) {
  while (<DATA>) {
    my ($country, $lat, $lon) = split(':');
    
    $lat{$country} = $lat;
    $lon{$country} = $lon;
  }
}

sub new {
  my ($class, $r) = @_;
  
  my $loc = $r->location;
  init($r, $loc) unless (exists $GIP->{$loc} and exists $MIRROR->{$loc});
  
  return bless { r => $r,
                 default => $DEFAULT->{$loc},
                 mirror => $MIRROR->{$loc},
                 gip => $GIP->{$loc},
                 nearby_cache => $NEARBY_CACHE->{$loc}, 
               }, $class;
}

sub init {
  my ($r, $loc) = @_;
  my $file = $r->dir_config('GeoIPDBFile') || $GEOIP_DBFILE;
  if ($file) {
    unless (-e $file) {
      $r->warn("Cannot find GeoIP database file '$file'");
      die;
    }
  }
  else {
    $r->warn("Must specify GeoIP database file");
    die;
  }
  
  my $flag = $r->dir_config('GeoIPFlag') || '';
  if ($flag) {
    unless ($flag =~ /^(STANDARD|MEMORY_CACHE|CHECK_CACHE|INDEX_CACHE)$/i) {
      $r->warn("GeoIP flag '$flag' not understood");
      die;
    }
  }
 FLAG: {
    ($flag && $flag eq 'MEMORY_CACHE') && do {
      $flag = GEOIP_MEMORY_CACHE;
      last FLAG;
    };
    ($flag && $flag eq 'CHECK_CACHE') && do {
      $flag = GEOIP_CHECK_CACHE;
      last FLAG;
    };
    ($flag && $flag eq 'INDEX_CACHE') && do {
      $flag = GEOIP_INDEX_CACHE;
      last FLAG;
    };
    $flag = GEOIP_STANDARD;
  }
  
  unless ($GIP->{$loc} = Apache::GeoIP->open($file, $flag)) {
    $r->warn("Couldn't make GeoIP object");
    die;
  }
  
  my $mirror_file = $r->dir_config('GeoIPMirror');
  my $mirror_data;
  if ($mirror_file and -f $mirror_file) {
    open (MIRROR, $mirror_file) or die "Cannot open $mirror_file: $!";
    while(<MIRROR>) {
      my ($url, $country) = split(' ');
      push @{$mirror_data->{$country}}, $url;
    }
    close MIRROR;
    $MIRROR->{$loc} = $mirror_data;
  }
  else {
    $r->warn("Please specify a mirror file");
    die;
  }
  $NEARBY_CACHE->{$loc} = {};
  $DEFAULT->{$loc} = $r->dir_config('GeoIPDefault') || 'us';
}

sub _random_mirror {
  my ($self, $country) = @_;
  my $mirror = $self->{mirror};
  my $num = scalar(@{$mirror->{$country}});
  
  return unless $num;

  return $mirror->{$country}->[int(rand()*$num)];
}

sub find_mirror_by_country {
  my ($self, $country) = @_;
  my $default = $self->{default};
  my $gip = $self->{gip};
  my $mirror = $self->{mirror};
  my $nearby_cache = $self->{default_cache};

  unless ($country) {
      my $addr = shift || $self->connection->remote_ip;
      $country = lc($gip->_country_code_by_addr($addr)) || $default;
  }
  if (exists $mirror->{$country}) {
      return $self->_random_mirror($country);
  } 
  elsif (exists $nearby_cache->{$country}) {
      return $self->_random_mirror($nearby_cache->{$country});
  } 
  else {
      my $new_country = $self->_find_nearby_country($country);
      $NEARBY_CACHE->{$country} = $new_country;
      return $self->_random_mirror($new_country);
  }
}

sub find_mirror_by_addr {
  my $self = shift;
  my $addr = shift || $self->connection->remote_ip;
  my $default = $self->{default};
  my $gip = $self->{gip};
  
  # default to $default if country not found
  my $country = lc($gip->_country_code_by_addr($addr)) || $default;
  $country = $default if ($country eq '--' or $country eq '');
  return $self->find_mirror_by_country($country);
}

sub find_mirror_by_name {
  my $self = shift;
  my $name = shift || $self->get_remote_host(REMOTE_HOST);
  my $default = $self->{default};
  my $gip = $self->{gip};
  
  # default to $default if country not found
  my $country = lc($gip->_country_code_by_name($name)) || $default;
  $country = $default if ($country eq '--' or $country eq '');
  return $self->find_mirror_by_country($country);
}

sub _find_nearby_country {
  my ($self, $country) = @_;
  my $mirror = $self->{mirror};
  
  my @candidate_countries = keys %{$mirror};
  my $closest_country;
  my $closest_distance = 1_000_000_000;
  
  for (@candidate_countries) {
    next unless (defined $lat{$_} and defined $lon{$_});
    my $distance = $self->_calculate_distance($country, $_);
    if ($distance < $closest_distance) {
      $closest_country = $_;
      $closest_distance = $distance;
    }
  }
  return $closest_country;
}

sub auto_redirect : method {
  my $class = shift;
  my $r = __PACKAGE__->new(shift);
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
  my $uri = Apache::URI->parse($r, $chosen);
  $uri->path($uri->path . $r->path_info);
  #    my $where = $uri->unparse;
  #  $r->warn("$where $host");
  $r->headers_out->set(Location => $uri->unparse);
  return REDIRECT;
}
  
sub _calculate_distance {
  my ($self, $country1, $country2) = @_;
  
  my $lat_1 = $lat{$country1};
  my $lat_2 = $lat{$country2};
  my $lon_1 = $lon{$country1};
  my $lon_2 = $lon{$country2};
  
  # Convert all the degrees to radians
  $lat_1 *= PI/180;
  $lon_1 *= PI/180;
  $lat_2 *= PI/180;
  $lon_2 *= PI/180;
  
  # Find the deltas
  my $delta_lat = $lat_2 - $lat_1;
  my $delta_lon = $lon_2 - $lon_1;
  
  # Find the Great Circle distance
  my $temp = sin($delta_lat/2.0)**2 + 
    cos($lat_1) * cos($lat_2) * sin($delta_lon/2.0)**2;
  return atan2(sqrt($temp),sqrt(1-$temp));
}

1;

__DATA__
af:33:65
al:41:20
dz:28:3
as:-14:-170
ad:42:1
ao:-12:18
ai:18:-63
aq:-90:0
ag:17:-61
ar:-34:-64
am:40:45
aw:12:-69
au:-27:133
at:47:13
az:40:47
bs:24:-76
bh:26:50
bd:24:90
bb:13:-59
by:53:28
be:50:4
bz:17:-88
bj:9:2
bm:32:-64
bt:27:90
bo:-17:-65
ba:44:18
bw:-22:24
bv:-54:3
br:-10:-55
io:-6:71
vg:18:-64
bg:43:25
bf:13:-2
bi:-3:30
kh:13:105
cm:6:12
ca:60:-95
cv:16:-24
ky:19:-80
cf:7:21
td:15:19
cl:-30:-71
cn:35:105
cx:-10:105
cc:-12:96
co:4:-72
km:-12:44
cd:0:25
cg:-1:15
ck:-21:-159
cr:10:-84
ci:8:-5
hr:45:15
cu:21:-80
cy:35:33
cz:49:15
dk:56:10
dj:11:43
dm:15:-61
do:19:-70
ec:-2:-77
eg:27:30
sv:13:-88
gq:2:10
er:15:39
ee:59:26
et:8:38
fk:-51:-59
fo:62:-7
fj:-18:175
fi:64:26
fr:46:2
gf:4:-53
pf:-15:-140
ga:-1:11
gm:13:-16
ge:42:43
de:51:9
eu:48:10
gh:8:-2
gi:36:-5
gr:39:22
gl:72:-40
gd:12:-61
gp:16:-61
gu:13:144
gt:15:-90
gn:11:-10
gw:12:-15
gy:5:-59
ht:19:-72
hm:-53:72
va:41:12
hn:15:-86
hk:22:114
hu:47:20
is:65:-18
in:20:77
id:-5:120
ir:32:53
iq:33:44
ie:53:-8
il:31:34
it:42:12
jm:18:-77
sj:71:-8
jp:36:138
jo:31:36
ke:1:38
ki:1:173
kp:40:127
kr:37:127
kw:29:45
kg:41:75
lv:57:25
lb:33:35
ls:-29:28
lr:6:-9
ly:25:17
li:47:9
lt:56:24
lu:49:6
mo:22:113
mk:41:22
mg:-20:47
mw:-13:34
my:2:112
mv:3:73
ml:17:-4
mt:35:14
mh:9:168
mq:14:-61
mr:20:-12
mu:-20:57
yt:-12:45
mx:23:-102
fm:6:158
mc:43:7
mn:46:105
ms:16:-62
ma:32:-5
mz:-18:35
na:-22:17
nr:-0:166
np:28:84
nl:52:5
an:12:-68
nc:-21:165
nz:-41:174
ni:13:-85
ne:16:8
ng:10:8
nu:-19:-169
nf:-29:167
mp:15:145
no:62:10
om:21:57
pk:30:70
pw:7:134
pa:9:-80
pg:-6:147
py:-23:-58
pe:-10:-76
ph:13:122
pn:-25:-130
pl:52:20
pt:39:-8
pr:18:-66
qa:25:51
re:-21:55
ro:46:25
ru:60:100
rw:-2:30
sh:-15:-5
kn:17:-62
lc:13:-60
pm:46:-56
vc:13:-61
ws:-13:-172
sm:43:12
st:1:7
sa:25:45
sn:14:-14
sc:-4:55
sl:8:-11
sg:1:103
sk:48:19
si:46:15
sb:-8:159
so:10:49
za:-29:24
gs:-54:-37
es:40:-4
lk:7:81
sd:15:30
sr:4:-56
sj:78:20
sz:-26:31
se:62:15
ch:47:8
sy:35:38
tj:39:71
tz:-6:35
th:15:100
tg:8:1
tk:-9:-172
to:-20:-175
tt:11:-61
tn:34:9
tr:39:35
tm:40:60
tc:21:-71
tv:-8:178
ug:1:32
ua:49:32
ae:24:54
gb:54:-2
us:38:-97
uy:-33:-56
uz:41:64
vu:-16:167
ve:8:-66
vn:16:106
vi:18:-64
wf:-13:-176
eh:24:-13
ye:15:48
yu:44:21
zm:-15:30
zw:-20:30
tw:23:121
__END__

=head1 NAME

Apache::Geo::Mirror - Find closest Mirror

=head1 SYNOPSIS

 # in httpd.conf
 # PerlModule Apache::HelloMirror
 #<Location /mirror>
 #   SetHandler perl-script
 #   PerlHandler Apache::HelloMirror
 #   PerlSetVar GeoIPDBFile "/usr/local/share/geoip/GeoIP.dat"
 #   PerlSetVar GeoIPFlag Standard
 #   PerlSetVar GeoIPMirror "/usr/local/share/data/mirror.txt"
 #   PerlSetVar GeoIPDefault it
 #</Location>
 
 # file Apache::HelloMirror
 
 use Apache::Geo::Mirror;
 use strict;
  
 use Apache::Constants qw(OK);
 
 sub handler {
   my $r = Apache::Geo::Mirror->new(shift);
   $r->content_type('text/plain');
   my $mirror = $r->find_mirror_by_addr();
   $r->print($mirror);
  
   OK;
 }
 1;

=head1 DESCRIPTION

This module provides a mod_perl (version 1) interface to the
I<Geo::Mirror> module, which
finds the closest mirror for an IP address.  It uses I<Geo::IP>
to identify the country that the IP address originated from.  If
the country is not represented in the mirror list, then it finds the
closest country using a latitude/longitude table.

=head1 CONFIGURATION

This module subclasses I<Apache>, and can be used as follows
in an Apache module.
 
  # file Apache::HelloMirror
  
  use Apache::Geo::Mirror;
  use strict;
 
  sub handler {
     my $r = Apache::Geo::Mirror->new(shift);
     # continue along
  }
 
The directives in F<httpd.conf> are as follows:
 
  <Location /mirror>
    PerlSetVar GeoIPDBFile "/usr/local/share/GeoIP/GeoIP.dat"
    PerlSetVar GeoIPFlag Standard
    PerlSetVar GeoIPMirror "/usr/local/share/data/mirror.txt"
    PerlSetVar GeoIPDefault us
    # other directives
  </Location>
 
The C<PerlSetVar> directives available are

=over 4

=item PerlSetVar GeoIPDBFile "/path/to/GeoIP.dat"

This specifies the location of the F<GeoIP.dat> file.
If not given, it defaults to the location specified
upon installing the module.

=item PerlSetVar GeoIPFlag Standard

This can be set to I<STANDARD>, or for faster performance
but at a cost of using more memory, I<MEMORY_CACHE>.
When using memory
cache you can force a reload if the file is updated by 
using I<CHECK_CACHE>. The I<INDEX_CACHE> flag caches
the most frequently accessed portion of the database.
If not specified, I<STANDARD> is used.

=item PerlSetVar GeoIPMirror "/path/to/mirror.txt"

This specifies the location of a file containing
the list of available mirrors. This file contains a list
of mirror sites and the corresponding country code in the format

  http://some.server.com/some/path         us
  ftp://some.other.server.fr/somewhere     fr

No default location for this file is assumed.

=item PerlSetVar GeoIPDefault country

This specifies the country code to be used if a wanted
country is not available in the mirror file. This
defaults to I<us>.

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

=item $mirror = $r->find_mirror_by_name( [$ipname] );

Finds the nearest mirror by country code. If I<$ipname> is not
given, this defaults to C<$r-E<gt>get_remote_host(Apache::REMOTE_HOST)>.

=back

=head1 AUTOMATIC REDIRECTION

If I<Apache::Geo::Mirror> is used as

  PerlModule Apache::Geo::Mirror
  <Location /CPAN>
    PerlSetVar GeoIPDBFile "/usr/local/share/geoip/GeoIP.dat"
    PerlSetVar GeoIPFlag Standard
    PerlSetVar GeoIPMirror "/usr/local/share/data/mirror.txt"
    PerlSetVar GeoIPDefault us
    PerlHandler Apache::Geo::Mirror->auto_redirect
  </Location>

then an automatic redirection is made.

=head1 VERSION

0.10

=head1 SEE ALSO

L<Geo::IP>, L<Geo::Mirror>, and L<Apache>.

=head1 AUTHOR

The look-up code for associating a country with an IP address 
is based on the GeoIP library and the Geo::IP Perl module, and is 
Copyright (c) 2002, T.J. Mather, tjmather@tjmather.com, New York, NY, 
USA. See http://www.maxmind.com/ for details. The mod_perl interface is 
Copyright (c) 2002, Randy Kobes <randy@theoryx5.uwinnipeg.ca>.

All rights reserved.  This package is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
