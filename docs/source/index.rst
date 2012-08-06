===========================================
 zonify - create DNS zone from AWS metadata
===========================================

Synopsis
--------

.. code-block:: text

    zonify ... (-h|-[?]|--help) ...
    zonify ec2 <rewrite rules>* > zone.ec2.yaml
    zonify ec2/r53 <domain> <rewrite rules>* > changes.yaml
    zonify r53 <domain> > zone.r53.yaml
    zonify diff zone.r53.yaml zone.ec2.yaml > changes.yaml
    zonify rewrite <rewrite rules>* < zone.ec2.yaml
    zonify summarize < changes.yaml
    zonify apply < changes.yaml
    zonify sync <domain> <rewrite rules>*
    zonify normalize <domain>
    zonify eips

Description
-----------

The `zonify` tool allows one to create DNS entries for all instances, tags and
load balancers in EC2 and synchronize a Route 53 zone with these entries.

The `zonify` tool and libraries intelligently insert a final and initial
``'.'`` as needed to conform to DNS conventions. One may enter the domains at
the command line as ``example.com`` or ``example.com.``; it will work either
way.

For access to AWS APIs, `zonify` uses the the conventional environment
variables to select regions and specify credentials:

.. code-block:: text

    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    EC2_URL

These variables are used by many AWS libraries and tools. As a convenience,
the environment varialbe ``AWS_REGION`` may be used with region nicknames:

.. code-block:: text

    AWS_REGION=eu-west-1

The Zonify subcommands allow staged generation, transformation and auditing of
entries as well as straightforward, one-step synchronization.

  ``ec2`` `(--srv-singleton|--no-srv-singleton)?`
    Organizes instances, load balancers, security groups and instance metadata
    into DNS entries, with the generic suffix '.' (intended to be transformed
    by later commands).

  ``ec2/r53`` `(--types CNAME,SRV)?` `(--srv-singleton|--no-srv-singleton)?`
    Creates a changes file, describing how records under the given suffix
    would be created and deleted to bring it in to sync with EC2. By default,
    only records of type ``CNAME`` and ``SRV`` are examined and changed.

  ``r53``
    Capture all Route 53 records under the given suffix.

  ``diff`` `(--types CNAME,SRV,A,MX,...)?`
    Describe changes (which can be fed to the ``apply`` subcommand) needed to
    bring a Route 53 domain in the first file into sync with domain described
    in the second file. The suffix is taken from the first file. The default
    with ``diff`` (unlike other `zonify` subcommands) is to examine all record
    types.

  ``rewrite`` `(--srv-singleton|--no-srv-singleton)?`
    Apply rewrite rules to the domain file.

  ``summarize``
    Summarize changes in a changes file, writing to STDOUT.

  ``apply``
    Apply a changes file.

  ``sync`` `(--types CNAME,SRV)?` `(--srv-singleton|--no-srv-singleton)?`
    Sync the given domain with EC2. By default, only records of type ``CNAME``
    and ``SRV`` are examined and changed.

  ``normalize``
    Create CNAMEs for SRV records that have only one server in them and rebase
    records on to the given domain.

  ``eips``
    List all Elastic IPs and DNS entries that map to them.

The `--[no-]srv-singleton` options control creation of CNAMEs for singleton
SRV records. They are enabled by default; but it can be useful to disable them
for pre-processing the YAML and then adding them with ``normalize``. For
example:

.. code-block:: bash

  zonify r53 amz.example.com > r53.yaml
  zonify ec2 --no-srv-singleton > ec2.yaml
  my-yaml-rewriter < ec2.yaml > adjusted.yaml
  zonify normalize amz.example.com < adjusted.yaml > normed.yaml
  zonify diff r53.yaml normed.yaml | zonify apply

Sync Policy
-----------

Zonify assumes the domain given on the command line is entirely under the
control of Zonify; records not reflecting the present state of EC2 are
scheduled for deletion in the generated changesets. This can be controlled to
some degree with the `--types` option.

The sync scopes over the domain and not necessarily the entire Route 53 zone.
Say, for example, one has ``example.com`` in a Route 53 zone and one plans to
use ``amz.example.com`` for Amazon instance records.  In this scenario, Zonify
will only specify changes that delete or create records under
``amz.example.com``; ``www.example.com``, ``s0.mobile.example.com`` and
similar records will not be affected.

YAML Output
-----------

All records and change sets are sorted by name on output. The data components
of records are also sorted. This ensures consistent output from run to run;
and allows the diff tool to return meaningful results when outputs are
compared.

One exception to this rule is the r53 subcommand, which preserves the order of
data as it was found in Route 53.

Rewrite Rules
-------------

Rewrite rules take the form ``<domain>(:<domain>)+``. To shorten names under
the ``apache`` security group to ``web.amz.example.com``, use:

.. code-block:: text

  apache.sg:web

To keep both forms, use the rule:

.. code-block:: text

  apache.sg:apache.sg:web

Generated Records and Querying
------------------------------

For records where there are potentially many servers -- security groups, tags,
load balancers -- Zonify creates SRV records. As a convenience, when a SRV
record has only one entry under it, a CNAME is also created.

Records created include:

  ``i-ABCD1234.inst.``
    Individual instances.

  ``_*._*.<value>.<key>.tag.``
    SRV records for tags.

  ``_*._*.<name>.sg.``
    SRV records for security groups.

  ``_*._*.<name>.elb``
    SRV records for instances behind Elastic Load Balancers.

  ``domU-*.priv.``, ``ip-*.priv``
    Records pointing to the default hostname, derived from the private DNS
    entry, set by many AMIs.

A list of all instances is placed under ``inst`` -- continuing with our
example above, this would be the SRV record ``_*._*.inst.amz.example.com``. To
obtain the list of all instances with `dig`:

.. code-block:: bash

  dig @8.8.8.8 +tcp +short _*._*.inst.amz.example.com SRV | cut -d' ' -f4

The `cut` call is necessary to remove some values, always nonces with Zonify,
that are part of standard format SRV records.

Examples
--------

.. code-block:: bash

  # Create records under amz.example.com, with instance names appearing
  # directly under .amz.example.com.
  zone sync amz.example.com name.tag:.
  # Similar to above but stores changes to disk for later application.
  zone ec2/r53 amz.example.com name.tag:. > changes.yaml

