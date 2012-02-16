git_raw = `git log --pretty=format:%h | head -n1`
git_rev = $?.success? ? ".%d" % git_raw.to_i(16) : ""
@spec = Gem::Specification.new do |s|
  s.name                     =  'zonify'
  s.author                   =  'AirBNB'
  s.email                    =  'contact@airbnb.com'
  s.homepage                 =  'https://github.com/airbnb/zonify'
  s.version                  =  '0.0.0' + git_rev
  s.summary                  =  'Generate DNS information from EC2 metadata.'
  s.description              =  <<DESC
Zonify provides a command line tool for generating DNS records from EC2
instances, instance tags, load balancers and security groups. A mechanism for
syncing these records with a zone stored in Route 53 is also provided.
DESC
  s.license                  =  'BSD'
  s.add_dependency(             'right_aws'                                   )
  s.files                    =  Dir['lib/**/*.rb', 'README']
  s.require_path             =  'lib'
  s.bindir                   =  'bin'
  s.executables              =  %w| zonify |
end

