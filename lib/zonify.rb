
require 'right_aws'

# Set up for AWS interfaces and access to EC2 instance metadata.
module Zonify

## Retrieve the EC2 instance ID of this instance.
#def local_instance_id
#  `curl -s http://169.254.169.254/latest/meta-data/instance-id`.strip
#end
#
#def instance_id
#  AWS[:instance_id] ||= RunRun::AWS.local_instance_id
#end
#
#def ec2
#  AWS[:EC2] ||= RightAws::Ec2.new()
#end
#
#def elb
#  AWS[:ELB] ||= RightAws::ElbInterface.new()
#end

class Capture
  attr_reader :ec2, :elb, :suffixes
  def initialize(opts={})
    @ec2             = opts[:ec2]
    @elb             = opts[:elb]
    suffixes         = (opts[:suffixes] or {})
    @suffixes        = {}
    @suffixes[:host] = (suffixes[:host] or 'inst')
    @suffixes[:elb]  = (suffixes[:elb]  or  'elb')
    @suffixes[:sg]   = (suffixes[:sg]   or   'sg')
  end
  def instances
    @ec2.describe_instances.inject({}) do |acc, i|
      dns = i[:dns_name]
      unless dns.nil? or dns.empty?
        groups = case
                 when i[:aws_groups] then i[:aws_groups]
                 when i[:groups]     then i[:groups].map{|g| g[:group_name] }
                 end
        acc[i[:aws_instance_id]] = { :sg  => groups,
                                     :dns => Zonify.dot_(dns) }
      end
      acc
    end
  end
  def load_balancers
    @elb.describe_load_balancers.map do |elb|
      { :instances => elb[:instances],
        :prefix    => Zonify.cut_down_elb_name(elb[:dns_name]) }
    end
  end
  def zonedata
    hosts = instances
    elbs = load_balancers
    host_records = hosts.map do |id,info|
      [ { :type=>'CNAME', :ttl=>86400,
          :name=>"#{id}.#{@suffixes[:host]}", :data=>info[:dns] },
        { :type=>'TXT', :ttl=>'100',
          :name=>"#{@suffixes[:host]}",
          :data=>"\"zonify // #{info[:dns]}\"" } ]
    end.flatten
    elb_records = elbs.map do |elb|
      running = elb[:instances].map{|i| hosts[i] }.compact
      name = "#{elb[:prefix]}.#{@suffixes[:elb]}"
      running.map do |host|
        { :type=>'TXT', :ttl=>100,
          :name=>name, :data=>"\"zonify // #{host[:dns]}\"" }
      end
    end.flatten
    sg_records = hosts.inject({}) do |acc, kv|
      _, info = kv
      info[:sg].each do |sg|
        acc[sg] ||= []
        acc[sg] << info[:dns]
      end if info[:sg]
      acc
    end.map do |sg, hostnames|
      sg_ldh = Zonify.sg_name_to_ldh(sg)
      name = "#{sg_ldh}.#{@suffixes[:sg]}"
      hostnames.map do |hostname|
        { :type=>'TXT', :ttl=>100,
          :name=>name, :data=>"\"zonify // #{hostname}\"" }
      end
    end.flatten
    [host_records, elb_records, sg_records].flatten
  end
end

class Sync
  attr_reader :r53, :root, :r53_zone, :r53_records
  def initialize(root, opts={})
    @r53  = opts[:r53]
    @root = Zonify::_dot(Zonify::dot_(root)).freeze
    clear
  end
  def clear
    @r53_zone    = nil
    @r53_records = nil
  end
  def calculate_changes(captured)
    _, r53_records = retrieve_zone_and_records
    collated       = Zonify::Sync.collate(captured)
    qualified      = collated.inject({}) do |acc, pair|
                       acc[pair[0].sub(/[.]$/, '') + @root] = pair[1]
                       acc
                     end
    expanded       = Zonify::Sync.expand_right_aws(r53_records)
    Zonify::Sync.calculate_changes(qualified, expanded)
  end
  def sync(captured, comment='Synced with Zonify tool.')
    r53_zone, _ = retrieve_zone_and_records
    changes     = calculate_changes(captured)
    @r53.change_resource_record_sets(@r53_zone[:aws_id], changes, comment)
  end
  def retrieve_zone_and_records
    unless @r53_zone and @r53_records
      relevant_zone = @r53.list_hosted_zones.select do |zone|
        @root.end_with?(zone[:name])
      end.sort_by{|zone| zone[:name].length }.last
      abort "No relevant zone." unless relevant_zone
      zone_id = relevant_zone[:aws_id]
      relevant_records = @r53.list_resource_record_sets(zone_id).select do |rr|
        rr[:name].end_with?(@root)
      end
      @r53_zone, @r53_records = [relevant_zone.freeze, relevant_records.freeze]
    end
    [@r53_zone, @r53_records]
  end
  class << self
    # Group records by name and type.
    def collate(captured)
      captured.inject({}) do |acc, record|
        name, type, ttl, data = [ record[:name], record[:type],
                                  record[:ttl],  record[:data]  ]
        acc[name]                          ||= {}
        acc[name][type]                    ||= { :ttl => ttl }
        acc[name][type][:resource_records] ||= []
        case type  # Enforce singularity of CNAMEs.
        when 'CNAME' then acc[name][type][:resource_records] = [data]
        else              acc[name][type][:resource_records] << data
        end
        acc
      end
    end
    # Put RightAWS into a heirarchical hash of hashes, to reduce complexity in
    # other parts of the program.
    def expand_right_aws(records)
      records.inject({}) do |acc, record|
        name, type, ttl, data = [ record[:name], record[:type],
                                  record[:ttl],  record[:resource_records] ]
        acc[name]                          ||= {}
        acc[name][type]                      = { :ttl => ttl }
        acc[name][type][:resource_records]   = data
        acc
      end
    end
    # Old records that have the same element as new records should be left as
    # is. If they differ in any way, they should be marked for deletion and
    # the new record marked for creation. Old records not in the new records
    # should also be marked for deletion. Input records in the expanded format,
    # not the collapsed, Right AWS format.
    def calculate_changes(new_records, old_records)
      create_set = new_records.map do |name, v|
        old = old_records[name]
        v.map do |type, data|
          old_data = ((old and old[type]) or {})
          unless Zonify::Sync.compare_records(old_data, data)
            data.merge(:name=>name, :type=>type, :action=>:create)
          end
        end.compact
      end
      delete_set = old_records.map do |name, v|
        new = new_records[name]
        v.map do |type, data|
          new_data = ((new and new[type]) or {})
          unless Zonify::Sync.compare_records(data, new_data)
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
          Zonify::Sync.normRRs(a[:resource_records])
      end
      as == bs
    end
    # Sometimes, resource_records are a single string; sometimes, an array.
    # The array should be sorted for comparison's sake.
    def normRRs(val)
      case val
      when Array then val.sort
      else            val
      end
    end
  end
end

extend self

ELB_DNS_RE = /^([a-z0-9-]+)-[^-.]+[.].+$/
def cut_down_elb_name(s)
  $1 if ELB_DNS_RE.match(s)
end

LDH_RE = /^([a-z0-9]|[a-z0-9][a-z0-9-]*[a-z0-9])$/
def sg_name_to_ldh(s)
  LDH_RE.match(s) ? s : s.downcase.gsub(/[^a-z0-9-]/, '-').
                                   sub(/(^-|-$)/, '0')
end

def _dot(s)
  /^[.]/.match(s) ? s : ".#{s}"
end

def dot_(s)
  /[.]$/.match(s) ? s : "#{s}."
end

end

