require 'yaml'

require 'right_aws'


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
    def create(*args)
      a = [RightAws::Ec2, RightAws::ElbInterface, RightAws::Route53Interface]
      ec2, elb, r53 = a.map do |cls|
        cloned = args.map{|item| item.dup unless item.nil? }
        Proc.new{|| cls.new(*cloned) }
      end
      Zonify::AWS.new(:ec2_proc=>ec2, :elb_proc=>elb, :r53_proc=>r53)
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
    relevant_zone = r53.list_hosted_zones.select do |zone|
      suffix_.end_with?(zone[:name])
    end.sort_by{|zone| zone[:name].length }.last
    if relevant_zone
      zone_id = relevant_zone[:aws_id]
      relevant_records = r53.list_resource_record_sets(zone_id).map do |rr|
        if rr[:name].end_with?(suffix_)
          rr[:name] = Zonify.read_octal(rr[:name])
          rr
        end
      end.compact
      [relevant_zone, Zonify.tree_from_right_aws(relevant_records)]
    end
  end
  # Apply a changeset to the records in Route53. The records must all be under
  # the same zone and suffix.
  def apply(changes, comment='Synced with Zonify tool.')
    require 'pp'
    # Dumb way to do this because I can not figure out #reject!
    keep = changes.select{|c| c[:resource_records].length <= 100 }
    filtered = changes.select{|c| c[:resource_records].length > 100 }
    unless keep.empty?
      suffix  = keep.first[:name] # Works because of longest submatch rule.
      zone, _ = route53_zone(suffix)
      Zonify.chunk_changesets(keep).each do |changeset|
        r53.change_resource_record_sets(zone[:aws_id], changeset, comment)
      end
    end
    filtered
  end
  def instances(*instances)
    ec2.describe_instances(*instances).inject({}) do |acc, i|
      dns = i[:dns_name]
      # The default hostname for EC2 instances is derived their internal DNS
      # entry.
      unless dns.nil? or dns.empty?
        groups = case
                 when i[:aws_groups] then i[:aws_groups]
                 when i[:groups]     then i[:groups].map{|g| g[:group_name] }
                 else                     []
                 end
        attrs = { :sg => groups,
                  :tags => (i[:tags] or []),
                  :dns => Zonify.dot_(dns).downcase }
        if i[:private_dns_name]
          attrs[:priv] = i[:private_dns_name].split('.').first.downcase
        end
        acc[i[:aws_instance_id]] = attrs
      end
      acc
    end
  end
  def load_balancers
    elb.describe_load_balancers.map do |elb|
      { :instances => elb[:instances],
        :prefix    => Zonify.cut_down_elb_name(elb[:dns_name]) }
    end
  end
  def eips
    ec2.describe_addresses
  end
  def eip_scan
    addresses = eips.map{|eip| eip[:public_ip] }
    result = {}
    addresses.each{|a| result[a] = [] }
    r53.list_hosted_zones.sort_by{|zone| zone[:name].reverse }.each do |zone|
      r53.list_resource_record_sets(zone[:aws_id]).each do |rr|
        check = case rr[:type]
                when 'CNAME'
                  rr[:resource_records].map do |s|
                    Zonify.ec2_dns_to_ip(s)
                  end.compact
                when 'A','AAAA'
                  rr[:resource_records]
                end
        check ||= []
        found = addresses.select{|a| check.member? a }.sort
        unless found.empty?
          name = Zonify.read_octal(rr[:name])
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
    { :type=>'SRV', :data=>"0 0 0 #{Zonify.dot_(name)}",
      :ttl=>100,    :name=>"#{Zonify::Resolve::SRV_PREFIX}.#{service}" }
  end
  def cname(name, dns, ttl=100)
    { :type=>'CNAME', :data=>Zonify.dot_(dns),
      :ttl=>ttl,      :name=>Zonify.dot_(name) }
  end
end

# Given EC2 host and ELB data, construct unqualified DNS entries to make a
# zone, of sorts.
def zone(hosts, elbs)
  host_records = hosts.map do |id,info|
    name = "#{id}.inst."
    priv = "#{info[:priv]}.priv."
    [ Zonify::RR.cname(name, info[:dns], 86400), # Long TTLs for host records.
      Zonify::RR.cname(priv, info[:dns], 86400), # Long TTLs for host records.
      Zonify::RR.srv('inst.', name) ] +
    info[:tags].map do |tag|
      k, v = tag
      unless k.empty? or k.nil? or v.empty? or v.nil?
        tag_dn = "#{Zonify.string_to_ldh(v)}.#{Zonify.string_to_ldh(k)}.tag."
        Zonify::RR.srv(tag_dn, name)
      end
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

# Group DNS entries by into a tree, with name at the top level, type at the
# next level and then resource records and TTL at the leaves.
def tree(records)
  records.inject({}) do |acc, record|
    name, type, ttl, data = [ record[:name], record[:type],
                              record[:ttl],  record[:data]  ]
    acc[name]                          ||= {}
    acc[name][type]                    ||= { :ttl=>ttl }
    acc[name][type][:resource_records] ||= []
    acc[name][type][:resource_records]  << data
    acc
  end
