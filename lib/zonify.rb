require 'yaml'

require 'right_aws'

require 'zonify/resolve'


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
      relevant_records = r53.list_resource_record_sets(zone_id).select do |rr|
        rr[:name].end_with?(suffix_)
      end
      [relevant_zone, Zonify.tree_from_right_aws(relevant_records)]
    end
  end
  # Apply a changeset to the records in Route53. The records must all be under
  # the same zone and suffix.
  def apply(changes, comment='Synced with Zonify tool.')
    unless changes.empty?
      suffix  = changes.first[:name] # Works because of longest submatch rule.
      zone, _ = route53_zone(suffix)
      r53.change_resource_record_sets(zone[:aws_id], changes, comment)
    end
  end
  def instances(*instances)
    ec2.describe_instances(*instances).inject({}) do |acc, i|
      dns = i[:dns_name]
      unless dns.nil? or dns.empty?
        groups = case
                 when i[:aws_groups] then i[:aws_groups]
                 when i[:groups]     then i[:groups].map{|g| g[:group_name] }
                 else                     []
                 end
        acc[i[:aws_instance_id]] = { :sg => groups,
                                     :tags => (i[:tags] or []),
                                     :dns => Zonify.dot_(dns) }
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
end

extend self

# Given EC2 host and ELB data, construct unqualified DNS entries to make a
# zone, of sorts.
def zone(hosts, elbs)
  host_records = hosts.map do |id,info|
    name = "#{id}.inst"
    info[:tags].map do |tag|
      k, v = tag
      unless k.empty? or k.nil? or v.empty? or v.nil?
        tag_dn = "#{Zonify.string_to_ldh(v)}.#{Zonify.string_to_ldh(k)}.tag"
        { :type=>'TXT',   :ttl=>100,
          :name=>tag_dn,  :data=>"\"zonify // #{name}.\"" }
      end
    end.compact +
    [ { :type=>'CNAME', :ttl=>86400,
        :name=>name,    :data=>info[:dns] },
      { :type=>'TXT',   :ttl=>100,
        :name=>"inst",  :data=>"\"zonify // #{name}.\"" } ]
  end.flatten
  elb_records = elbs.map do |elb|
    running = elb[:instances].select{|i| hosts[i] }
    name = "#{elb[:prefix]}.elb"
    running.map do |host|
      { :type=>'TXT', :ttl=>100,
        :name=>name,  :data=>"\"zonify // #{host}.inst.\"" }
    end
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
    name = "#{sg_ldh}.sg"
    ids.map do |id|
      { :type=>'TXT', :ttl=>100,
        :name=>name,  :data=>"\"zonify // #{id}.inst.\"" }
    end
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
    acc[name][type]                    ||= {:ttl=>ttl}
    acc[name][type][:resource_records] ||= []
    case type  # Enforce singularity of CNAMEs.
    when 'CNAME' then acc[name][type][:resource_records] = [data]
    else              acc[name][type][:resource_records] << data
    end
    acc
  end
end

# Collate RightAWS style records in to the tree format used by the tree method.
def tree_from_right_aws(records)
  records.inject({}) do |acc, record|
    name, type, ttl, data = [ record[:name], record[:type],
                              record[:ttl],  record[:resource_records] ]
    acc[name]                          ||= {}
    acc[name][type]                      = { :ttl => ttl }
    acc[name][type][:resource_records]   = data
    acc
  end
end

def qualify(tree, root)
  _root_ = Zonify._dot(Zonify.dot_(root))
  tree.inject({}) do |acc, pair|
    name, info = pair
    acc[name.sub(/[.]?$/, _root_)] = info.inject({}) do |acc_, pair_|
      type, data = pair_
      case type
      when 'TXT'
        rrs = data[:resource_records].map do |rr|
          /^"zonify \/\/ /.match(rr) ? rr.sub(/[.]?"$/, _root_+'"') : rr
        end
        acc_[type] = data.merge(:resource_records=>rrs)
      else
        acc_[type] = data
      end
      acc_
    end
    acc
  end
end

# Old records that have the same element as new records should be left as is.
# If they differ in any way, they should be marked for deletion and the new
# record marked for creation. Old records not in the new records should also
# be marked for deletion.
def diff(new_records, old_records)
  create_set = new_records.map do |name, v|
    old = old_records[name]
    v.map do |type, data|
      old_data = ((old and old[type]) or {})
      unless Zonify.compare_records(old_data, data)
        data.merge(:name=>name, :type=>type, :action=>:create)
      end
    end.compact
  end
  delete_set = old_records.map do |name, v|
    new = new_records[name]
    v.map do |type, data|
      new_data = ((new and new[type]) or {})
      unless Zonify.compare_records(data, new_data)
        data.merge(:name=>name, :type=>type, :action=>:delete)
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

module YAML
extend self
  def format(records, suffix='')
   _suffix_ = Zonify._dot(Zonify.dot_(suffix))
   lines = Zonify::YAML.trim_lines(::YAML.dump('records'=>records))
   lines.unshift("suffix: #{_suffix_}\n").join
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

end

