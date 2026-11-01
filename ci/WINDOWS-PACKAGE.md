# Windows Bootsnap source encoding

Framework sets Ruby's default internal encoding to ASCII-8BIT. Bootsnap
1.26.0's Prism workaround can transcode UTF-8 source under that setting and
raise `Encoding::UndefinedConversionError` before compilation.

The Windows package requires Bootsnap 1.26.1 or later, which includes
[Bootsnap #576](https://github.com/rails/bootsnap/pull/576). The released
implementation disables internal transcoding; no source patch is applied.

Verify runs `ci/verify-windows-bootsnap.rb` with the packaged Ruby before
packaging and after fresh MSI installation. The check compiles UTF-8 and
Latin-1 fixtures under four default internal encodings, then reads each
through the cache again. It asserts exact bytes, encoding and frozen-string
semantics. It prints the loaded Bootsnap and Ruby versions.

The existing console, payload, CLI and local/TCP database checks also run.
`ci/verify-windows-database-query.rb` asserts an actual SQL result through
packaged Ruby/pg. These checks do not establish Windows dependency closure;
Omnibus currently skips that health inspection on Windows.
