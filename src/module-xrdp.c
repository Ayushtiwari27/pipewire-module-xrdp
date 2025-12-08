/**
 * xrdp pipewire module
 *
 * This is a modified version of src/modules/module-pipe-tunnel.c
 * from pipewire 0.3.64
 */

/* PipeWire
 *
 * Copyright © 2021 Sanchayan Maity <sanchayan@asymptotic.io>
 * Copyright © 2022 Wim Taymans
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice (including the next
 * paragraph) shall be included in all copies or substantial portions of the
 * Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <signal.h>
#include <limits.h>
#include <math.h>
#include <time.h>

#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/un.h>

#include <spa/utils/result.h>
#include <spa/utils/string.h>
#include <spa/utils/json.h>
#include <spa/utils/ringbuffer.h>
#include <spa/utils/dll.h>
#include <spa/debug/types.h>
#include <spa/pod/builder.h>
#include <spa/param/audio/format-utils.h>
#include <spa/param/latency-utils.h>
#include <spa/param/audio/raw.h>

#include <pipewire/impl.h>
#include <pipewire/i18n.h>

/** \page page_module_pipe_tunnel PipeWire Module: Unix Pipe Tunnel
 *
 * The pipe-tunnel module provides a source or sink that tunnels all audio to
 * a unix pipe.
 *
 * ## Module Options
 *
 * - `tunnel.mode`: the desired tunnel to create. (Default `playback`)
 * - `pipe.filename`: the filename of the pipe.
 * - `stream.props`: Extra properties for the local stream.
 *
 * When `tunnel.mode` is `capture`, a capture stream on the default source is
 * created. Samples read from the pipe will be the contents of the captured source.
 *
 * When `tunnel.mode` is `sink`, a sink node is created. Samples read from the
 * pipe will be the samples played on the sink.
 *
 * When `tunnel.mode` is `playback`, a playback stream on the default sink is
 * created. Samples written to the pipe will be played on the sink.
 *
 * When `tunnel.mode` is `source`, a source node is created. Samples written to
 * the pipe will be made available to streams connected to the source.
 *
 * When `pipe.filename` is not given, a default fifo in `/tmp/fifo_input` or
 * `/tmp/fifo_output` will be created that can be written and read respectively,
 * depending on the selected `tunnel.mode`.
 *
 * ## General options
 *
 * Options with well-known behavior.
 *
 * - \ref PW_KEY_REMOTE_NAME
 * - \ref PW_KEY_AUDIO_FORMAT
 * - \ref PW_KEY_AUDIO_RATE
 * - \ref PW_KEY_AUDIO_CHANNELS
 * - \ref SPA_KEY_AUDIO_POSITION
 * - \ref PW_KEY_NODE_LATENCY
 * - \ref PW_KEY_NODE_NAME
 * - \ref PW_KEY_NODE_DESCRIPTION
 * - \ref PW_KEY_NODE_GROUP
 * - \ref PW_KEY_NODE_VIRTUAL
 * - \ref PW_KEY_MEDIA_CLASS
 * - \ref PW_KEY_TARGET_OBJECT to specify the remote name or serial id to link to
 *
 * When not otherwise specified, the pipe will accept or produce a
 * 16 bits, stereo, 48KHz sample stream.
 *
 * ## Example configuration of a pipe playback stream
 *
 *\code{.unparsed}
 * context.modules = [
 * {   name = libpipewire-module-pipe-tunnel
 *     args = {
 *         tunnel.mode = playback
 *         # Set the pipe name to tunnel to
 *         pipe.filename = "/tmp/fifo_output"
 *         #audio.format=<sample format>
 *         #audio.rate=<sample rate>
 *         #audio.channels=<number of channels>
 *         #audio.position=<channel map>
 *         #target.object=<remote target node>
 *         stream.props = {
 *             # extra sink properties
 *         }
 *     }
 * }
 * ]
 *\endcode
 */

#define NAME "xrdp"

#define DEFAULT_FORMAT "S16"
#define DEFAULT_RATE 44100
#define DEFAULT_CHANNELS 2
#define DEFAULT_POSITION "[ FL FR ]"

/* FIFO paths - can be overridden by environment variables */
#define DEFAULT_SPEAKER_FIFO_NAME "xrdp_spk.pcm"
#define DEFAULT_MIC_FIFO_NAME "xrdp_mic.pcm"
#define DEFAULT_FORMAT_FILE_NAME "xrdp_audio_format.txt"

PW_LOG_TOPIC_STATIC(mod_topic, "mod." NAME);
#define PW_LOG_TOPIC_DEFAULT mod_topic

#define MODULE_USAGE	"[ remote.name=<remote> ] "				\
			"[ sink.node.latency=<latency for sink> ] "		\
			"[ target.object=<remote node target name> ] "		\
			"[ audio.format=<sample format> ] "			\
			"[ audio.rate=<sample rate> ] "				\
			"[ audio.channels=<number of channels> ] "		\
			"[ audio.position=<channel map> ] "			\
			"[ sink.stream.props=<properties for sink> ] "		\
			"[ source.stream.props=<properties for source> ] "


