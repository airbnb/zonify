require 'yaml'

require 'fog'


module Zonify

# Set up for AWS interfaces and access to EC2 instance metadata.
class AWS
  class << self
    # Retrieve the EC2 instance ID of this instance.
    def local_instance_id
      s = `curl -s http://169.254.169.254/latest/meta-data/instance-id`
      s.strip if $?.success?
    end
    # Initialize all AWS interfaces with the same access keys and logger
    # (probably what you want to do). These are set up lazily; unused
    # interfaces will not be initialized.
    def create(options)
      options_ec2 = options.merge( :provider=>'AWS',
                                   :connection_options=>{:nonblock=>false} )
      options_ec2.delete(:reverse)
      options_ec2.delete(:zone)
      ec2 = Proc.new{|| Fog::Compute.new(options_ec2) }
      options_elb = options_ec2.dup.delete_if{|k, _| k == :provider }
      elb = Proc.new{|| Fog::AWS::ELB.new(options_elb) }
      options_r53 = options_ec2.dup.delete_if{|k, _| k == :region }
      r53 = Proc.new{|| Fog::DNS.new(options_r53) }
      options.merge!(:ec2_proc=>ec2, :elb_proc=>elb, :r53_proc=>r53)
      Zonify::AWS.new(options)
    end
  end
  attr_reader :ec2_proc, :elb_proc, :r53_proc
  def initialize(opts={})
    @ec2      = opts[:ec2]
    @elb      = opts[:elb]
    @r53      = opts[:r53]
    @ec2_proc = opts[:ec2_proc]
    @elb_proc = opts[:elb_proc]
    @r53_proc = opts[:r53_proc]
    @reverse  = opts[:reverse]
    @zone     = opts[:zone]
  end
  def reverse_public_ip?
    !!@reverse
  end
  def ec2
    @ec2 ||= @ec2_proc.call
  end
  def elb
    @elb ||= @elb_proc.call
  end
  def r53
    @r53 ||= @r53_proc.call
  end
  # Generate DNS entries based on EC2 instances, security groups and ELB load
  # balancers under the user's AWS account.
  def ec2_zone
    Zonify.tree(Zonify.zone(instances, load_balancers))
  end
  # Retrieve Route53 zone data -- the zone ID as well as resource records --
  # relevant to the given suffix. When there is any ambiguity, the zone with
  # the longest name is chosen.
  def route53_zone(suffix)
    suffix_ = Zonify.dot_(suffix)
    relevant_zone = r53.zones.select do |zone|
      if @zone
        @zone == zone.id
      else
        suffix_.end_with?(zone.domain)
      end
    end.sort_by{|zone| zone.domain.length }.last
    if relevant_zone
      relevant_records = relevant_zone.records.all!.map do |rr|
        if rr.name.end_with?(suffix_)
          rr.attributes.merge(:name=>Zonify.read_octal(rr.name))
        end
      end.compact
      [relevant_zone, Zonify.tree_from_right_aws(relevant_records)]
    end
  end
  # Apply a changeset to the records in Route53. The records must all be under
  # the same zone and suffix.
  def apply(changes, comment='Synced with Zonify tool.')
    filtered = changes.select{|change| change[:value].length > 100 }
    # For all the SRV records that were considered too long, get the names of
    # the associated weighted CNAMEs.
    filtered_correlates = filtered.map do |change|
      case change[:name]
      when /^_[*][.]_[*][.]/
        change[:name][6, change[:name].length]
      end
    end.compact
    keep = changes.select do |change|
      change[:value].length <= 100 and not
        filtered_correlates.include?(change[:name])
    end
    unless keep.empty?
      suffix  = keep.first[:name] # Works because of longest submatch rule.
      zone, _ = route53_zone(suffix)
      Zonify.chunk_changesets(keep).each do |changeset|
        rekeyed = changeset.map do |record|
          record.inject({}) do |acc, pair|
            k, v = pair
            k_ = k == :value ? :resource_records : k
            acc[k_] = v
            acc
          end
        end
        begin
          r53.change_resource_record_sets(zone.id, rekeyed, :comment=>comment)
        rescue Fog::Errors::Error => e
          STDERR.puts("Failed with some records, due to:\n#{e}")
        end
      end
    end
    filtered
  end
  def instances
    ec2.servers.inject({}) do |acc, i|
      dns = if reverse_public_ip? and not i.public_ip_address.nil?
              pub = i.public_ip_address
              dns = "ec2-#{pub.gsub(".", "-")}.compute-1.amazonaws.com"
            else
              i.dns_name or i.private_dns_name
            end
      # The default hostname for EC2 instances is derived from their internal
      # DNS entry.
      terminal_states = %w| terminated shutting-down |
      unless dns.nil? or dns.empty? or terminal_states.member? i.state
        groups = (i.groups or [])
        attrs = { :sg => groups,
                  :tags => (i.tags or []),
                  :dns => Zonify.dot_(dns).downcase }
        if i.private_dns_name
          attrs[:priv] = i.private_dns_name.split('.').first.downcase
        end
        acc[i.id] = attrs
      end
      acc
    end
  end
  def load_balancers
    elb.load_balancers.map do |elb|
      { :instances => elb.instances,
        :prefix    => Zonify.cut_down_elb_name(elb.dns_name.downcase) }
    end
  end
  def eips
    ec2.addresses
  end
  def eip_scan
    addresses = eips.map{|eip| eip.public_ip }
    result = {}
    addresses.each{|a| result[a] = [] }
    r53.zones.sort_by{|zone| zone.domain.reverse }.each do |zone|
      zone.records.all!.each do |rr|
        check = case rr.type
                when 'CNAME'
                  rr.value.map do |s|
                    Zonify.ec2_dns_to_ip(s)
                  end.compact
                when 'A','AAAA'
                  rr.value
                end
        check ||= []
        found = addresses.select{|a| check.member? a }.sort
        unless found.empty?
          name = Zonify.read_octal(rr.name)
          found.each{|a| result[a] << name }
        end
      end
    end
    result
  end
