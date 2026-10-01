# Windows Nokogiri source cache

Nokogiri 1.19.4 downloads libiconv through a GNU mirror selector that can
redirect HTTPS to HTTP or time out. Windows Verify prefetches the identical
archive from the maintainer-hosted HTTPS mirror used in
[Nokogiri PR 3671](https://github.com/sparklemotion/nokogiri/pull/3671).
The released gem's SHA-256 and MiniPortile's verification remain unchanged.

The download accepts HTTPS only, including redirects, has bounded timeouts
and retries, and publishes the archive only after checksum verification.
There is no persistent Actions cache or compiled cache.

A build-only Ruby preload stages the archive after RubyGems extraction and
before extension compilation. RubyGems deletes the gem directory during
extraction, so staging before installation would lose it. The helper reads
Nokogiri's dependency identity and rejects missing or changed bytes. Other
gems delegate directly to RubyGems. Omnibus clears inherited RUBYOPT, so the
Windows recipe forwards the opt-in preload explicitly to bundle install.
The helper is not installed and the fresh-runner runtime job has no preload.

CI verifies a receipt against the embedded gem metadata and retained source
archive before uploading the MSI. Nokogiri deletes ports/archives after
compilation, so the receipt records verified staging before that cleanup.
Conflicting receipts fail rather than being overwritten.

Run `ruby ci/test-nokogiri-archive-cache.rb` for corruption, metadata and real
RubyGems extraction-order tests. After `make dependencies`, run
`ruby ci/test-omnibus-cache-environment.rb` to verify the locked Omnibus
implementation's environment boundary. The complete Verify workflow remains
the package build and fresh installation gate.

Retire this preload when the selected released Nokogiri supports its upstream
mirror option and passes the complete Windows build and installation tests.
MSYS2 and other RubyGems downloads remain independent network dependencies.
