spec = Gem::Specification.new do |s|
  s.name                     =  'zonify'
  s.version                  =  '0.0.0'
  s.summary                  =  'Generate DNS information from EC2 metadata.'
  s.description              =  'Generate DNS information from EC2 metadata.'
  s.add_dependency(             'right_aws'                                   )
  s.files                    =  Dir['lib/**/*.rb']
  s.require_path             =  'lib'
  s.bindir                   =  'bin'
  s.executables              =  %w| zonify |
end