end

extend self


module Resolve
SRV_PREFIX = '_*._*'
end

# Records are all created with functions in this module, which ensures the
# necessary SRV prefixes, uniform TTLs and final dots in names.
module RR
extend self
  def srv(service, name)
    { :type=>'SRV', :value=>"0 0 0 #{Zonify.dot_(name)}",
      :ttl=>'100',  :name=>"#{Zonify::Resolve::SRV_PREFIX}.#{service}" }
  end
  def cname(name, dns, ttl='100')
    { :type=>'CNAME', :value=>Zonify.dot_(dns),
      :ttl=>ttl,      :name=>Zonify.dot_(name) }
  end
end

# Given EC2 host and ELB data, construct unqualified DNS entries to make a
# zone, of sorts.
def zone(hosts, elbs)
  host_records = hosts.map do |id,info|
    name = "#{id}.inst."
    priv = "#{info[:priv]}.priv."
    [ Zonify::RR.cname(name, info[:dns], '600'),
      Zonify::RR.cname(priv, info[:dns], '600'),
      Zonify::RR.srv('inst.', name) ] +
    info[:tags].map do |tag|
      k, v = tag
      next if k.nil? or v.nil? or k.empty? or v.empty?
      tag_dn = "#{Zonify.string_to_ldh(v)}.#{Zonify.string_to_ldh(k)}.tag."
      Zonify::RR.srv(tag_dn, name)
    end.compact
  end.flatten
  elb_records = elbs.map do |elb|
    running = elb[:instances].select{|i| hosts[i] }
    name = "#{elb[:prefix]}.elb."
    running.map{|host| Zonify::RR.srv(name, "#{host}.inst.") }
  end.flatten
  sg_records = hosts.inject({}) do |acc, kv|
    id, info = kv
    info[:sg].each do |sg|
      acc[sg] ||= []
      acc[sg]  << id
    end
    acc
  end.map do |sg, ids|
    sg_ldh = Zonify.string_to_ldh(sg)
    name = "#{sg_ldh}.sg."
    ids.map{|id| Zonify::RR.srv(name, "#{id}.inst.") }
  end.flatten
  [host_records, elb_records, sg_records].flatten
end

# Group DNS entries into a tree, with name at the top level, type at the
# next level and then resource records and TTL at the leaves. If the records
# are part of a weighted record set, then the record data is pushed down one
# more level, with the "set identifier" in between the type and data.
def tree(records)
  records.inject({}) do |acc, record|
    name, type, ttl, value,
    weight, set,
    health_check_id       = [ record[:name],   record[:type],
                              record[:ttl],    record[:value],
                              record[:weight], record[:set_identifier],
                              record[:health_check_id] ]
    reference = acc[name]       ||= {}
    reference = reference[type] ||= {}
    reference = reference[set]  ||= {} if set
    appended                      = (reference[:value] or []) << value
    reference[:ttl]               = ttl
    reference[:value]             = appended.sort.uniq
    reference[:weight]            = weight if weight
    reference[:health_check_id]   = health_check_id if health_check_id
    acc
  end
