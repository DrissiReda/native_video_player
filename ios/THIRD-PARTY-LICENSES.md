# Third-party licenses — iOS AV1 software decode

This plugin's iOS target optionally links two third-party libraries, used
**only** by the software AV1 playback path (`ios/Classes/AV1/`). The
pre-existing AVPlayer path links nothing new.

## FFmpeg 7.1.1 (LGPL-2.1-or-later)

Libraries used: libavformat, libavcodec, libavutil, libswscale,
libswresample. Built with `--disable-gpl --disable-nonfree`; decoders
limited to libdav1d (AV1), AAC and Opus; demuxers limited to mov and
matroska; no network protocols (bytes are fed by the app through its own
HTTP proxy via a custom AVIOContext).

- Upstream: https://ffmpeg.org / https://github.com/FFmpeg/FFmpeg
- Exact source: tag `n7.1.1` (release 7.1.1)
- License: GNU Lesser General Public License v2.1 or later.
  Full text: https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html
  (also shipped in the FFmpeg source tree as COPYING.LGPLv2.1)
- Compliance: the libraries are linked **statically** into the app. Per
  LGPL-2.1 §6(a), the Corresponding Source (the exact FFmpeg tree plus the
  `build-ffmpeg.sh` configure invocations used) and the object files needed
  to relink the app are available on request; the build scripts that produce
  these XCFrameworks are kept alongside the plugin source.

## dav1d 1.5.4 (BSD-2-Clause)

The AV1 decoder used through FFmpeg's `libdav1d` wrapper.

- Upstream: https://code.videolan.org/videolan/dav1d
- Exact source: tag `1.5.4`
- License: BSD 2-Clause ("Simplified BSD"). Full text:

```
Copyright © 2018-2025, VideoLAN and dav1d authors
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
```