static const struct spa_dict_item module_props[] = {
	{ PW_KEY_MODULE_AUTHOR, "Wim Taymans <wim.taymans@gmail.com>" },
	{ PW_KEY_MODULE_DESCRIPTION, "Create a xrdp pipewire interface" },
	{ PW_KEY_MODULE_USAGE, MODULE_USAGE },
	{ PW_KEY_MODULE_VERSION, pw_get_headers_version() },
};

struct impl {
	struct pw_context *context;  // common
	uint32_t destroy_work_id;  // common

#define MODE_XRDP_SINK		1
#define MODE_XRDP_SOURCE	2
#define MODE_BOTH	(MODE_XRDP_SINK | MODE_XRDP_SOURCE)
	uint32_t mode;
	struct pw_properties *props_sink;
	struct pw_properties *props_source;

	struct pw_impl_module *module;  // common

	struct spa_hook module_listener;  // common

	struct pw_core *core;  // common
	struct spa_hook core_proxy_listener;  // common
	struct spa_hook core_listener;  // common

	char *filename_sink;        // Speaker FIFO path
	char *filename_source;      // Mic FIFO path
	char *format_file_path;     // Format specification file path
	int fd_sink;                // Speaker FIFO fd
	int fd_source;              // Mic FIFO fd
	time_t last_format_write;   // Throttle format file writes

	struct pw_properties *stream_props_sink;
	struct pw_properties *stream_props_source;
	struct pw_stream *stream_sink;
	struct pw_stream *stream_source;
	struct spa_hook stream_listener_sink;
	struct spa_hook stream_listener_source;
	struct spa_audio_info_raw info;  // common
	uint32_t frame_size;  // only source

	unsigned int do_disconnect:1;  // common
	uint32_t leftover_count;  // only source
	uint8_t *leftover;  // only source

	unsigned int unloading:1;  // common
	struct pw_work_queue *work;  // common
	int display_num; // for debug
};

static void do_unload_module(void *obj, void *data, int res, uint32_t id)
{
	struct impl *impl = data;
	pw_impl_module_destroy(impl->module);
}

static void unload_module(struct impl *impl)
{
	if (!impl->unloading) {
		impl->unloading = true;
		pw_work_queue_add(impl->work, impl, 0, do_unload_module, impl);
	}
}

static void stream_destroy_sink(void *d)
{
	struct impl *impl = d;
	spa_hook_remove(&impl->stream_listener_sink);
	impl->stream_sink = NULL;
}

static void stream_destroy_source(void *d)
{
	struct impl *impl = d;
	spa_hook_remove(&impl->stream_listener_source);
	impl->stream_source = NULL;
}

static void set_fifo_paths(struct impl *impl) {
	uid_t uid = getuid();
	char default_path[256];

	/* Get speaker FIFO path */
	const char *spk_path = getenv("XRDP_AUDIO_SPK_FIFO");
	if (spk_path && spk_path[0] != '\0') {
		impl->filename_sink = strdup(spk_path);
	} else {
		snprintf(default_path, sizeof(default_path), "/run/user/%d/%s", uid, DEFAULT_SPEAKER_FIFO_NAME);
		impl->filename_sink = strdup(default_path);
	}

	/* Get microphone FIFO path */
	const char *mic_path = getenv("XRDP_AUDIO_MIC_FIFO");
	if (mic_path && mic_path[0] != '\0') {
		impl->filename_source = strdup(mic_path);
	} else {
		snprintf(default_path, sizeof(default_path), "/run/user/%d/%s", uid, DEFAULT_MIC_FIFO_NAME);
		impl->filename_source = strdup(default_path);
	}

	/* Get format file path */
	const char *fmt_path = getenv("XRDP_AUDIO_FORMAT_FILE");
	if (fmt_path && fmt_path[0] != '\0') {
		impl->format_file_path = strdup(fmt_path);
	} else {
		snprintf(default_path, sizeof(default_path), "/run/user/%d/%s", uid, DEFAULT_FORMAT_FILE_NAME);
		impl->format_file_path = strdup(default_path);
	}

	pw_log_info("FIFO paths: speaker=%s, mic=%s, format=%s",
		impl->filename_sink, impl->filename_source, impl->format_file_path);
}

