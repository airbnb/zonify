spec = Gem::Specification.new do |s|
  s.name                     =  'zonify'
  s.author                   =  'AirBNB Staff'
  s.email                    =  'oss@airbnb.com'
  s.homepage                 =  'https://github.com/airbnb/zonify'
  s.version                  =  '0.0.0'
  s.summary                  =  'Generate DNS information from EC2 metadata.'
  s.description              =  <<DESC
Zonify provides a command line tool for generating DNS records from EC2
instances, instance tags, load balancers and security groups.
DESC
  s.license                  =  'BSD'
  s.add_dependency(             'right_aws'                                   )
  s.files                    =  Dir['lib/**/*.rb']
  s.require_path             =  'lib'
  s.bindir                   =  'bin'
  s.executables              =  %w| zonify |
end