end

# In the fully normalized tree of records, there are no multi-entry CNAMEs and
# every single entry SRV record has a corresponding SRV record. All resource
# record lists are sorted and deduplicated.
# To normalize a tree, we introduce CNAMEs for every singleton SRV record and
# merge them in. Then we transform all multi-entry CNAMEs to SRV records and
# collect the CNAMEs to be removed. The CNAMEs are removed and the new SRV
# records merged in.
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
  Zonify.merge(cleared, srvs)
end

# For SRV records with a single entry, create a singleton CNAME as a
# convenience.
def cname_singletons(tree)
  tree.inject({}) do |acc, pair|
    name, info = pair
    name_clipped = name.sub("#{Zonify::Resolve::SRV_PREFIX}.", '')
    info.each do |type, data|
      if 'SRV' == type and 1 == data[:resource_records].length
        rr_clipped = data[:resource_records].map do |rr|
          Zonify.dot_(rr.sub(/^([^ ]+ +){3}/, '').strip)
        end
        new_data = data.merge(:resource_records=>rr_clipped)
        acc[name_clipped] = { 'CNAME' => new_data }
      end
    end
    acc
  end
end

# Find CNAMEs with multiple records and create SRV records to replace them,
# as well as returning the list of CNAMEs so replaced.
def srv_from_cnames(tree)
  remove = []
  srvs = tree.inject({}) do |acc, pair|
    name, info = pair
    name_srv = "#{Zonify::Resolve::SRV_PREFIX}.#{name}"
    info.each do |type, data|
      if 'CNAME' == type and 1 < data[:resource_records].length
        remove.push(name)
        rr_srv = data[:resource_records].map{|s| '0 0 0 ' + s }
        acc[name_srv]['SRV'] = { :ttl=>100, :resource_records=>rr_srv }
      end
    end
    acc
  end
  [remove, srvs]
end

# Collate RightAWS style records in to the tree format used by the tree method.
def tree_from_right_aws(records)
  records.inject({}) do |acc, record|
    name, type, ttl, data = [ record[:name], record[:type],
                              record[:ttl],  record[:resource_records] ]
    acc[name]                          ||= {}
    acc[name][type]                      = { :ttl => ttl }
    acc[name][type][:resource_records]   = (data or [])
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
        type, data   = pair_
        acc_[type] ||= data.merge(:resource_records=>[])
        new_rrs      = data[:resource_records] + acc_[type][:resource_records]
        acc_[type][:resource_records] = new_rrs.uniq.sort
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
        unless Zonify.compare_records(old_data, data)
          data.merge(:name=>name, :type=>type, :action=>:create)
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
          data.merge(:name=>name, :type=>type, :action=>:delete)
        end
      end
    end.compact
  end
  (delete_set.flatten + create_set.flatten).sort_by do |record|
    # Sort actions so that creation of a record comes immediately after a
    # deletion.
    delete_first = record[:action] == :delete ? 0 : 1
    [record[:name], record[:type], delete_first]
  end
end

# Determine whether two resource record sets are the same in all respects
# (keys missing in one should be missing in the other).
def compare_records(a, b)
  as, bs = [a, b].map do |record|
    [:name, :type, :action, :ttl].map{|k| record[k] } <<
      Zonify.normRRs(record[:resource_records])
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
def string_to_ldh(s)
  LDH_RE.match(s) ? s.downcase : s.downcase.gsub(/[^a-z0-9-]/, '-').
                                            sub(/(^-|-$)/, '0')
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
     dumped = ::YAML.dump(k=>records[k])
     Zonify::YAML.trim_lines(dumped).map{|ln| '  ' + ln }.join
   end.join
   "suffix: #{_suffix_}\nrecords:\n" + entries
  end
  def read(text)
    yaml = ::YAML.load(text)
    if yaml['suffix'] and yaml['records']
      [yaml['suffix'], yaml['records']]
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

def measureRRs(changes)
  [ change[:resource_records].length,
    change[:resource_records].inject(0){|sum, s| s.length + sum } ]
end

def fits(change, changes)
  new = changes + [change]
  measured = measureRRs(new)
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
          acc_[type] ||= { :resource_records=>[] }
          rrs = case type
                when 'SRV'
                  if name.start_with? "#{Zonify::Resolve::SRV_PREFIX}."
                    data[:resource_records].map do |rr|
                      if /^(.+) ([^ ]+)$/.match(rr)
                        "#{$1} #{Zonify::Mappings.names($2, mappings).first}"
                      else
                        rr
                      end
                    end
                  else
                    data[:resource_records]
                  end
                else
                  data[:resource_records]
                end
          rrs ||= []
          new_rrs = rrs + acc_[type][:resource_records]
          acc_[type] = data.merge(:resource_records=>new_rrs)
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