static int open_fifo(const char *path, int flags, mode_t mode) {
    struct stat st;
    int fd;
    
    /* Check if FIFO exists */
    if (stat(path, &st) < 0) {
        if (errno == ENOENT) {
            /* FIFO doesn't exist, create it */
            if (mkfifo(path, mode) < 0) {
                pw_log_error("Failed to create FIFO %s: %s", path, strerror(errno));
                return -1;
            }
            pw_log_info("Created FIFO: %s", path);
        } else {
            pw_log_error("stat %s failed: %s", path, strerror(errno));
            return -1;
        }
    } else if (!S_ISFIFO(st.st_mode)) {
        /* File exists but is not a FIFO */
        pw_log_warn("%s exists but is not a FIFO, recreating", path);
        unlink(path);
        if (mkfifo(path, mode) < 0) {
            pw_log_error("Failed to recreate FIFO %s: %s", path, strerror(errno));
            return -1;
        }
    }
    
    /* Try to open with O_NONBLOCK */
    fd = open(path, flags | O_NONBLOCK);
    
    if (fd < 0) {
        if (errno == ENXIO) {
            /* No reader/writer on the other end - this is EXPECTED and OK */
            pw_log_info("FIFO %s: no peer connected yet (will retry later)", path);
            
            /* Return a special code to indicate "not ready yet" vs "fatal error" */
            /* We'll use -ENXIO to distinguish from -1 */
            return -ENXIO;
        }
        
        /* Other errors are real problems */
        pw_log_error("Failed to open FIFO %s: %s", path, strerror(errno));
        return -1;
    }
    
    pw_log_info("Successfully opened FIFO: %s (fd=%d)", path, fd);
    return fd;
}
static int open_speaker_fifo(struct impl *impl) {
	if (impl->fd_sink >= 0) {
		return 0; /* Already open */
	}

	impl->fd_sink = open_fifo(impl->filename_sink, O_WRONLY, 0666);
	if (impl->fd_sink == -ENXIO) {
	    /* No reader yet - this is OK, we'll retry later */
	    pw_log_info("Speaker FIFO not ready yet, will open on first use");
	    impl->fd_sink = -1;  /* Mark as not open */
	    /* Continue with module init! Don't fail here! */
	} else if (impl->fd_sink < 0) {
	    /* Fatal error */
	    pw_log_error("Failed to open speaker FIFO");
	}
	return 0;
}

static int open_mic_fifo(struct impl *impl) {
	if (impl->fd_source >= 0) {
		return 0; /* Already open */
	}
	impl->fd_source = open_fifo(impl->filename_source, O_RDONLY, 0666);
	if (impl->fd_source == -ENXIO) {
	    pw_log_info("Mic FIFO not ready yet, will open on first use");
	    impl->fd_source = -1;
	    /* Continue! */
	} else if (impl->fd_source < 0) {
	    pw_log_error("Failed to open mic FIFO");
	}
	return 0;
}

static void close_fifos(struct impl *impl) {
	if (impl->fd_sink >= 0) {
		close(impl->fd_sink);
		impl->fd_sink = -1;
		pw_log_info("Closed speaker FIFO");
	}

	if (impl->fd_source >= 0) {
		close(impl->fd_source);
		impl->fd_source = -1;
		pw_log_info("Closed mic FIFO");
	}

	/* Clean up FIFO files */
	if (impl->filename_sink) {
		unlink(impl->filename_sink);
	}
	if (impl->filename_source) {
		unlink(impl->filename_source);
	}
}

static int reconnect_fifo(struct impl *impl, int is_sink) {
	if (is_sink) {
		if (impl->fd_sink >= 0) {
			close(impl->fd_sink);
			impl->fd_sink = -1;
		}
		pw_log_info("Reconnecting speaker FIFO...");
		return open_speaker_fifo(impl);
	} else {
		if (impl->fd_source >= 0) {
			close(impl->fd_source);
			impl->fd_source = -1;
		}
		pw_log_info("Reconnecting mic FIFO...");
		return open_mic_fifo(impl);
	}
}

static void stream_state_changed_sink(void *d, enum pw_stream_state old,
		enum pw_stream_state state, const char *error)
{
	struct impl *impl = d;
	switch (state) {
	case PW_STREAM_STATE_ERROR:
	case PW_STREAM_STATE_UNCONNECTED:
		unload_module(impl);
		break;
	case PW_STREAM_STATE_PAUSED:
		/* FIFO will be closed in impl_destroy */
		break;
	case PW_STREAM_STATE_STREAMING:
		break;
	default:
		break;
	}
    pw_log_debug("stream_state_changed:%s", pw_stream_state_as_string (state));
}

static void stream_state_changed_source(void *d, enum pw_stream_state old,
		enum pw_stream_state state, const char *error)
{
	struct impl *impl = d;
	switch (state) {
	case PW_STREAM_STATE_ERROR:
	case PW_STREAM_STATE_UNCONNECTED:
		unload_module(impl);
		break;
	case PW_STREAM_STATE_PAUSED:
		/* FIFO will be closed in impl_destroy */
		break;
	case PW_STREAM_STATE_STREAMING:
		break;
	default:
		break;
	}
    pw_log_debug("stream_state_changed:%s", pw_stream_state_as_string (state));
}

