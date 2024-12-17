mod_message_status
=================

Message Read Status Module for ejabberd
-------------------------------------

Description:
------------
This module implements message read and delivery status tracking for ejabberd XMPP
server. It allows tracking when messages are delivered and read by recipients,
with support for both SQL and Mnesia backends.

Requirements:
------------
- ejabberd 21.0 or higher
- Erlang/OTP

Installation:
------------
For Docker-based ejabberd installation:

1. Create modules source directory in your ejabberd container:
   mkdir -p .ejabberd_modules/sources

2. Copy the module source to the container:
   cp -r mod_message_status .ejabberd_modules/sources/

3. Check and install the module using ejabberdctl:
   ejabberdctl module_check mod_message_status
   ejabberdctl module_install mod_message_status

4. Add the module configuration to your ejabberd.yml:
   modules:
     mod_message_status:
       backend: sql  # or 'mnesia'

5. Restart your ejabberd container to apply changes:
   docker restart your-ejabberd-container

Configuration:
-------------
Add to ejabberd.yml:

modules:
  mod_message_status:
    backend: sql  # or mnesia
    use_cache: true
    cache_size: 1000
    cache_life_time: 3600

Protocol:
--------
The module implements custom IQ stanzas in the 'urn:xmpp:message-status:0' namespace.

1. Mark as Read:
   <iq type='set'>
     <status xmlns='urn:xmpp:message-status:0' type='read'>
       <message id='[message-id]' jid='[jid]'/>
     </status>
   </iq>

2. Mark as Delivered:
   <iq type='set'>
     <status xmlns='urn:xmpp:message-status:0' type='delivered'>
       <message id='[message-id]' jid='[jid]'/>
     </status>
   </iq>

3. Query Status:
   <iq type='get'>
     <status xmlns='urn:xmpp:message-status:0'>
       <message id='[message-id]' jid='[jid]'/>
     </status>
   </iq>

Features:
--------
- Message read status tracking
- Message delivery status tracking
- Status querying
- Timestamp tracking
- Multiple backend support (SQL/Mnesia)
- IQ-based protocol

Support:
-------
For issues and feature requests, visit:
https://github.com/bemwamalak/mod_message_status

Author:
------
Bemwa Malak <bemwa.malak10@gmail.com>

License:
-------
MIT License - See COPYING file for details
