# mod_message_status

An ejabberd module for tracking message read and delivery status.

## Overview

This module provides functionality to track and manage message read and delivery status in ejabberd XMPP server. It supports both SQL and Mnesia backends for storing message status information.

## Features

- Track message read status
- Track message delivery status
- Query message status
- Support for both SQL and Mnesia backends
- IQ-based status updates and queries
- Timestamp tracking for all status changes

## Requirements

- ejabberd >= 21.0
- Erlang/OTP

## Installation

### Docker Installation (Recommended)
1. Create modules source directory in your ejabberd container:
   ```bash
   mkdir -p .ejabberd_modules/sources
   ```

2. Copy the module source to the container:
   ```bash
   cp -r mod_message_status .ejabberd_modules/sources/
   ```

3. Check and install the module using ejabberdctl:
   ```bash
   ejabberdctl module_check mod_message_status
   ejabberdctl module_install mod_message_status
   ```

4. Add the module configuration to your ejabberd.yml:
   ```yaml
   modules:
     mod_message_status:
       backend: sql  # or mnesia
       use_cache: true
       cache_size: 1000
       cache_life_time: 3600
   ```

5. Restart your ejabberd container to apply changes:
   ```bash
   docker restart your-ejabberd-container
   ```

## Configuration

Add the following to your `ejabberd.yml` configuration file:

```yaml
modules:
  mod_message_status:
    backend: sql  # or 'mnesia'
    use_cache: true
    cache_size: 1000
    cache_life_time: 3600
```

## Usage

### Marking Messages as Read
```xml
<iq type='set'>
  <mark-read xmlns='urn:xmpp:message-status:0' id='msg_id' from='from_user_jid' to='to_user_jid'>
  </mark-read>
</iq>
```

### Marking Messages as Delivered
```xml
<iq type='set'>
  <mark-delivered xmlns='urn:xmpp:message-status:0' id='msg_id' from='sender_user_jid' to='to_user_jid'>
  </mark-delivered>
</iq>
```

### Querying Message Status
```xml
<iq type='get'>
  <get-status xmlns='urn:xmpp:message-status:0' id='msg_id' jid='sender_user_jid'>
  </get-status>
</iq>
```

## License

This project is licensed under the MIT License - see the [COPYING](COPYING) file for details.

## Author

Bemwa Malak <bemwa.malak10@gmail.com>

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