static void playback_stream_process(void *data)
{
	struct impl *impl = data;
	struct pw_buffer *buf;
	struct spa_data *d;
	uint32_t size, offset;
	ssize_t written;

	if ((buf = pw_stream_dequeue_buffer(impl->stream_sink)) == NULL) {
		pw_log_debug("out of buffers: %m");
		return;
	}

	/* Try to open FIFO if not already open */
	if (impl->fd_sink < 0) {
		if (open_speaker_fifo(impl) < 0) {
			/* Can't write without FIFO, just drop the data */
			pw_log_trace("Speaker FIFO not ready, dropping audio");
			goto done;
		}
	}

	/* Write all data buffers to FIFO */
	for (uint32_t i = 0; i < buf->buffer->n_datas; i++) {
		d = &buf->buffer->datas[i];

		offset = SPA_MIN(d->chunk->offset, d->maxsize);
		size = SPA_MIN(d->chunk->size, d->maxsize - offset);

		if (size == 0)
			continue;

		written = write(impl->fd_sink, SPA_PTROFF(d->data, offset, void), size);

		if (written < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				/* FIFO full, drop the frame */
				pw_log_trace("Speaker FIFO full (EAGAIN), dropping %u bytes", size);
			} else if (errno == EPIPE) {
				/* Broken pipe, try to reconnect */
				pw_log_warn("Speaker FIFO broken pipe, reconnecting...");
				if (reconnect_fifo(impl, 1) < 0) {
					pw_log_warn("Failed to reconnect speaker FIFO");
				}
			} else {
				pw_log_error("Error writing to speaker FIFO: %s", strerror(errno));
			}
		} else if (written != (ssize_t)size) {
			pw_log_warn("Partial write to speaker FIFO: %zd/%u bytes", written, size);
		}
	}

done:
	pw_stream_queue_buffer(impl->stream_sink, buf);
}

static void capture_stream_process(void *data)
{
	struct impl *impl = data;
	struct pw_buffer *buf;
	struct spa_data *d;
	uint32_t req;
	ssize_t nread;

	if ((buf = pw_stream_dequeue_buffer(impl->stream_source)) == NULL) {
		pw_log_debug("out of buffers: %m");
		return;
	}

	d = &buf->buffer->datas[0];

	if ((req = buf->requested * impl->frame_size) == 0)
		req = 4096 * impl->frame_size;

	req = SPA_MIN(req, d->maxsize);

	d->chunk->offset = 0;
	d->chunk->stride = impl->frame_size;
	d->chunk->size = 0;

	/* Try to open FIFO if not already open */
	if (impl->fd_source < 0) {
		if (open_mic_fifo(impl) < 0) {
			/* Can't read without FIFO, fill with silence */
			pw_log_trace("Mic FIFO not ready, filling with silence");
			d->chunk->size = req;
			memset(d->data, 0, req);
			goto done;
		}
	}

	/* Read from mic FIFO */
	nread = read(impl->fd_source, d->data, req);

	if (nread < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK) {
			/* No data available, fill with silence */
			pw_log_trace("Mic FIFO empty (EAGAIN), filling with silence");
			d->chunk->size = req;
			memset(d->data, 0, req);
		} else if (errno == EPIPE) {
			/* Broken pipe, try to reconnect */
			pw_log_warn("Mic FIFO broken pipe, reconnecting...");
			if (reconnect_fifo(impl, 0) < 0) {
				pw_log_warn("Failed to reconnect mic FIFO");
			}
			/* Fill with silence for this buffer */
			d->chunk->size = req;
			memset(d->data, 0, req);
		} else {
			pw_log_error("Error reading from mic FIFO: %s", strerror(errno));
			d->chunk->size = req;
			memset(d->data, 0, req);
		}
	} else if (nread == 0) {
		/* EOF, fill with silence */
		pw_log_trace("Mic FIFO EOF, filling with silence");
		d->chunk->size = req;
		memset(d->data, 0, req);
	} else {
		/* Got some data */
		d->chunk->size = nread;

		/* If we got less than requested, pad with silence */
		if ((uint32_t)nread < req) {
			memset(SPA_PTROFF(d->data, nread, void), 0, req - nread);
			d->chunk->size = req;
		}
	}

done:
	pw_stream_queue_buffer(impl->stream_source, buf);
}

/* Forward declarations */
static int calc_frame_size(const struct spa_audio_info_raw *info);
static const char *format_to_string(uint32_t format);
static void write_format_spec(struct impl *impl);

static void on_stream_param_changed(void *data, uint32_t id, const struct spa_pod *param)
{
	struct impl *impl = data;
	struct spa_audio_info_raw info;
	int res;

	if (param == NULL || id != SPA_PARAM_Format)
		return;

	if ((res = spa_format_audio_raw_parse(param, &info)) < 0) {
		pw_log_error("Failed to parse format: %s", spa_strerror(res));
		return;
	}

	/* Update format info */
	impl->info = info;
	impl->frame_size = calc_frame_size(&impl->info);

	pw_log_info("Format changed: rate=%u, channels=%u, format=%s",
		impl->info.rate, impl->info.channels, format_to_string(impl->info.format));

	/* Write format specification file for external processes */
	write_format_spec(impl);
}

