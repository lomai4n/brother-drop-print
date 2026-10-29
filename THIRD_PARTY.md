# Third-party code

The unmodified source files in vendor/brlaser are from
[Owl-Maintain/brlaser](https://github.com/Owl-Maintain/brlaser), pinned to
commit edf2770c4573973d5b90ce57ec407e675348c196 (6.2.8).

Copyright Peter De Wachter and brlaser contributors.
License: GPL-2.0-or-later. The license text is included in
vendor/brlaser/COPYING and the project LICENSE.

Only the user-space raster encoder is linked. No CUPS driver, kernel extension,
vendor binary, or Brother installation package is installed or redistributed.

The upstream DCP-1600 / DCP-1610W profile supplies the initial A4 geometry.
It is not a substitute for DCP-1618W hardware calibration.
