git_version = begin
  describe = `git describe --always`.strip
  if $?.success? && /^([^-]+)-([0-9]+)-[^-]+$/.match(describe)
    "#{$1}.#{$2}"
  else
    git_raw = `git log --pretty=format:%h | head -n1`
    $?.success? ? '0.0.0.%d' % git_raw.strip.to_i(16) : '0.0.0'
  end
end
@spec = Gem::Specification.new do |s|
  s.name                     =  'zonify'
  s.author                   =  'Airbnb'
  s.email                    =  'contact@airbnb.com'
  s.homepage                 =  'https://github.com/airbnb/zonify'
  s.version                  =  git_version
  s.summary                  =  'Generate DNS information from EC2 metadata.'
  s.description              =  <<DESC
Zonify provides a command line tool for generating DNS records from EC2
instances, instance tags, load balancers and security groups. A mechanism for
syncing these records with a zone stored in Route 53 is also provided.
DESC
  s.license                  =  'BSD'
  s.add_dependency(             'fog'                                         )
  s.files                    =  Dir['lib/**/*.rb', 'README']
  s.require_path             =  'lib'
  s.bindir                   =  'bin'
  s.executables              =  %w| zonify |
end

