# Windows source-download validation

This fork-only workflow builds the macOS packaging candidate with a verified
source archive cache for Windows. It is separate from the proposed macOS diff.

Released Nokogiri 1.19.4 downloads libiconv from GNU's mirror selector, which can
redirect HTTPS to HTTP. Nokogiri's unreleased mirror option was introduced in
[PR 3671](https://github.com/sparklemotion/nokogiri/pull/3671). This workflow uses
that maintainer-hosted HTTPS mirror and the released gem's existing SHA-256.

The prefetch accepts HTTPS only, including redirects, checks the pinned digest,
and publishes the archive only after verification. Downloads have bounded
timeouts and retries. No persistent Actions cache or compiled cache is used.

During the Omnibus build, a scoped Ruby preload seeds Nokogiri's `ports/archives`
directory after RubyGems extraction and before native-extension compilation.
Seeding earlier would fail because RubyGems deletes the gem directory first.
The helper reads the dependency identity from the extracted gem and verifies
the cached bytes. MiniPortile independently verifies them again on extraction.
Missing archives, changed dependency identities and corrupt bytes fail closed.
Other gems delegate directly to RubyGems. No gem source or checksum is modified.

Omnibus intentionally removes inherited `RUBYOPT`. A Windows-only, opt-in recipe
setting passes the preload explicitly to the embedded `bundle install` command.
The original recipe behavior is unchanged when the cache option is absent.
`test-omnibus-cache-environment.rb` uses the locked Omnibus implementation to
check both inherited-option removal and explicit command-environment forwarding.

The preload applies only to that command. It is not installed in the package
and is absent from the separate fresh-runner MSI installation/runtime job.
The workflow retains the original Windows runtime checks and pins the Framework
revision used by the earlier failed builds. MSYS2 and RubyGems downloads remain
separate network dependencies; this cache addresses only the libiconv failure.

Run the helper's tests with `ruby ci/test-nokogiri-archive-cache.rb`. They include
real RubyGems extraction/extension-build ordering and rejection of corrupt or
changed inputs. These tests do not replace the full Windows build/runtime run.
