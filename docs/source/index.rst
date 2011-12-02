===========================================
 zonify - create DNS zone from AWS metadata
===========================================

Synopsis
--------

.. code-block:: text

    zonify ... (-h|-[?]|--help)? ...
    zonify ec2 > zone.ec2.yaml
    zonify r53 <domain> > zone.r53.yaml
    zonify ec2/r53 <domain> > changes.yaml
    zonify diff zone.r53.yaml zone.ec2.yaml > changes.yaml
    zonify summarize < changes.yaml
    zonify apply < changes.yaml
    zonify sync (--confirm)?
    zonify resolve <name>+

Description
-----------

The `zonify` tool allows one to create DNS entries for all instances, tags and
load balancers in EC2 and synchronize a Route 53 zone with these entries.

The `zonify` tool and libraries intelligently insert a final and initial ``.``
as needed to conform to DNS conventions. One may enter the domains at the
command line as ``example.com`` or ``example.com.``; it will work either way.

ec2
---

The `ec2` subcommand organizes instances, load balancers and instance metadata
into DNS entries with the generic suffix '.' and writes them to STDOUT as YAML, as described below.

route53
-------

The `r53` subcommand retrieves DNS entries from Route 53 that are under the
given suffix. First, one Route 53 zone is selected which has a name such that:

  * The components of the name, in order, form a suffix of the list of
    components of the domain given as a parameter.

  * The name is the longest such name that matches this criterion.

Then names are listed from the Route 53 zone for which it is true that the
components of the given domain form a suffix of the list of components of the
name.

One consequence of this rule is that if one provides ``com`` as an argument,
nothing will be returned. Although ``com.`` may be a suffix of ones Route 53
zones, one is unlikely to own a zone that is wholly contained in it.

zone.yaml output format
-----------------------

The ``zone.*.yaml`` files contain two entries, ``suffix`` and ``records``, as
in this elided example:

  suffix: .internal.example.com.
  records:
    i-0ABCD123.inst.internal.example.com.:
      CNAME:
        :ttl: 86400
        :resource_records:
        - ec2-86-75-3-09.compute-1.amazonaws.com.
    i-12345678.inst.internal.example.com.:
      CNAME:
        :ttl: 86400
        :resource_records:
        - ec2-9-9-9-9.compute-1.amazonaws.com.
    ...
    secret.sg.internal.example.com.:
      TXT:
        :ttl: 100
        :resource_records:
        - "\"zonify // i-0ABCD123.inst.internal.example.com.\""
        - "\"zonify // i-27248b46.inst.internal.example.com.\""
    ...
    the-app.elb.internal.example.com.:
      TXT:
        :ttl: 100
        :resource_records:
        - "\"zonify // i-0ABCD123.inst.internal.example.com.\""
        - "\"zonify // i-27248b46.inst.internal.example.com.\""
    ...

Examples
--------

.. code-block:: bash

  zonify

