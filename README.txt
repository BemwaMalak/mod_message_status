mod_message_status
=================

This module provides message read status tracking functionality for ejabberd.

Features:
- Track read status of messages
- Support for both Mnesia and SQL backends
- IQ-based API for marking messages as read and querying status
- Caching support for better performance

Configuration
------------

Add to ejabberd.yml:

modules:
  mod_message_status:
    backend: mnesia  # or sql
    use_cache: true
    cache_size: 1000
    cache_life_time: 3600

IQ Protocol
----------
Namespace: urn:xmpp:message-status:0

Mark as read:
<iq type='set'>
  <mark-read xmlns='urn:xmpp:message-status:0' 
             id='message-id' 
             from='user@domain' 
             to='recipient@domain'/>
</iq>

Get status:
<iq type='get'>
  <get-status xmlns='urn:xmpp:message-status:0' 
              id='message-id' 
              jid='user@domain'/>
</iq>
