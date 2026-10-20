# Snowball test vocabularies

Every seventh line of the test vocabularies of the Snowball project
(https://github.com/snowballstem/snowball-data, `english/` and `spanish/`), each line a
word and its stem as the reference implementation gives it. BSD license: Copyright (c)
2001 Dr Martin Porter, 2004-2025 Richard Boulton, Yoshiki Shibukawa, Olly Betts; all
rights reserved.

`tests/text/stemmer_test.zig` stems every word and expects the same stem. To check the
whole vocabularies (the stemmers matched all 42,649 English and 28,378 Spanish words
when they were written), replace these files with `paste -d' ' voc.txt output.txt` of
each language and run `zig build test`.
