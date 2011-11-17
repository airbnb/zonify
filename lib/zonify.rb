
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
    @suffixes[:host] = Zonify.dot((suffixes[:host] or '.ins'))
    @suffixes[:elb]  = Zonify.dot((suffixes[:elb]  or '.elb'))
    @suffixes[:sg]   = Zonify.dot((suffixes[:sg]   or  '.sg'))
  end
  def instances
    @ec2.describe_instances.inject({}) do |acc, i|
      dns = i[:dns_name]
      unless dns.nil? or dns.empty?
        acc[i[:aws_instance_id]] = {:dns => dns, :sg  => i[:aws_groups]}
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
      ['CNAME', "#{id}#{@suffixes[:host]}", info[:dns]]
    end
    elb_records = elbs.map do |elb|
      running = elb[:instances].map{|i| hosts[i] }.compact
      running.map do |host|
        ['TXT', "#{elb[:prefix]}#{@suffixes[:elb]}", "zonify/#{host[:dns]}"]
      end
    end.flatten(1)
    sg_records = hosts.inject({}) do |acc, kv|
      _, info = kv
      info[:sg].each do |sg|
        acc[sg] ||= []
        acc[sg] << info[:dns]
      end
      acc
    end.map do |sg, hostnames|
      sg_ldh = Zonify.sg_name_to_ldh(sg)
      hostnames.map do |hostname|
        ['TXT', "#{sg_ldh}#{@suffixes[:sg]}", "zonify/#{hostname}"]
      end
    end.flatten(1)
    [host_records, elb_records, sg_records].flatten(1)
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

def dot(s)
  s.sub(/^[^.]/, ".#{$1}")
end

end