static const struct pw_stream_events playback_stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.destroy = stream_destroy_sink,
	.state_changed = stream_state_changed_sink,
	.process = playback_stream_process,
	.param_changed = on_stream_param_changed
};

static const struct pw_stream_events capture_stream_events = {
	PW_VERSION_STREAM_EVENTS,
	.destroy = stream_destroy_source,
	.state_changed = stream_state_changed_source,
	.process = capture_stream_process,
	.param_changed = on_stream_param_changed
};

static int create_stream(struct impl *impl)
{
	int res;
	uint32_t n_params;
	const struct spa_pod *params[1];
	uint8_t buffer[1024];
	struct spa_pod_builder b;

	// sink
	if (impl->mode & MODE_XRDP_SINK) {
		impl->stream_sink = pw_stream_new(impl->core, "xrdp-sink", impl->stream_props_sink);
		impl->stream_props_sink = NULL;

		if (impl->stream_sink == NULL)
			return -errno;

		pw_stream_add_listener(impl->stream_sink,
				&impl->stream_listener_sink,
				&playback_stream_events, impl);
	}

	//source
	if (impl->mode & MODE_XRDP_SOURCE) {
		impl->stream_source = pw_stream_new(impl->core, "xrdp-source", impl->stream_props_source);
		impl->stream_props_source = NULL;

		if (impl->stream_source == NULL)
			return -errno;

		pw_stream_add_listener(impl->stream_source,
				&impl->stream_listener_source,
				&capture_stream_events, impl);
	}

	/* Build format enumeration with current format */
	n_params = 0;
	spa_pod_builder_init(&b, buffer, sizeof(buffer));

	/* Use the format info that was already parsed */
	params[n_params++] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &impl->info);

	/* After initial connection, write format spec */
	write_format_spec(impl);

	if (impl->mode & MODE_XRDP_SINK) {
		if ((res = pw_stream_connect(impl->stream_sink,
				PW_DIRECTION_INPUT,
				PW_ID_ANY,
				PW_STREAM_FLAG_AUTOCONNECT |
				PW_STREAM_FLAG_MAP_BUFFERS |
				PW_STREAM_FLAG_RT_PROCESS,
				params, n_params)) < 0)
			return res;
	}

	if (impl->mode & MODE_XRDP_SOURCE) {
		if ((res = pw_stream_connect(impl->stream_source,
				PW_DIRECTION_OUTPUT,
				PW_ID_ANY,
				PW_STREAM_FLAG_AUTOCONNECT |
				PW_STREAM_FLAG_MAP_BUFFERS |
				PW_STREAM_FLAG_RT_PROCESS,
				params, n_params)) < 0)
			return res;
	}

	return 0;
}

static void core_error(void *data, uint32_t id, int seq, int res, const char *message)
{
	struct impl *impl = data;

	pw_log_error("error id:%u seq:%d res:%d (%s): %s",
			id, seq, res, spa_strerror(res), message);

	if (id == PW_ID_CORE && res == -EPIPE)
		//pw_impl_module_schedule_destroy(impl->module);
		unload_module(impl);
}

static const struct pw_core_events core_events = {
	PW_VERSION_CORE_EVENTS,
	.error = core_error,
};

static void core_destroy(void *d)
{
	struct impl *impl = d;
	spa_hook_remove(&impl->core_listener);
	impl->core = NULL;
	//pw_impl_module_schedule_destroy(impl->module);
	unload_module(impl);
}

static const struct pw_proxy_events core_proxy_events = {
	.destroy = core_destroy,
};

static void impl_destroy(struct impl *impl)
{
	/* Close FIFOs and clean up FIFO files */
	close_fifos(impl);

	if (impl->stream_sink)
		pw_stream_destroy(impl->stream_sink);
	if (impl->core && impl->do_disconnect)
		pw_core_disconnect(impl->core);

	if (impl->filename_sink) {
		free(impl->filename_sink);
		impl->filename_sink = NULL;
	}

	pw_properties_free(impl->stream_props_sink);
	pw_properties_free(impl->props_sink);

	if (impl->stream_source)
		pw_stream_destroy(impl->stream_source);

	if (impl->filename_source) {
		free(impl->filename_source);
		impl->filename_source = NULL;
	}

	if (impl->format_file_path) {
		/* Clean up format file */
		unlink(impl->format_file_path);
		free(impl->format_file_path);
		impl->format_file_path = NULL;
	}

	pw_properties_free(impl->stream_props_source);
	pw_properties_free(impl->props_source);

	free(impl->leftover);
	free(impl);
}

static void module_destroy(void *data)
{
	struct impl *impl = data;
	spa_hook_remove(&impl->module_listener);
	impl_destroy(impl);
}

static const struct pw_impl_module_events module_events = {
	PW_VERSION_IMPL_MODULE_EVENTS,
	.destroy = module_destroy,
};

