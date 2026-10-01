# Candidate component regression; neither a package patch nor Windows proof.
require 'tmpdir'
require 'json'

raise 'Prism compiler required' unless RubyVM::InstructionSequence.respond_to?(:compile_prism)
fixtures = {
  'utf8' => "# frozen_string_literal: true\n'\u2019'\n".b,
  'latin1_magic' => "# encoding: ISO-8859-1\n# frozen_string_literal: true\n'\xE9'\n".b,
  'ascii' => "# frozen_string_literal: true\n'ascii'\n".b
}
external_before, internal_before = Encoding.default_external, Encoding.default_internal
results = []
begin
  Dir.mktmpdir('bootsnap-compiler-probe') do |dir|
    fixtures.each do |name, bytes|
      path = File.join(dir, "#{name}.rb")
      File.binwrite(path, bytes)
      reference = RubyVM::InstructionSequence.compile_file_prism(path, frozen_string_literal: true).eval
      [nil, Encoding::UTF_8, Encoding::ASCII_8BIT, Encoding::ISO_8859_1].each do |internal|
        Encoding.default_external = Encoding::ASCII_8BIT
        Encoding.default_internal = internal
        entry = { fixture: name, internal_encoding: internal&.name }
        begin
          source = File.read(path, encoding: Encoding::UTF_8)
          actual = RubyVM::InstructionSequence.compile_prism(source, path, path, nil, frozen_string_literal: true).eval
          entry[:original] = actual.b == reference.b && actual.encoding == reference.encoding && actual.frozen? == reference.frozen? ? 'matches native compiler' : 'differs from native compiler'
        rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError => error
          entry[:original] = error.class.name
        end
        source = File.read(path, external_encoding: Encoding::UTF_8, internal_encoding: nil)
        raise 'Source bytes changed' unless source.b == bytes
        actual = RubyVM::InstructionSequence.compile_prism(source, path, path, nil, frozen_string_literal: true).eval
        raise 'Candidate differs from native compiler' unless actual.b == reference.b && actual.encoding == reference.encoding && actual.frozen? == reference.frozen?
        entry[:candidate] = 'matches native compiler bytes, encoding and frozen state'
        results << entry
      end
    end
  end
ensure
  Encoding.default_external, Encoding.default_internal = external_before, internal_before
end
raise 'Expected original regression not reproduced' unless results.any? { |row| row[:original] == 'Encoding::UndefinedConversionError' }
puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, cases: results, status: 'candidate component probe passed')
