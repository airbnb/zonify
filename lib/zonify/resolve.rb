
require 'rubygems'
require 'net/dns/resolver'


module Zonify ; end
module Zonify::Resolve

ZNAME = /^zonify \/\/ ([.a-z0-9-]*[.]) *$/

extend self

def resolve(name, opts={})
  recursive = (opts[:recursive] or false)
  fullRR = (opts[:fullRR] or false)
  resolver = Zonify::Resolve.new_resolver
  rrs = resolve_once(name, resolver)
  if opts[:recursive]
    loop do
      partitioned = Zonify::Resolve.partition(rrs)
      rrsTXT = partitioned[Net::DNS::RR::TXT]
      break unless rrsTXT
      partitioned[Net::DNS::RR::TXT] = nil
      pending = partitioned.values.flatten(1).compact
      rrsTXT.each do |rr|
        pending.concat(resolve_once($1, resolver)) if ZNAME.match(rr.txt)
      end
      rrs = pending
    end
  end
  fullRR ? rrs : rrs.map{|rr| Zonify::Resolve.data(rr) }
end

def resolve_once(name, resolver)
  answer = []
  [Net::DNS::TXT, Net::DNS::CNAME, Net::DNS::A].each do |type|
    break unless answer.empty?
    packet = resolver.send(name, type)
    packet.answer.each do |rr|
      case rr
      when Net::DNS::RR::TXT
        answer.push(rr) if ZNAME.match(rr.txt)
      else
        answer.push(rr)
      end
    end
  end
  answer
end

def new_resolver
  resolver = Net::DNS::Resolver.new
  resolver.use_tcp = true # Because of large data size from big TXT records.
  resolver
end

def partition(rrs)
  rrs.inject({}) do |acc, rr|
    acc[rr.class] ||= []
    acc[rr.class]  << rr
    acc
  end
end

def data(rr)
  case rr
  when Net::DNS::RR::TXT
    $1 if ZNAME.match(rr.txt)
  when Net::DNS::RR::A
    rr.address
  when Net::DNS::RR::CNAME
    rr.cname
  end
end

end