static uint32_t channel_from_name(const char *name)
{
	int i;
	for (i = 0; spa_type_audio_channel[i].name; i++) {
		if (spa_streq(name, spa_debug_type_short_name(spa_type_audio_channel[i].name)))
			return spa_type_audio_channel[i].type;
	}
	return SPA_AUDIO_CHANNEL_UNKNOWN;
}

static void parse_position(struct spa_audio_info_raw *info, const char *val, size_t len)
{
	struct spa_json it[2];
	char v[256];

	spa_json_init(&it[0], val, len);
        if (spa_json_enter_array(&it[0], &it[1]) <= 0)
                spa_json_init(&it[1], val, len);

	info->channels = 0;
	while (spa_json_get_string(&it[1], v, sizeof(v)) > 0 &&
	    info->channels < SPA_AUDIO_MAX_CHANNELS) {
		info->position[info->channels++] = channel_from_name(v);
	}
}

static inline uint32_t format_from_name(const char *name, size_t len)
{
	int i;
	for (i = 0; spa_type_audio_format[i].name; i++) {
		if (strncmp(name, spa_debug_type_short_name(spa_type_audio_format[i].name), len) == 0)
			return spa_type_audio_format[i].type;
	}
	return SPA_AUDIO_FORMAT_UNKNOWN;
}

static const char *format_to_string(uint32_t format)
{
	switch (format) {
	case SPA_AUDIO_FORMAT_S16:
	case SPA_AUDIO_FORMAT_S16_OE:
		return "s16le";
	case SPA_AUDIO_FORMAT_S24:
	case SPA_AUDIO_FORMAT_S24_OE:
		return "s24le";
	case SPA_AUDIO_FORMAT_S32:
	case SPA_AUDIO_FORMAT_S32_OE:
		return "s32le";
	case SPA_AUDIO_FORMAT_F32:
	case SPA_AUDIO_FORMAT_F32_OE:
		return "f32le";
	default:
		return "s16le";  /* fallback */
	}
}

static void parse_audio_info(const struct pw_properties *props, struct spa_audio_info_raw *info)
{
	const char *str;

	spa_zero(*info);
	if ((str = pw_properties_get(props, PW_KEY_AUDIO_FORMAT)) == NULL)
		str = DEFAULT_FORMAT;
	info->format = format_from_name(str, strlen(str));

	info->rate = pw_properties_get_uint32(props, PW_KEY_AUDIO_RATE, info->rate);
	if (info->rate == 0)
		info->rate = DEFAULT_RATE;

	info->channels = pw_properties_get_uint32(props, PW_KEY_AUDIO_CHANNELS, info->channels);
	info->channels = SPA_MIN(info->channels, SPA_AUDIO_MAX_CHANNELS);
	if ((str = pw_properties_get(props, SPA_KEY_AUDIO_POSITION)) != NULL)
		parse_position(info, str, strlen(str));
	if (info->channels == 0)
		parse_position(info, DEFAULT_POSITION, strlen(DEFAULT_POSITION));
}

static int calc_frame_size(const struct spa_audio_info_raw *info)
{
	int res = info->channels;
	switch (info->format) {
	case SPA_AUDIO_FORMAT_U8:
	case SPA_AUDIO_FORMAT_S8:
	case SPA_AUDIO_FORMAT_ALAW:
	case SPA_AUDIO_FORMAT_ULAW:
		return res;
	case SPA_AUDIO_FORMAT_S16:
	case SPA_AUDIO_FORMAT_S16_OE:
	case SPA_AUDIO_FORMAT_U16:
		return res * 2;
	case SPA_AUDIO_FORMAT_S24:
	case SPA_AUDIO_FORMAT_S24_OE:
	case SPA_AUDIO_FORMAT_U24:
		return res * 3;
	case SPA_AUDIO_FORMAT_S24_32:
	case SPA_AUDIO_FORMAT_S24_32_OE:
	case SPA_AUDIO_FORMAT_S32:
	case SPA_AUDIO_FORMAT_S32_OE:
	case SPA_AUDIO_FORMAT_U32:
	case SPA_AUDIO_FORMAT_U32_OE:
	case SPA_AUDIO_FORMAT_F32:
	case SPA_AUDIO_FORMAT_F32_OE:
		return res * 4;
	case SPA_AUDIO_FORMAT_F64:
	case SPA_AUDIO_FORMAT_F64_OE:
		return res * 8;
	default:
		return 0;
	}
}

static void copy_props(struct pw_properties *stream_props, struct pw_properties *props, const char *key)
{
	const char *str;
	if ((str = pw_properties_get(props, key)) != NULL) {
		if (pw_properties_get(stream_props, key) == NULL)
			pw_properties_set(stream_props, key, str);
	}
}

