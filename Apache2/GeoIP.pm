package Apache2::GeoIP;

use strict;
use warnings;
use vars qw($VERSION);

$VERSION = '1.99';

1;

__END__

=head1 NAME

Apache2::GeoIP - Look up country by IP Address

=head1 IP ADDRESS TO COUNTRY DATABASES

Free monthly updates to the database are available from 

  http://www.maxmind.com/download/geoip/database/

This free database is similar to the database contained in IP::Country, as 
well as many paid databases. It uses ARIN, RIPE, APNIC, and LACNIC whois to 
obtain the IP->Country mappings.

For Win32 users, the F<GeoIP.dat> database file is expected
to reside in the F</Program Files/GeoIP/> directory.

If you require greater accuracy, MaxMind offers a Premium database on a paid 
subscription basis. 

=head1 MAILING LISTS AND CVS

A mailing list and cvs access for the GeoIP library are available 
from SourceForge; see http://sourceforge.net/projects/geoip/.

=head1 SEE ALSO

L<Apache2::Geo::IP> and L<Apache2::Geo::Mirror>.

=head1 AUTHOR

The look-up code for associating a country with an IP address 
is based on the GeoIP library and the Geo::IP Perl module, and is 
Copyright (c) 2002, T.J. Mather, tjmather@tjmather.com, New York, NY, 
USA. See http://www.maxmind.com/ for details. The mod_perl interface is 
Copyright (c) 2002, Randy Kobes <randy@theoryx5.uwinnipeg.ca>.

All rights reserved.  This package is free software; you can redistribute it
and/or modify it under the same terms as Perl itself.

=cut
