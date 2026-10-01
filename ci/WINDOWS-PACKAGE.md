# Complete Windows package validation

This fork-only branch combines the verified Nokogiri source cache with a
Bootsnap 1.26.0 source-encoding correction. It is separate from the proposed
macOS changes. No private application source is included.

Metasploit sets Ruby's default internal encoding to binary. On Ruby 3.4.9,
Bootsnap's Prism workaround reads Ruby source as UTF-8 but implicitly converts
it to that internal encoding. Non-ASCII source then raises an encoding error.
The correction explicitly disables internal transcoding while preserving UTF-8
source interpretation and Ruby encoding magic comments. The original behavior
is reproduced before the corrected upstream test suite runs on Windows and Linux.

The regression is prepared against rails/bootsnap commit
`384fe647c1273061173c2b4678b194ddc64de622`. It checks source bytes, string encoding
and frozen state on cache misses and hits, using UTF-8 and Latin-1 source under
four internal encodings. It runs in Bootsnap's existing suite. This is an original
candidate correction, not an accepted upstream backport. AI assistance was used.

The Windows recipe verifies the entire released Bootsnap source file's SHA-256
before applying the correction during the build. A dependency/source change
requires review rather than silently applying a patch to unknown code. The
normal MSI contains the correction; the fresh-runner runtime job does not patch
the installed files or load a workaround. It retains the original CLI, console,
managed PostgreSQL and TCP database checks.

The temporary recipe patch should be removed once a Bootsnap release containing
the correction is selected and the complete package passes the same checks.
See WINDOWS-SOURCE-CACHE.md for the independent source-download fix and retirement
condition. Signing and upstream release publication are outside this validation.