static void write_format_spec(struct impl *impl)
{
	FILE *f;
	time_t now = time(NULL);

	/* Throttle format file writes to max once per 2 seconds */
	if (impl->last_format_write > 0 && (now - impl->last_format_write) < 2) {
		pw_log_debug("Skipping format file write (throttled)");
		return;
	}

	if (!impl->format_file_path) {
		pw_log_warn("Format file path not set");
		return;
	}

	f = fopen(impl->format_file_path, "w");
	if (!f) {
		pw_log_error("Failed to open format file %s: %s",
			impl->format_file_path, strerror(errno));
		return;
	}

	fprintf(f, "# XRDP Audio Format Specification\n");
	fprintf(f, "# Auto-generated by pipewire-module-xrdp\n");
	fprintf(f, "speaker_rate=%u\n", impl->info.rate);
	fprintf(f, "speaker_channels=%u\n", impl->info.channels);
	fprintf(f, "speaker_format=%s\n", format_to_string(impl->info.format));
	fprintf(f, "mic_rate=%u\n", impl->info.rate);
	fprintf(f, "mic_channels=%u\n", impl->info.channels);
	fprintf(f, "mic_format=%s\n", format_to_string(impl->info.format));
	fprintf(f, "timestamp=%ld\n", (long)now);

	fclose(f);
	impl->last_format_write = now;

	pw_log_info("Wrote format spec: rate=%u, channels=%u, format=%s",
		impl->info.rate, impl->info.channels, format_to_string(impl->info.format));
}

SPA_EXPORT
int pipewire__module_init(struct pw_impl_module *module, const char *args)
{
	struct pw_context *context = pw_impl_module_get_context(module);
	struct pw_properties *props = NULL;
	struct impl *impl;
	const char *str;
	int res;

	PW_LOG_TOPIC_INIT(mod_topic);

	impl = calloc(1, sizeof(struct impl));
	if (impl == NULL)
		return -errno;

	impl->fd_sink = -1;
	impl->fd_source = -1;
	impl->filename_sink = NULL;
	impl->filename_source = NULL;
	impl->format_file_path = NULL;
	impl->last_format_write = 0;

	impl->module = module;
	impl->context = context;
	impl->work = pw_context_get_work_queue(context);

	pw_log_debug("module %p: new %s", impl, args);

	if (args == NULL)
		args = "";

	props = pw_properties_new_string(args);
	if (props == NULL) {
		res = -errno;
		pw_log_error( "can't create properties: %m");
		goto error;
	}
	impl->props_sink = props;

	impl->stream_props_sink = pw_properties_new(NULL, NULL);
	if (impl->stream_props_sink == NULL) {
		res = -errno;
		pw_log_error( "can't create properties: %m");
		goto error;
	}

	// sink
	if (pw_properties_get(props, PW_KEY_NODE_VIRTUAL) == NULL)
		pw_properties_set(props, PW_KEY_NODE_VIRTUAL, "true");
	if (pw_properties_get(props, PW_KEY_NODE_NETWORK) == NULL)
		pw_properties_set(props, PW_KEY_NODE_NETWORK, "true");
	if (pw_properties_get(props, PW_KEY_MEDIA_CLASS) == NULL)
		pw_properties_set(props, PW_KEY_MEDIA_CLASS, "Audio/Sink");

	if ((str = pw_properties_get(props, "sink.stream.props")) != NULL) {
		impl->mode |= MODE_XRDP_SINK;
		pw_properties_update_string(impl->stream_props_sink, str, strlen(str));
	}
	pw_properties_set(impl->stream_props_sink, "object.register", "true");
	pw_properties_set(impl->stream_props_sink, PW_KEY_NODE_NAME, "xrdp-sink");
	pw_properties_set(impl->stream_props_sink, PW_KEY_NODE_DESCRIPTION, "XRDP Audio Output");
	copy_props(impl->stream_props_sink, props, PW_KEY_AUDIO_FORMAT);
	copy_props(impl->stream_props_sink, props, PW_KEY_AUDIO_RATE);
	copy_props(impl->stream_props_sink, props, PW_KEY_AUDIO_CHANNELS);
	copy_props(impl->stream_props_sink, props, SPA_KEY_AUDIO_POSITION);
//	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_NAME);
//	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_DESCRIPTION);
	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_GROUP);
