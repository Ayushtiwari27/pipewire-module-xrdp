# Current Code Analysis - What Exists

## Key Functions in module-xrdp.c (Current Implementation)

### Socket Connection Functions (TO BE REMOVED)
- `connect_xrdp_socket()` - Establishes Unix socket connection to chansrv
- `close_send_sink()` - Closes speaker socket
- `close_send_source()` - Closes mic socket
- `socket_read()` - Reads from socket with protocol parsing
- `socket_write()` - Writes to socket with protocol headers

### Stream Callbacks (TO BE MODIFIED)
- `on_sink_process()` - Currently wraps PCM in xrdp protocol and sends via socket
- `on_source_process()` - Currently reads from socket and unwraps protocol

### Module Lifecycle (TO BE MODIFIED)
- `module_init()` - Currently calls connect_xrdp_socket()
- `module_cleanup()` - Currently calls close socket functions

### PipeWire Integration (KEEP MOSTLY AS-IS)
- `create_stream()` - Sets up PipeWire streams
- `stream_state_changed()` - Handles PipeWire state changes
- Module registration and metadata

## Data Structures

### struct impl (Current)
```c
struct impl {
    struct pw_context *context;
    struct pw_stream *sink_stream;
    struct pw_stream *source_stream;
    
    // Audio format
    struct spa_audio_info_raw info;
    uint32_t frame_size;
    
    // xrdp socket (TO BE REPLACED WITH FIFOs)
    int fd_sink;
    int fd_source;
    char *socket_path;
    
    // Protocol state (TO BE REMOVED)
    struct xrdp_proto_state proto;
};
```

## Protocol Messages (TO BE REMOVED)
```c
#define PA_CMD_SEND_DATA 0x01
#define PA_CMD_START_REC 0x02
#define PA_CMD_STOP_REC 0x03

struct xrdp_msg_header {
    uint32_t command;
    uint32_t size;
};
```

These protocol structures are xrdp-specific and will be completely removed.
