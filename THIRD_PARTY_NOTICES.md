# Third-party notices

acmedb includes, or is derived from, the following works. Their licenses are reproduced below.

| Work | Where | License |
| --- | --- | --- |
| LMDB (Symas Corporation, OpenLDAP Foundation) | `vendor/lmdb/` | OpenLDAP Public License 2.8 (`vendor/lmdb/LICENSE`) |
| libmdbx 0.14.4 (Leonid Yuriev), with the local change listed in `vendor/libmdbx/PATCHES.md` | `vendor/libmdbx/` | Apache License 2.0 (`vendor/libmdbx/LICENSE`; its NOTICE below) |
| Unicode Character Database 16.0 (tables generated from it) | `src/text/unicode_tables.zig` | Unicode License v3 (below) |
| Snowball stemming algorithms (English "Porter2", Spanish), translated to Zig; the Snowball Spanish stop-word list | `src/text/stem_english.zig`, `src/text/stem_spanish.zig`, `src/text/stop_words.zig` | BSD 3-Clause (below) |
| Snowball test vocabularies (a sample) | `tests/text/snowball/` (tests only) | BSD 3-Clause (below) |
| openCypher Technology Compatibility Kit | `tests/tck/features/` (tests only) | Apache License 2.0 (`tests/tck/LICENSE`) |

The English stop words are Lucene's English stop set, a list of 33 common English words.

## libmdbx (Apache License 2.0)

acmedb's builds with the libmdbx engine contain libmdbx, compiled from
`vendor/libmdbx/mdbx.c` as modified by acmedb (`vendor/libmdbx/PATCHES.md`). The
attribution notice of its NOTICE file:

```text
libmdbx (aka MDBX) is an extremely fast, compact, powerful, embeddedable,
transactional key-value storage engine with open-source code.

Copyright 2015-2026 Леонид Юрьев aka Leonid Yuriev <leo@yuriev.ru>
SPDX-License-Identifier: Apache-2.0
For notes about the license change, credits and acknowledgments,
please refer to the COPYRIGHT file within libmdbx source.
```

## Snowball (BSD 3-Clause)

```text
Copyright (c) 2001, Dr Martin Porter
Copyright (c) 2004,2005, Richard Boulton
Copyright (c) 2013, Yoshiki Shibukawa
Copyright (c) 2006-2025, Olly Betts
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions
are met:

  1. Redistributions of source code must retain the above copyright notice,
     this list of conditions and the following disclaimer.
  2. Redistributions in binary form must reproduce the above copyright notice,
     this list of conditions and the following disclaimer in the documentation
     and/or other materials provided with the distribution.
  3. Neither the name of the Snowball project nor the names of its contributors
     may be used to endorse or promote products derived from this software
     without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Unicode License v3

```text
UNICODE LICENSE V3

COPYRIGHT AND PERMISSION NOTICE

Copyright © 1991-2026 Unicode, Inc.

NOTICE TO USER: Carefully read the following legal agreement. BY
DOWNLOADING, INSTALLING, COPYING OR OTHERWISE USING DATA FILES, AND/OR
SOFTWARE, YOU UNEQUIVOCALLY ACCEPT, AND AGREE TO BE BOUND BY, ALL OF THE
TERMS AND CONDITIONS OF THIS AGREEMENT. IF YOU DO NOT AGREE, DO NOT
DOWNLOAD, INSTALL, COPY, DISTRIBUTE OR USE THE DATA FILES OR SOFTWARE.

Permission is hereby granted, free of charge, to any person obtaining a
copy of data files and any associated documentation (the "Data Files") or
software and any associated documentation (the "Software") to deal in the
Data Files or Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, and/or sell
copies of the Data Files or Software, and to permit persons to whom the
Data Files or Software are furnished to do so, provided that either (a)
this copyright and permission notice appear with all copies of the Data
Files or Software, or (b) this copyright and permission notice appear in
associated Documentation.

THE DATA FILES AND SOFTWARE ARE PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT OF
THIRD PARTY RIGHTS.

IN NO EVENT SHALL THE COPYRIGHT HOLDER OR HOLDERS INCLUDED IN THIS NOTICE
BE LIABLE FOR ANY CLAIM, OR ANY SPECIAL INDIRECT OR CONSEQUENTIAL DAMAGES,
OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS,
WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THE DATA
FILES OR SOFTWARE.

Except as contained in this notice, the name of a copyright holder shall
not be used in advertising or otherwise to promote the sale, use or other
dealings in these Data Files or Software without prior written
authorization of the copyright holder.
```