//	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_LATENCY);
	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_VIRTUAL);
	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_NETWORK);
	copy_props(impl->stream_props_sink, props, PW_KEY_MEDIA_CLASS);

	parse_audio_info(impl->stream_props_sink, &impl->info);

	if (impl->info.rate != 0 &&
	    pw_properties_get(props, PW_KEY_NODE_RATE) == NULL)
		pw_properties_setf(props, PW_KEY_NODE_RATE,
				"1/%u", impl->info.rate);

	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_RATE);

	if ((str = pw_properties_get(props, "sink.node.latency")) != NULL)
		pw_properties_setf(props, PW_KEY_NODE_LATENCY,	"%s/%u", str, impl->info.rate);
	copy_props(impl->stream_props_sink, props, PW_KEY_NODE_LATENCY);

	// source
	props = pw_properties_new_string(args);
	if (props == NULL) {
		res = -errno;
		pw_log_error( "can't create properties: %m");
		goto error;
	}
	impl->props_source = props;

	impl->stream_props_source = pw_properties_new(NULL, NULL);
	if (impl->stream_props_source == NULL) {
		res = -errno;
		pw_log_error( "can't create properties: %m");
		goto error;
	}

	if (pw_properties_get(props, PW_KEY_NODE_VIRTUAL) == NULL)
		pw_properties_set(props, PW_KEY_NODE_VIRTUAL, "true");
	if (pw_properties_get(props, PW_KEY_NODE_NETWORK) == NULL)
		pw_properties_set(props, PW_KEY_NODE_NETWORK, "true");
	if (pw_properties_get(props, PW_KEY_MEDIA_CLASS) == NULL)
		pw_properties_set(props, PW_KEY_MEDIA_CLASS, "Audio/Source");

	if ((str = pw_properties_get(props, "source.stream.props")) != NULL) {
		impl->mode |= MODE_XRDP_SOURCE;
		pw_properties_update_string(impl->stream_props_source, str, strlen(str));
	}
	pw_properties_set(impl->stream_props_source, "object.register", "true");
	pw_properties_set(impl->stream_props_source, PW_KEY_NODE_NAME, "xrdp-source");
	pw_properties_set(impl->stream_props_source, PW_KEY_NODE_DESCRIPTION, "XRDP Audio Input");
	copy_props(impl->stream_props_source, props, PW_KEY_AUDIO_FORMAT);
	copy_props(impl->stream_props_source, props, PW_KEY_AUDIO_RATE);
	copy_props(impl->stream_props_source, props, PW_KEY_AUDIO_CHANNELS);
	copy_props(impl->stream_props_source, props, SPA_KEY_AUDIO_POSITION);
//	copy_props(impl->stream_props_source, props, PW_KEY_NODE_NAME);
//	copy_props(impl->stream_props_source, props, PW_KEY_NODE_DESCRIPTION);
	copy_props(impl->stream_props_source, props, PW_KEY_NODE_GROUP);
	copy_props(impl->stream_props_source, props, PW_KEY_NODE_LATENCY);
	copy_props(impl->stream_props_source, props, PW_KEY_NODE_VIRTUAL);
	copy_props(impl->stream_props_source, props, PW_KEY_NODE_NETWORK);
	copy_props(impl->stream_props_source, props, PW_KEY_MEDIA_CLASS);

	parse_audio_info(impl->stream_props_source, &impl->info);

	impl->frame_size = calc_frame_size(&impl->info);
	if (impl->frame_size == 0) {
		pw_log_error("unsupported audio format:%d channels:%d",
				impl->info.format, impl->info.channels);
		res = -EINVAL;
		goto error;
	}
	if (impl->info.rate != 0 &&
	    pw_properties_get(props, PW_KEY_NODE_RATE) == NULL)
		pw_properties_setf(props, PW_KEY_NODE_RATE,
				"1/%u", impl->info.rate);

	copy_props(impl->stream_props_source, props, PW_KEY_NODE_RATE);

	impl->leftover = calloc(1, impl->frame_size);
	if (impl->leftover == NULL) {
		res = -errno;
		pw_log_error("can't alloc leftover buffer: %m");
		goto error;
	}

	if (!impl->mode) {
		res = -EINVAL;
		goto error;
	}

	impl->core = pw_context_get_object(impl->context, PW_TYPE_INTERFACE_Core);
	if (impl->core == NULL) {
		str = pw_properties_get(props, PW_KEY_REMOTE_NAME);
		impl->core = pw_context_connect(impl->context,
				pw_properties_new(
					PW_KEY_REMOTE_NAME, str,
					NULL),
				0);
		impl->do_disconnect = true;
	}
	if (impl->core == NULL) {
		res = -errno;
		pw_log_error("can't connect: %m");
		goto error;
	}

	pw_proxy_add_listener((struct pw_proxy*)impl->core,
			&impl->core_proxy_listener,
			&core_proxy_events, impl);
	pw_core_add_listener(impl->core,
			&impl->core_listener,
			&core_events, impl);

	/* Set up FIFO paths from environment variables */
	set_fifo_paths(impl);

	/* Try to open FIFOs (non-fatal if they fail) */
	if (impl->mode & MODE_XRDP_SINK) {
		open_speaker_fifo(impl);
	}
	if (impl->mode & MODE_XRDP_SOURCE) {
		open_mic_fifo(impl);
	}

  	if ((res = create_stream(impl)) < 0)
		goto error;

	pw_impl_module_add_listener(module, &impl->module_listener, &module_events, impl);

	pw_impl_module_update_properties(module, &SPA_DICT_INIT_ARRAY(module_props));

	return 0;

error:
	impl_destroy(impl);
	return res;
}