end

# In the fully normalized tree of records, each multi-element SRV is
# associated with a set of equally weighted CNAMEs, one for each record.
# Singleton SRVs are associated with a single CNAME. All resource record lists
# are sorted and deduplicated.
def normalize(tree)
  singles = Zonify.cname_singletons(tree)
  merged = Zonify.merge(tree, singles)
  remove, srvs = Zonify.srv_from_cnames(merged)
  cleared = merged.inject({}) do |acc, pair|
    name, info = pair
    info.each do |type, data|
      unless 'CNAME' == type and remove.member?(name)
        acc[name] ||= {}
        acc[name][type] = data
      end
    end
    acc
  end
  stage2 = Zonify.merge(cleared, srvs)
  multis = Zonify.cname_multitudinous(stage2)
  stage3 = Zonify.merge(stage2, multis)
end

# For SRV records with a single entry, create a singleton CNAME as a
# convenience.
def cname_singletons(tree)
  tree.inject({}) do |acc, pair|
    name, info = pair
    name_clipped = name.sub("#{Zonify::Resolve::SRV_PREFIX}.", '')
    info.each do |type, data|
      if 'SRV' == type and 1 == data[:value].length
        rr_clipped = data[:value].map do |rr|
          Zonify.dot_(rr.sub(/^([^ ]+ +){3}/, '').strip)
        end
        new_data = data.merge(:value=>rr_clipped)
        acc[name_clipped] = { 'CNAME' => new_data }
      end
    end
    acc
  end
end

# Find CNAMEs with multiple records and create SRV records to replace them,
# as well as returning the list of CNAMEs to replace.
def srv_from_cnames(tree)
  remove = []
  srvs = tree.inject({}) do |acc, pair|
    name, info = pair
    name_srv = "#{Zonify::Resolve::SRV_PREFIX}.#{name}"
    info.each do |type, data|
      if 'CNAME' == type and 1 < data[:value].length
        remove.push(name)
        rr_srv = data[:value].map{|s| '0 0 0 ' + s }
        acc[name_srv]      ||= { }
        acc[name_srv]['SRV'] = { :ttl=>100, :value=>rr_srv }
      end
    end
    acc
  end
  [remove, srvs]
end

# For every SRV record that is not a singleton and that does not shadow an
# existing CNAME, we create WRRs for item in the SRV record.
def cname_multitudinous(tree)
  tree.inject({}) do |acc, pair|
    name, info = pair
    name_clipped = name.sub("#{Zonify::Resolve::SRV_PREFIX}.", '')
    info.each do |type, data|
      if 'SRV' == type and 1 < data[:value].length
        wrrs = data[:value].inject({}) do |accumulator, rr|
          server = Zonify.dot_(rr.sub(/^([^ ]+ +){3}/, '').strip)
          id = server.split('.').first # Always the instance ID.
          accumulator[id] = data.merge(:value=>[server], :weight=>"16")
          accumulator
        end
        acc[name_clipped] = { 'CNAME' => wrrs }
      end
    end
    acc
  end
end

# Collate RightAWS style records in to the tree format used by the tree method.
def tree_from_right_aws(records)
  records.inject({}) do |acc, record|
    name, type, ttl, value,
    weight, set,
    health_check_id       = [ record[:name],   record[:type],
                              record[:ttl],    record[:value],
                              record[:weight], record[:set_identifier],
                              record[:health_check_id] ]
    reference = acc[name]       ||= {}
    reference = reference[type] ||= {}
    reference = reference[set]  ||= {} if set
    reference[:ttl]               = ttl
    reference[:value]             = (value or [])
    reference[:weight]            = weight if weight
    reference[:health_check_id]   = health_check_id if health_check_id
    acc
  end
end

# Merge all records from the trees, taking TTLs from the leftmost tree and
# sorting and deduplicating resource records. (When called on a single tree,
# this function serves to sort and deduplicate resource records.)
def merge(*trees)
  acc = {}
  trees.each do |tree|
    tree.inject(acc) do |acc, pair|
      name, info     = pair
      acc[name]    ||= {}
      info.inject(acc[name]) do |acc_, pair_|
        type, data = pair_
        case
        when (not acc_[type])
          acc_[type] = data.dup
        when (not acc_[type][:value] and not data[:value]) # WRR records.
          d = data.merge(acc_[type])
          acc_[type] = d
        else # Not WRR records.
          acc_[type][:value] = (data[:value] + acc_[type][:value]).sort.uniq
        end
        acc_
      end
      acc
    end
  end
  acc
