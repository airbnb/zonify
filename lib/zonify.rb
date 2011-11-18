
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
    @suffixes[:host] = Zonify._dot((suffixes[:host] or '.ins'))
    @suffixes[:elb]  = Zonify._dot((suffixes[:elb]  or '.elb'))
    @suffixes[:sg]   = Zonify._dot((suffixes[:sg]   or  '.sg'))
  end
  def instances
    @ec2.describe_instances.inject({}) do |acc, i|
      dns = i[:dns_name]
      unless dns.nil? or dns.empty?
        acc[i[:aws_instance_id]] = { :sg  => i[:aws_groups],
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
      [ { :type=>'CNAME', :ttl=>'86400',
          :name=>"#{id}#{@suffixes[:host]}", :data=>info[:dns] },
        { :type=>'TXT', :ttl=>'100',
          :name=>'all', :data=>"zonify // #{info[:dns]}" } ]
    end.flatten
    elb_records = elbs.map do |elb|
      running = elb[:instances].map{|i| hosts[i] }.compact
      name = "#{elb[:prefix]}#{@suffixes[:elb]}",
      running.map do |host|
        { :type=>'TXT', :ttl=>'100',
          :name=>name, :data=>"zonify // #{host[:dns]}" }
      end
    end.flatten
    sg_records = hosts.inject({}) do |acc, kv|
      _, info = kv
      info[:sg].each do |sg|
        acc[sg] ||= []
        acc[sg] << info[:dns]
      end
      acc
    end.map do |sg, hostnames|
      sg_ldh = Zonify.sg_name_to_ldh(sg)
      name = "#{sg_ldh}#{@suffixes[:sg]}"
      hostnames.map do |hostname|
        { :type=>'TXT', :ttl=>'100',
          :name=>name, :data=>"zonify // #{hostname}" }
      end
    end.flatten
    [host_records, elb_records, sg_records].flatten
  end
end

class Sync
  attr_accessor :r53, :root
  def initialize(root, opts={})
    @r53             = opts[:r53]
    @root            = Zonify::_dot(Zonify::dot_(root))
  end
  def calculate_change_set(captured)
  end
  def retrieve_zone_and_records
    relevant_zone = @r53.list_hosted_zones.select do |zone|
      @root.end_with?(zone[:name])
    end.sort_by{|zone| zone[:name].length }.last
    abort "No relevant zone." unless relevant_zone
    zone_id = relevant_zone[:aws_id]
    relevant_records = @r53.list_resource_record_sets(zone_id).select do |rr|
      rr[:name].end_with?(@root)
    end
    [relevant_zone, relevant_records]
  end
  class << self
    def convert_to_route53_form(captured)
      captured.inject({}) do |acc, record|
        name, type, ttl, data = [ record[:name], record[:type],
                                  record[:ttl],  record[:data]  ]
        acc[name]                          ||= {}
        acc[name][type]                    ||= { :ttl => ttl }
        acc[name][type][:resource_records] ||= []
        acc[name][type][:resource_records] << data
        acc
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

