# Windows Bootsnap source encoding

Framework sets Ruby's default internal encoding to ASCII-8BIT. Bootsnap
1.26.0's Windows workaround reads source as UTF-8 without disabling implicit
transcoding. Ruby 3.4's Prism compiler consequently rejects a source file
containing U+2019 with `Encoding::UndefinedConversionError`.

The recipe adds `internal_encoding: nil` to that read after bundle install.
It checks the original whole-file SHA-256 before applying the patch, so a
changed dependency fails with an instruction to review the temporary fix.
This is a candidate correction, not an accepted upstream backport. It does
not change the Framework source or any dependency version requirement.

Verify checks the corrected whole-file digest in both the build tree and
fresh MSI installation. The existing console, payload, CLI and local/TCP
database tests exercise the resulting package without a runtime preload.
An additional query through packaged Ruby/pg asserts the expected row and
database over TCP. These checks do not assert Windows dependency closure;
Omnibus currently skips that health inspection on Windows.

The regression and full upstream Bootsnap suites are maintained in the
separate source-internal-encoding contribution. The fixture includes an
explicit UTF-8 magic comment for older Rubies. The correction was validated
on Ruby 3.4.9 on Windows and Linux and across Bootsnap's upstream matrix.

Remove the patch and digest verifiers once Framework's selected released
Bootsnap contains the correction and passes the full package/runtime tests.
Review dependency upgrades separately rather than changing the expected
digest to bypass an unfamiliar source change.
