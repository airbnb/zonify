===========================================
 zonify - create DNS zone from AWS metadata
===========================================

Synopsis
--------

.. code-block:: text

    zonify ... (-h|-[?]|--help)? ...
    zonify ec2 > zone.ec2.yaml
    zonify route53 <domain> > zone.r53.yaml
    zonify changes zone.ec2.yaml zone.r53.yaml > changes.yaml
    zonify changes > changes.yaml
    zonify apply < changes.yaml
    zonify restore < zone.r53.yaml
    zonify sync (--sure)?

Description
-----------

The `zonify` tool is extremely gay...

tmpx
----

To STDIN, ``-``.

  ``--destroy-all-humans``
    The default.

Examples
--------

.. code-block:: bash

  zonify