end

# Old records that have the same elements as new records should be left as is.
# If they differ in any way, they should be marked for deletion and the new
# record marked for creation. Old records not in the new records should also
# be marked for deletion.
def diff(new_records, old_records, types=['CNAME','SRV'])
  create_set = new_records.map do |name, v|
    old = old_records[name]
    v.map do |type, data|
      if types.member? '*' or types.member? type
        old_data = ((old and old[type]) or {})
        unless type == 'CNAME' and not types.member? 'A' and
               old and old.member? 'A'
          unless Zonify.compare_records(old_data, data)
            Zonify.hoist(data, name, type, 'CREATE')
          end
        end
      end
    end.compact
  end
  delete_set = old_records.map do |name, v|
    new = new_records[name]
    v.map do |type, data|
      if types.member? '*' or types.member? type
        new_data = ((new and new[type]) or {})
        unless Zonify.compare_records(data, new_data)
          Zonify.hoist(data, name, type, 'DELETE')
        end
      end
    end.compact
  end
  (delete_set.flatten + create_set.flatten).sort_by do |record|
    # Sort actions so that creation of a record comes immediately after a
    # deletion.
    delete_first = record[:action] == 'DELETE' ? 0 : 1
    [record[:name], record[:type], delete_first]
  end
end

def hoist(data, name, type, action)
  meta = {:name=>name, :type=>type, :action=>action}
  if data[:value] # Not a WRR.
    [data.merge(meta)]
  else # Is a WRR.
    data.map{|k,v| v.merge(meta.merge(:set_identifier=>k)) }
  end
end

# Determine whether two resource record sets are the same in all respects
# (keys missing in one should be missing in the other).
def compare_records(a, b)
  keys = ((a.keys | b.keys) - [:value]).sort_by{|s| s.to_s }
  as, bs = [a, b].map do |record|
    keys.map{|k| record[k] } << Zonify.normRRs(record[:value])
  end
  as == bs
end

# Sometimes, resource_records are a single string; sometimes, an array. The
# array should be sorted for comparison's sake. Strings should be put in an
# array.
def normRRs(val)
  case val
  when Array then val.sort
  else           [val]
  end
end

def read_octal(s)
  after = s
  acc = ''
  loop do
    before, match, after = after.partition(/\\([0-9][0-9][0-9])/)
    acc += before
    break if match.empty?
    acc << $1.oct
  end
  acc
end

ELB_DNS_RE = /^([a-z0-9-]+)-[^-.]+[.].+$/
def cut_down_elb_name(s)
  $1 if ELB_DNS_RE.match(s)
end

LDH_RE = /^([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9-]*[a-zA-Z0-9])$/
def string_to_ldh_component(s)
  munged = LDH_RE.match(s) ? s.downcase : s.downcase.gsub(/[^a-z0-9-]/, '-').
                                                     sub(/(^[-]+|[-]+$)/, '')
  munged[0...63]
end

def string_to_ldh(s)
  head, *tail = s.split('.')
  tail_ = tail.map{|s| string_to_ldh_component(s) }
  head_ = case head
          when '*' then '*'
          when nil then ''
          else          string_to_ldh_component(head)
          end
  [head_, tail_].flatten.select{|c| not (c.empty? or c.nil?) }.join('.')
end

def _dot(s)
  /^[.]/.match(s) ? s : ".#{s}"
end

def dot_(s)
  /[.]$/.match(s) ? s : "#{s}."
end

