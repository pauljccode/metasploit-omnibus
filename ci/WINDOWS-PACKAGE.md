# Windows Bootsnap source encoding

Framework sets Ruby's default internal encoding to ASCII-8BIT. Bootsnap
1.26.0's Prism workaround reads source as UTF-8 without disabling implicit
transcoding. Ruby 3.4's Prism compiler consequently rejects a source file
containing U+2019 with `Encoding::UndefinedConversionError`.

The recipe adds `internal_encoding: nil` to that read after bundle install.
It checks the original whole-file SHA-256 before applying the patch, so a
changed dependency fails with an instruction to review the temporary fix.
This backports [Bootsnap PR #576](https://github.com/rails/bootsnap/pull/576),
merged as `db216d1c90cd58c298e2b537dabf82bae6543c6e`. The production change
matches the accepted fix. It does not change the Framework source or any
dependency version requirement.

Verify checks the corrected whole-file digest in both the build tree and
fresh MSI installation. The existing console, payload, CLI and local/TCP
database tests exercise the resulting package without a runtime preload.
An additional query through packaged Ruby/pg asserts the expected row and
database over TCP. These checks do not assert Windows dependency closure;
Omnibus currently skips that health inspection on Windows.

The regression test is included in the merged Bootsnap contribution. Its
fixture includes an explicit UTF-8 magic comment for older Rubies. The fix
was validated
on Ruby 3.4.9 on Windows and Linux and across Bootsnap's upstream matrix.

Remove the patch and digest verifiers once Framework's selected released
Bootsnap contains the correction and passes the full package/runtime tests.
Review dependency upgrades separately rather than changing the expected
digest to bypass an unfamiliar source change.