EC2_DNS_RE = /^ec2-([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)
               [.]compute-[0-9]+[.]amazonaws[.]com[.]?$/x
def ec2_dns_to_ip(dns)
  "#{$1}.#{$2}.#{$3}.#{$4}" if EC2_DNS_RE.match(dns)
end

module YAML
extend self
  def format(records, suffix='')
    _suffix_ = Zonify._dot(Zonify.dot_(suffix))
    entries = records.keys.sort.map do |k|
      if k == 'CNAME'
        STDERR.puts(::YAML.dump(records))
        abort "A problem was found // #{ARGV[0]}"
      end
      [ k + ":\n" ] + records[k].keys.sort_by{|kk| kk.to_s }.map do |kk|
        sorted = Zonify::YAML.sorted_hash(records[k][kk])
        lines = Zonify::YAML.trim_lines(sorted)
        [ kk + ":\n" ] + lines.map{|ln| '  ' + ln }
      end.flatten.map{|ln| '  ' + ln }
    end.flatten.map{|ln| '  ' + ln }.join
    "suffix: #{_suffix_}\nrecords:\n" + entries
  end
  def sorted_hash(h)
    result = ::YAML::quick_emit(h.object_id, {}) do |out|
      out.map do |map|
        h.keys.sort_by{|k| k.to_s }.each{|k| map.add(k, h[k]) }
      end
    end
  end
  def read(text)
    yaml = ::YAML.load(text)
    if yaml['suffix']
      [yaml['suffix'], (yaml['records'] or {})]
    end
  end
  def trim_lines(yaml)
   lines = yaml.lines.to_a
   lines.shift if /^---/.match(lines[0])
   lines.pop if /^$/.match(lines[-1])
   lines
  end
end

# The Route 53 API has limitations on query size:
#
#  - A request cannot contain more than 100 Change elements.
#
#  - A request cannot contain more than 1000 ResourceRecord elements.
#
#  - The sum of the number of characters (including spaces) in all Value
#    elements in a request cannot exceed 32,000 characters.
#
def chunk_changesets(changes)
  chunks = [[]]
  changes.each do |change|
    if fits(change, chunks.last)
      chunks.last.push(change)
    else
      chunks.push([change])
    end
  end
  chunks
end

def measureRRs(change)
  [ change[:value].length,
    change[:value].inject(0){|sum, s| s.length + sum } ]
end

# Determine whether we can add this record to the existing records, subject to
# Amazon size constraints.
def fits(change, changes)
  new = changes + [change]
  measured = new.map{|change| measureRRs(change) }
  len, chars = measured.inject([0, 0]) do |acc, pair|
    [ acc[0] + pair[0], acc[1] + pair[1] ]
  end
  new.length <= 100 and len <= 1000 and chars <= 30000 # margin of safety
end

module Mappings
extend self
  def parse(s)
    k, *v = s.split(':')
    [k, v] if k and v and not v.empty?
  end
  # Apply mappings to the name in order. (A hash can be used for mappings but
  # then one will not be able to predict the order.) If no mappings apply, the
  # empty list is returned.
  def apply(name, mappings)
    name_ = Zonify.dot_(name)
    mappings.map do |k, v|
      _k_ = Zonify.dot_(Zonify._dot(k))
      before = Zonify::Mappings.unsuffix(name_, _k_)
      v.map{|s| Zonify.dot_(before + Zonify._dot(s)) } if before
    end.compact.flatten
  end
  # Get the names that result from the mappings, or the original name if none
  # apply. The first name in the list is taken to be the canonical name, the
  # one used for groups of servers in SRV records.
  def names(name, mappings)
    mapped = Zonify::Mappings.apply(name, mappings)
    mapped.empty? ? [name] : mapped
  end
  def unsuffix(s, suffix)
    before, _, after = s.rpartition(suffix)
    before if after.empty?
  end
  def rewrite(tree, mappings)
    tree.inject({}) do |acc, pair|
      name, info = pair
      names = Zonify::Mappings.names(name, mappings)
      names.each do |name|
        acc[name] ||= {}
        info.inject(acc[name]) do |acc_, pair_|
          type, data = pair_
          acc_[type] ||= {}
          prefix_ = Zonify.dot_(Zonify::Resolve::SRV_PREFIX)
          rrs = if type == 'SRV' and name.start_with? prefix_ and data[:value]
                  data[:value].map do |rr|
                    if /^(.+) ([^ ]+)$/.match(rr)
                      "#{$1} #{Zonify::Mappings.names($2, mappings).first}"
                    else
                      rr
                    end
                  end
                end
          normed = (rrs + (acc_[type][:value] or [])).sort.uniq if rrs
          addenda = normed ? { :value => normed } : {}
          acc_[type] = data.merge(addenda)
          acc_
        end
      end
      acc
    end
  end
end

# Based on reading the Wikipedia page:
#   http://en.wikipedia.org/wiki/List_of_DNS_record_types
# and the IANA registry:
#   http://www.iana.org/assignments/dns-parameters
RRTYPE_RE = /^([*]|[A-Z0-9-]+)$/

end
